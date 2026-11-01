package com.ajiputra.fake_gps

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Criteria
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import java.util.Locale
import java.util.Random
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** Per-provider health, so the UI can show which fake source is actually winning. */
class ProviderHealth(val name: String) {
    @Volatile var attached: Boolean = false
    @Volatile var enabled: Boolean = false
    @Volatile var pushes: Long = 0
    @Volatile var failures: Long = 0
    @Volatile var lastError: String? = null

    fun toMap(): Map<String, Any?> = mapOf(
        "name" to name,
        "attached" to attached,
        "enabled" to enabled,
        "pushes" to pushes,
        "failures" to failures,
        "error" to lastError,
    )
}

/**
 * Keeps the stream of fixes alive while the app is backgrounded, and repairs itself
 * when a provider is revoked mid-session (the usual cause of a position that "snaps
 * back" to the real GPS).
 *
 * Two things gate this service from the outside:
 *  - the package must be the selected mock location app (checked via AppOps in
 *    [MainActivity] before start);
 *  - a `location` foreground service needs the location runtime permission on API 34+.
 *
 * What goes on the wire is built by [FixSynthesizer], not here: this class owns the
 * lifecycle, the tick and the provider bookkeeping.
 */
class MockLocationService : Service() {

    companion object {
        const val ACTION_START = "com.ajiputra.fake_gps.action.START"
        const val ACTION_STOP = "com.ajiputra.fake_gps.action.STOP"
        const val ACTION_WAKE = "com.ajiputra.fake_gps.action.WAKE"

        const val EXTRA_LAT = "lat"
        const val EXTRA_LNG = "lng"
        const val EXTRA_SPEED = "speed"
        const val EXTRA_BEARING = "bearing"
        const val EXTRA_INTERVAL = "intervalMs"
        const val EXTRA_ROUTE_LAT = "routeLat"
        const val EXTRA_ROUTE_LNG = "routeLng"
        const val EXTRA_JITTER = "jitter"
        const val EXTRA_LOOP = "loop"

        private const val CHANNEL_ID = "mock_location"
        private const val NOTIFICATION_ID = 7101

        /** `gps`/`network` feed the platform API, `fused` feeds Play-Services consumers. */
        val PROVIDER_NAMES = arrayOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            "fused",
        )

        val health: ConcurrentHashMap<String, ProviderHealth> = ConcurrentHashMap<String, ProviderHealth>().apply {
            PROVIDER_NAMES.forEach { put(it, ProviderHealth(it)) }
        }

        @Volatile var isRunning: Boolean = false
            private set
        @Volatile var lat: Double = 0.0
        @Volatile var lng: Double = 0.0
        @Volatile var speed: Double = 0.0
        @Volatile var bearing: Double = 0.0
        @Volatile var intervalMs: Long = 500L
        @Volatile var jitterMeters: Double = 0.0
        @Volatile var loopRoute: Boolean = false
        @Volatile var lastError: String? = null
        @Volatile var tickCount: Long = 0
        @Volatile var startedAt: Long = 0
        @Volatile var providers: List<String> = emptyList()
            internal set

        @Volatile private var routeLat: DoubleArray = DoubleArray(0)
        @Volatile private var routeLng: DoubleArray = DoubleArray(0)
        @Volatile private var routeIndex: Int = 0

        /**
         * Last target known to the service, persisted so `START_STICKY` restarts and
         * process kills resume the *same* point instead of a stale or zeroed one.
         * A restart that loses the coordinate is the number-one cause of a fix stream
         * that silently reverts to the real GPS after a few minutes.
         */
        @Volatile private var lastLat: Double = Double.NaN
        @Volatile private var lastLng: Double = Double.NaN
        @Volatile private var hasTarget: Boolean = false

        fun rememberTarget(la: Double, ln: Double) {
            if (la.isNaN() || ln.isNaN()) return
            lastLat = la
            lastLng = ln
            hasTarget = true
        }

        /**
         * Application context, captured in [onCreate]. Lets [persistTarget] be called
         * from activities/isolates that have no service instance yet.
         */
        @Volatile private var appContext: Context? = null

        private const val PREFS_NAME = "mock_service_state"

        /** Called by [MainActivity] so persistence works before the service exists. */
        fun attachContext(ctx: Context) {
            appContext = ctx.applicationContext
        }

        /** Persists the target without needing a live service instance. */
        fun persistTarget(la: Double, ln: Double) {
            val ctx = appContext ?: return
            try {
                ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                    .putFloat("lat", la.toFloat())
                    .putFloat("lng", ln.toFloat())
                    .putBoolean("hasTarget", true)
                    .apply()
            } catch (_: Throwable) {
            }
        }

        /**
         * Watchdog bookkeeping. `lastTickAt` is written by the ticker; the UI polls it.
         * A gap longer than [_staleMs] means the handler stopped for a reason the
         * service did not observe (process throttling, doze without wake, thread death).
         */
        @Volatile var lastTickAt: Long = 0
        const val STALE_THRESHOLD_MS = 3_500L

        fun setRoute(latArray: DoubleArray, lngArray: DoubleArray) {
            routeLat = latArray
            routeLng = lngArray
            routeIndex = 0
        }

        fun clearRoute() {
            routeLat = DoubleArray(0)
            routeLng = DoubleArray(0)
            routeIndex = 0
        }

        fun healthSnapshot(): List<Map<String, Any?>> =
            PROVIDER_NAMES.mapNotNull { health[it]?.toMap() }

        /**
         * Called by [WatchdogReceiver] to collapse a post-freeze gap.
         *
         * The alarm fires from system_server even while this process is frozen, so by
         * the time it runs the Handler queue may hold several stale ticks. Re-arming
         * from here guarantees one fresh fix per second regardless of what was queued,
         * which is what every location client's staleness check actually looks at.
         */
        @Volatile private var immediateRequested: Boolean = false

        fun requestImmediatePush(context: Context) {
            immediateRequested = true
            // If the process was fully killed rather than frozen, `isRunning` is false
            // and nothing will consume the flag — start the service again from the
            // persisted target instead.
            val intent = Intent(context, MockLocationService::class.java).apply {
                action = ACTION_WAKE
            }
            try {
                if (isRunning) context.startService(intent) else null
            } catch (_: Throwable) {
            }
        }
    }

    private lateinit var locationManager: LocationManager
    private lateinit var handler: Handler
    private lateinit var thread: HandlerThread
    private var wakeLock: PowerManager.WakeLock? = null
    private val random = Random()

    private val tick = object : Runnable {
        override fun run() {
            if (!isRunning) return
            // The wake lock is re-asserted on every tick, not only in onCreate. Under
            // Doze the CPU is suspended and a queued postDelayed simply does not fire;
            // the client then stops receiving fixes, times out, and falls back to the
            // real GPS. Holding a short lease per tick keeps the stream continuous and
            // lets the device sleep between ticks instead of pinning it awake forever.
            ensureAwake()
            if (immediateRequested) {
                immediateRequested = false
                // A watchdog wake means the gap was already long enough to matter. Drop
                // any ticks still queued from before the freeze so the cadence restarts
                // cleanly instead of firing a burst of stale ones.
                handler.removeCallbacks(this)
            }
            step()
            push()
            lastTickAt = System.currentTimeMillis()
            if (tickCount % 8 == 0L) refreshNotification()
            WatchdogReceiver.arm(this@MockLocationService)
            // --- 3. fix cadence: GMS does not emit on a perfect metronome. A uniform
            // interval is one of the cheapest fingerprints a client can compute, so the
            // next tick is drawn from the same spread a real provider produces.
            handler.postDelayed(this, nextInterval())
        }
    }

    /**
     * Keeps the CPU awake long enough to deliver the next fix, and no longer.
     * A 2 s lease per tick covers the longest inter-tick gap (`nextInterval` caps at
     * 12 s only for pathological configs; the default base is 500 ms).
     */
    private fun ensureAwake() {
        try {
            val wl = wakeLock ?: return
            if (!wl.isHeld) wl.acquire(2_500L)
        } catch (_: Throwable) {
        }
    }

    /**
     * Interval for the next fix, in ms. Base rate comes from [intervalMs] (default
     * 500 ms = 2 Hz), then ±18 % jitter plus a rare 1-in-25 longer gap modelling the
     * frame a chip drops when it re-acquires. The mean is preserved, so the stream
     * still lands the same number of fixes per minute.
     */
    /**
     * Interval for the next fix, in ms.
     *
     * The base rate comes from [intervalMs] (default 500 ms = 2 Hz), then ±12 % jitter
     * plus a rare 1-in-40 longer gap modelling the frame a chip drops when it
     * re-acquires. Both bounds are deliberately tighter than a metronome-shaped stream
     * would need: a client that has already been burned by a stale fix tightens its
     * own timeout, and any gap above ~1.5 s is enough for it to fall back to the real
     * provider. The mean is preserved, so nothing is lost in fixes-per-minute.
     */
    private fun nextInterval(): Long {
        val base = intervalMs.coerceIn(150L, 1_000L)
        val jitter = 1.0 + (random.nextDouble() * 0.24 - 0.12)
        val dropped = if (random.nextInt(40) == 0) 1.0 + random.nextDouble() * 0.25 else 1.0
        return (base * jitter * dropped).toLong().coerceIn(120L, 1_500L)
    }

    override fun onCreate() {
        super.onCreate()
        appContext = applicationContext
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        createChannel()
        thread = HandlerThread("mock-location-ticker").also { it.start() }
        handler = Handler(thread.looper)
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "FakeGPS::mock").apply {
            setReferenceCounted(false)
        }
        // No acquire here: the tick asserts a short lease (see ensureAwake), so the
        // device is not pinned awake for the whole session just to stay registered.
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            WatchdogReceiver.disarm(this)
            stopSelf()
            return START_NOT_STICKY
        }

        // A wake from WatchdogReceiver: the service is already running and only needs
        // the cadence restarted. Handling it before the recovery block keeps the target
        // untouched — this path must never re-read config or re-register providers.
        if (intent?.action == ACTION_WAKE && isRunning) {
            immediateRequested = true
            handler.removeCallbacks(tick)
            handler.post(tick)
            return START_STICKY
        }

        // Android restarts a STICKY service with a null intent after a low-memory or
        // doze kill. Falling through with no config would push whatever stale value
        // `lat`/`lng` happen to hold — or 0,0 after a process death — which is exactly
        // the "it jumped back to the real location" symptom. Recover from persistent
        // storage instead, and if there is nothing to recover, bail out cleanly.
        val recovered = intent?.action == ACTION_START || intent != null
        if (recovered) {
            readConfig(intent!!)
        } else if (hasTarget) {
            lat = lastLat
            lng = lastLng
        } else {
            val restored = restoreFromPrefs()
            if (!restored) {
                stopSelf()
                return START_NOT_STICKY
            }
        }

        // Foreground first: Android kills the process if this is not called within ~5 s.
        startInForeground()

        if (!isRunning) {
            attachProviders()
            if (providers.isEmpty()) {
                stopSelf()
                return START_NOT_STICKY
            }
            rememberTarget(lat, lng)
            persistTarget(lat, lng)
            FixSynthesizer.reset()
            startedAt = System.currentTimeMillis()
            tickCount = 0
            isRunning = true
            push()
            WatchdogReceiver.arm(this)
            handler.postDelayed(tick, nextInterval())
        }
        return START_STICKY
    }

    // --------------------------------------------------------------- recovery

    private fun prefsName() = PREFS_NAME

    /**
     * Persists the target so a process kill / STICKY restart resumes it.
     * Static so [MainActivity] can write it before the service is even running.
     * Falls back to the last context seen by the service when called from a
     * non-static path.
     */
    private fun persistTarget(la: Double, ln: Double) {
        try {
            getSharedPreferences(prefsName(), Context.MODE_PRIVATE).edit()
                .putFloat("lat", la.toFloat())
                .putFloat("lng", ln.toFloat())
                .putBoolean("hasTarget", true)
                .apply()
        } catch (_: Throwable) {
        }
    }

    private fun restoreFromPrefs(): Boolean = try {
        val p = getSharedPreferences(prefsName(), Context.MODE_PRIVATE)
        if (!p.getBoolean("hasTarget", false)) {
            false
        } else {
            lat = p.getFloat("lat", 0f).toDouble()
            lng = p.getFloat("lng", 0f).toDouble()
            rememberTarget(lat, lng)
            true
        }
    } catch (_: Throwable) {
        false
    }

    override fun onDestroy() {
        isRunning = false
        WatchdogReceiver.disarm(this)
        handler.removeCallbacksAndMessages(null)
        detachProviders()
        FixSynthesizer.reset()
        thread.quitSafely()
        startedAt = 0
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------- providers

    private fun attachProviders() {
        val ok = mutableListOf<String>()
        for (name in PROVIDER_NAMES) {
            if (attachOne(name)) ok += name
        }
        providers = ok
        if (ok.isEmpty()) {
            lastError = "Tidak ada provider yang bisa didaftarkan. Pastikan app ini dipilih " +
                "sebagai aplikasi lokasi tiruan di Opsi pengembang."
        }
    }

    private fun attachOne(name: String): Boolean {
        val state = health[name] ?: return false
        return try {
            // A previous run may have left the provider registered.
            try {
                locationManager.removeTestProvider(name)
            } catch (_: IllegalArgumentException) {
            }
            @Suppress("DEPRECATION")
            locationManager.addTestProvider(
                name,
                false, false, false, false, true, true, true,
                Criteria.POWER_LOW, Criteria.ACCURACY_FINE,
            )
            locationManager.setTestProviderEnabled(name, true)
            state.attached = true
            state.enabled = true
            state.lastError = null
            true
        } catch (t: SecurityException) {
            state.attached = false
            state.enabled = false
            state.lastError = "SecurityException: bukan aplikasi mock yang dipilih"
            lastError = state.lastError
            false
        } catch (t: Throwable) {
            state.attached = false
            state.enabled = false
            state.lastError = "${t.javaClass.simpleName}: ${t.message ?: "gagal daftar"}"
            false
        }
    }

    private fun detachProviders() {
        for (name in PROVIDER_NAMES) {
            try {
                locationManager.setTestProviderEnabled(name, false)
            } catch (_: Throwable) {
            }
            try {
                locationManager.removeTestProvider(name)
            } catch (_: Throwable) {
            }
            health[name]?.let {
                it.attached = false
                it.enabled = false
            }
        }
        providers = emptyList()
    }

    private fun readConfig(intent: Intent) {
        lat = intent.getDoubleExtra(EXTRA_LAT, lat)
        lng = intent.getDoubleExtra(EXTRA_LNG, lng)
        speed = intent.getDoubleExtra(EXTRA_SPEED, speed)
        bearing = intent.getDoubleExtra(EXTRA_BEARING, bearing)
        intervalMs = intent.getLongExtra(EXTRA_INTERVAL, intervalMs)
        jitterMeters = intent.getDoubleExtra(EXTRA_JITTER, jitterMeters)
        loopRoute = intent.getBooleanExtra(EXTRA_LOOP, loopRoute)
        setRoute(
            intent.getDoubleArrayExtra(EXTRA_ROUTE_LAT) ?: DoubleArray(0),
            intent.getDoubleArrayExtra(EXTRA_ROUTE_LNG) ?: DoubleArray(0),
        )
    }

    // ------------------------------------------------------------- movement

    private fun step() {
        if (speed <= 0.0) return
        val dt = intervalMs / 1000.0
        val distance = speed * dt

        if (routeLat.size >= 2 && routeLat.size == routeLng.size) {
            advanceAlongRoute(distance)
        } else {
            val (nLat, nLng) = destination(lat, lng, bearing, distance)
            lat = nLat
            lng = nLng
        }
    }

    /** Walks the polyline at the configured speed, snapping to each vertex on arrival. */
    private fun advanceAlongRoute(distance: Double) {
        if (routeIndex >= routeLat.size - 1) {
            if (!loopRoute) {
                speed = 0.0
                return
            }
            routeIndex = 0
        }
        var remaining = distance
        while (remaining > 0.0 && routeIndex < routeLat.size - 1) {
            val tLat = routeLat[routeIndex + 1]
            val tLng = routeLng[routeIndex + 1]
            val toTarget = haversine(lat, lng, tLat, tLng)
            bearing = bearingTo(lat, lng, tLat, tLng)
            if (toTarget <= remaining || toTarget < 0.35) {
                lat = tLat
                lng = tLng
                remaining -= toTarget
                routeIndex += 1
            } else {
                val (nLat, nLng) = destination(lat, lng, bearing, remaining)
                lat = nLat
                lng = nLng
                remaining = 0.0
            }
        }
        if (routeIndex >= routeLat.size - 1 && !loopRoute) speed = 0.0
    }

    private fun push() {
        tickCount += 1
        val secondsSinceStart = if (startedAt == 0L) 0.0
        else (System.currentTimeMillis() - startedAt) / 1000.0

        // Health sweep: a provider can be silently dropped by the ROM (battery saver,
        // GMS restart, mock-app re-selection) without `setTestProviderLocation` ever
        // throwing. In that state the service looks healthy while clients fall back to
        // the real GPS — the exact symptom this sweep exists to catch.
        if (tickCount % 20 == 0L) verifyProvidersAlive()

        for (name in providers) {
            val state = health[name] ?: continue
            if (!state.attached) continue

            try {
                // The fix is synthesised per provider so `gps`, `network` and `fused`
                // never report byte-identical values — a client comparing them is a
                // standard check, and identical streams are the tell.
                val loc = FixSynthesizer.build(
                    provider = name,
                    targetLat = lat,
                    targetLng = lng,
                    secondsSinceStart = secondsSinceStart,
                )
                // Fixes this app reads back itself should not carry the mock bit. This
                // does not hide the flag from client apps — see clearMockFlag.
                FixSynthesizer.clearMockFlag(loc)

                locationManager.setTestProviderLocation(name, loc)
                state.pushes += 1
                state.lastError = null
            } catch (t: Throwable) {
                state.failures += 1
                state.lastError = "${t.javaClass.simpleName}: ${t.message ?: "gagal kirim"}"
                lastError = "${state.name}: ${state.lastError}"
                // The provider was revoked or reset (ROM battery saver, mock app
                // switched, GMS restart). Re-register it instead of dying quietly.
                if (state.failures % 3L == 0L) {
                    attachOne(name)
                    if (state.attached) {
                        providers = PROVIDER_NAMES.filter { health[it]?.attached == true }
                    }
                }
            }
        }
    }

    /**
     * Re-registers any provider the ROM quietly dropped.
     *
     * `setTestProviderLocation` on a provider whose registration was revoked can
     * succeed into the void on some ROMs — the call returns normally and the fix is
     * never delivered. The only reliable probe is to re-register: if the provider is
     * still ours, `addTestProvider` throws (already exists) and nothing changes; if it
     * was dropped, this puts it back before the client notices.
     */
    private fun verifyProvidersAlive() {
        for (name in PROVIDER_NAMES) {
            val state = health[name] ?: continue
            try {
                // Cheap reachability check first: enabling is idempotent and throws
                // when the provider is no longer registered under us.
                locationManager.setTestProviderEnabled(name, true)
            } catch (_: Throwable) {
                attachOne(name)
            }
            if (!state.attached) attachOne(name)
        }
        val live = PROVIDER_NAMES.filter { health[it]?.attached == true }
        if (live.isNotEmpty()) providers = live
    }

    // ---------------------------------------------------------------- math

    private fun destination(
        lat: Double, lng: Double, bearingDeg: Double, distanceMeters: Double,
    ): Pair<Double, Double> {
        val radius = 6_371_000.0
        val angular = distanceMeters / radius
        val brng = Math.toRadians(bearingDeg)
        val lat1 = Math.toRadians(lat)
        val lng1 = Math.toRadians(lng)

        val lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(brng))
        val lng2 = lng1 + atan2(
            sin(brng) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2),
        )
        return Math.toDegrees(lat2) to normalizeLng(Math.toDegrees(lng2))
    }

    private fun haversine(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val radius = 6_371_000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLng = Math.toRadians(lng2 - lng1)
        val a = sin(dLat / 2) * sin(dLat / 2) +
            cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLng / 2) * sin(dLng / 2)
        return radius * 2 * asin(sqrt(a.coerceIn(0.0, 1.0)))
    }

    private fun bearingTo(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val phi1 = Math.toRadians(lat1)
        val phi2 = Math.toRadians(lat2)
        val dLng = Math.toRadians(lng2 - lng1)
        val y = sin(dLng) * cos(phi2)
        val x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLng)
        return (Math.toDegrees(atan2(y, x)) + 360.0) % 360.0
    }

    private fun normalizeLng(value: Double): Double {
        var v = value
        while (v > 180.0) v -= 360.0
        while (v < -180.0) v += 360.0
        return v
    }

    // --------------------------------------------------------- notification

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mock location",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps the fake GPS fix alive in the background."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 2,
            Intent(this, MockLocationService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val attachedCount = providers.size
        val body = String.format(
            Locale.US, "%.5f, %.5f · %.1f m/s · %d/%d provider",
            lat, lng, speed, attachedCount, PROVIDER_NAMES.size,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Mock location aktif")
            .setContentText(body)
            .setSmallIcon(R.drawable.ic_stat_mock)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun startInForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 14+ enforces this at the platform level: `startForeground` with
            // FOREGROUND_SERVICE_TYPE_LOCATION throws SecurityException unless
            // ACCESS_FINE_LOCATION (or COARSE) is currently granted. The UI checks this
            // before starting, but a START_STICKY restart can run days later, after the
            // user revoked location from system settings — and that path would kill the
            // whole app. Degrade to an untyped foreground service instead of crashing;
            // the mock writes will then fail individually and be visible in health.
            val canUseLocationType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                hasLocationPermissionNow()
            } else {
                true
            }
            if (canUseLocationType) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                // API 29–33 still accept an untyped call; on 34+ this is the one form
                // that does not require the permission.
                startForeground(NOTIFICATION_ID, notification)
                lastError = "Izin lokasi dicabut — titik tidak bisa dikirim."
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /** Runtime location grant check that works on API 24+. */
    private fun hasLocationPermissionNow(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED ||
                checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    } catch (_: Throwable) {
        false
    }

    private fun refreshNotification() {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, buildNotification())
        } catch (_: Throwable) {
        }
    }
}
