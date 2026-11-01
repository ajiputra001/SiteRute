package com.ajiputra.fake_gps

import android.Manifest
import android.app.AlarmManager
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * The bridge. Flutter owns the UI; this Activity owns permissions, the mock-app
 * gate, diagnostics and the intent that boots the foreground service. Position
 * math and test-provider writes live in [MockLocationService].
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.ajiputra.fake_gps/control"
        private const val REQ_PERMISSIONS = 0x4D4F434B
    }

    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Seed the shared prefs context so persistTarget works before the service boots.
        MockLocationService.attachContext(applicationContext)
        refreshGates()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(statusMap())
                    "refreshGates" -> {
                        refreshGates()
                        result.success(true)
                    }
                    "isMockAppSelected" -> {
                        val selected = isMockAppSelected()
                        gateMockSelected = selected
                        result.success(selected)
                    }
                    "hasLocationPermission" -> result.success(hasLocationPermission())
                    "requestPermissions" -> requestPermissions(result)
                    "openDeveloperSettings" -> result.success(openDeveloperSettings())
                    "openAppDetails" -> result.success(openAppDetails())
                    "openBatterySettings" -> result.success(openBatterySettings())
                    "openExactAlarmSettings" -> result.success(openExactAlarmSettings())
                    "realLocation" -> locateOnce(result)
                    "probe" -> result.success(probe())
                    "detectionSurface" -> result.success(
                        DetectionSurface.selfInfo(this).toMutableMap().apply {
                            put("neutralId", DetectionSurface.isNeutralId(this@MainActivity))
                            put(
                                "flaggedTokens",
                                DetectionSurface.flaggedTokens(packageName),
                            )
                            put("signingSha256", DetectionSurface.signingSha256(this@MainActivity))
                            put("mockSlotTaken", DetectionSurface.slotOccupiedByAnotherApp(this@MainActivity))
                        }
                    )
                    // ---- updater
                    "installedVersion" -> result.success(installedVersion())
                    "checkUpdate" -> checkUpdate(result)
                    "downloadUpdate" -> downloadUpdate(result)
                    "installUpdate" -> {
                        val path = call.argument<String>("path").orEmpty()
                        result.success(UpdateChecker.install(this, path))
                    }
                    "canInstallPackages" -> result.success(UpdateChecker.canInstall(this))
                    "openInstallSettings" -> result.success(UpdateChecker.openInstallSettings(this))
                    "start" -> startMocking(call.arguments as? Map<*, *> ?: emptyMap<String, Any>(), result)
                    "update" -> {
                        updateConfig(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                        result.success(null)
                    }
                    "stop" -> {
                        WatchdogReceiver.disarm(this)
                        stopService(Intent(this, MockLocationService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------------------------------------------------------- status

    private fun statusMap(): Map<String, Any?> = mapOf(
        "running" to MockLocationService.isRunning,
        "lat" to MockLocationService.lat,
        "lng" to MockLocationService.lng,
        "speed" to MockLocationService.speed,
        "bearing" to MockLocationService.bearing,
        "intervalMs" to MockLocationService.intervalMs,
        "uptimeMs" to if (MockLocationService.startedAt == 0L) 0L
            else System.currentTimeMillis() - MockLocationService.startedAt,
        "providers" to MockLocationService.providers.toList(),
        "health" to MockLocationService.healthSnapshot(),
        "error" to MockLocationService.lastError,
        "tickCount" to MockLocationService.tickCount,
        "lastTickAt" to MockLocationService.lastTickAt,
        "stale" to (
            MockLocationService.isRunning &&
                MockLocationService.lastTickAt > 0L &&
                System.currentTimeMillis() - MockLocationService.lastTickAt >
                MockLocationService.STALE_THRESHOLD_MS
            ),
        // Answered from a value cached at resume/start instead of two binder calls
        // per second. The cache is refreshed by `refreshGates()`.
        "mockSelected" to gateMockSelected,
        "batteryUnrestricted" to gateBatteryUnrestricted,
        "locationGranted" to gateLocationGranted,
        // Without exact-alarm access the watchdog degrades to an inexact alarm, which
        // barely survives a ColorOS freeze. Surfaced so the UI can ask for it.
        "exactAlarmGranted" to canScheduleExactAlarms(),
    )

    @Volatile private var gateMockSelected: Boolean = false
    @Volatile private var gateBatteryUnrestricted: Boolean = false
    @Volatile private var gateLocationGranted: Boolean = false

    /** Re-reads the three gate values. Called on start, on resume and on demand. */
    private fun refreshGates() {
        gateLocationGranted = hasLocationPermission()
        gateMockSelected = isMockAppSelected()
        gateBatteryUnrestricted = isBatteryUnrestricted()
    }

    override fun onResume() {
        super.onResume()
        refreshGates()
    }

    private fun isMockAppSelected(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
            ?: return false
        val mode = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), packageName
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), packageName
                )
            }
        } catch (_: Throwable) {
            AppOpsManager.MODE_ERRORED
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun hasLocationPermission(): Boolean =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun isBatteryUnrestricted(): Boolean = try {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        pm.isIgnoringBatteryOptimizations(packageName)
    } catch (_: Throwable) {
        false
    }

    // ----------------------------------------------------------- permissions

    private fun requestPermissions(result: MethodChannel.Result) {
        val wanted = mutableListOf<String>()
        if (!hasLocationPermission()) {
            wanted += Manifest.permission.ACCESS_FINE_LOCATION
            wanted += Manifest.permission.ACCESS_COARSE_LOCATION
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            wanted += Manifest.permission.POST_NOTIFICATIONS
        }
        if (wanted.isEmpty()) {
            result.success(true)
            return
        }
        pendingResult = result
        requestPermissions(wanted.toTypedArray(), REQ_PERMISSIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERMISSIONS) return
        pendingResult?.success(hasLocationPermission())
        pendingResult = null
    }

    // ------------------------------------------------------------ real fix

    /**
     * One-shot real-position read: cached fix first, otherwise one update with a
     * 10 s ceiling. Kept native so the app carries no Play-Services location
     * dependency and no third-party plugin.
     */
    private fun locateOnce(result: MethodChannel.Result) {
        if (!hasLocationPermission()) {
            result.error("PERMISSION_DENIED", "Location permission is required.", null)
            return
        }
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager

        val cached = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .mapNotNull { runCatching { manager.getLastKnownLocation(it) }.getOrNull() }
            .maxByOrNull { it.time }
        if (cached != null) {
            result.success(mapOf("lat" to cached.latitude, "lng" to cached.longitude))
            return
        }

        val main = Handler(Looper.getMainLooper())
        var delivered = false
        var active: LocationListener? = null

        fun deliver(location: Location?) {
            if (delivered) return
            delivered = true
            active?.let { l -> runCatching { manager.removeUpdates(l) } }
            main.removeCallbacksAndMessages(null)
            if (location != null) {
                result.success(mapOf("lat" to location.latitude, "lng" to location.longitude))
            } else {
                result.error("NO_FIX", "No GPS fix within 10 s.", null)
            }
        }

        val listener = LocationListener { location: Location -> deliver(location) }
        active = listener

        val provider = when {
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> null
        }
        if (provider == null) {
            deliver(null)
            return
        }
        try {
            manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
        } catch (t: Throwable) {
            deliver(null)
            return
        }
        main.postDelayed({ deliver(null) }, 10_000)
    }

    // ------------------------------------------------------------ diagnostics

    /**
     * Reads back what each provider currently reports and compares it with the mock
     * coordinate. This is the honest answer to "is the fake fix actually winning?".
     */
    private fun probe(): Map<String, Any?> {
        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val targetLat = MockLocationService.lat
        val targetLng = MockLocationService.lng
        val rows = mutableListOf<Map<String, Any?>>()

        for (name in MockLocationService.PROVIDER_NAMES) {
            val location = runCatching { manager.getLastKnownLocation(name) }.getOrNull()
            if (location == null) {
                rows += mapOf(
                    "name" to name,
                    "match" to false,
                    "distance" to null,
                    "source" to "kosong",
                    "note" to "belum ada fix",
                )
                continue
            }
            val distance = approxDistance(targetLat, targetLng, location.latitude, location.longitude)
            val mockFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                location.isMock
            } else {
                @Suppress("DEPRECATION")
                location.isFromMockProvider
            }
            rows += mapOf(
                "name" to name,
                "match" to (distance < 80.0),
                "distance" to distance,
                "source" to if (mockFlag) "mock" else "real",
                "note" to String.format("%.6f, %.6f", location.latitude, location.longitude),
            )
        }

        return mapOf(
            "running" to MockLocationService.isRunning,
            "target" to mapOf("lat" to targetLat, "lng" to targetLng),
            "rows" to rows,
        )
    }

    private fun approxDistance(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val dLat = Math.toRadians(lat2 - lat1)
        val dLng = Math.toRadians(lng2 - lng1) * cos(Math.toRadians((lat1 + lat2) / 2))
        return 6_371_000.0 * sqrt(dLat * dLat + dLng * dLng)
    }

    // --------------------------------------------------------------- intents

    private fun openDeveloperSettings(): Boolean = try {
        startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: Throwable) {
        openAppDetails()
    }

    private fun openAppDetails(): Boolean = try {
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (_: Throwable) {
        false
    }

    private fun openBatterySettings(): Boolean {
        // Verified on CPH1911 with `dumpsys package com.android.settings`: ColorOS *does*
        // implement the per-app ignore dialog, but only behind the data URI filter —
        // invoking the bare action or passing an extra resolves to nothing and silently
        // drops the user on the Settings root. That is why the operator's app never
        // appeared in any battery list: the AOSP `HighPowerApplicationsActivity` is
        // redirected to the main Settings page on this ROM.
        //
        // The working call is:
        //   am start -a android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS \
        //            -d package:com.ajiputra.telemetrykit
        // which opens "Izinkan aplikasi selalu berjalan di background?" and, when
        // accepted, writes `user,<pkg>,<uid>` into the deviceidle whitelist.
        val candidates = buildList {
            add(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName")))
            // Per-app details always has a battery row as a fallback.
            add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")))
            add(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Throwable) {
                // Component not present on this ROM — try the next candidate.
            }
        }
        return false
    }

    /** Whether the OS will let this package schedule exact alarms (API 31+). */
    private fun canScheduleExactAlarms(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
        } else {
            true
        }
    } catch (_: Throwable) {
        false
    }

    /** Opens the system screen that lets the user grant exact-alarm access. */
    private fun openExactAlarmSettings(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            startActivity(
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } else {
            false
        }
    } catch (_: Throwable) {
        false
    }

    // ------------------------------------------------------------ mock start

    private fun startMocking(args: Map<*, *>, result: MethodChannel.Result) {
        if (!hasLocationPermission()) {
            result.error("PERMISSION_DENIED", "Location permission is required to post mock fixes.", null)
            return
        }
        if (!isMockAppSelected()) {
            result.error(
                "MOCK_NOT_ALLOWED",
                "This app is not selected as the mock location app in Developer options.",
                null
            )
            return
        }

        val startLat = (args["lat"] as? Number)?.toDouble() ?: 0.0
        val startLng = (args["lng"] as? Number)?.toDouble() ?: 0.0
        // Remember the target before the service sees it, so a STICKY restart or a
        // process death resumes this point rather than 0,0 or a stale one.
        MockLocationService.rememberTarget(startLat, startLng)

        val intent = Intent(this, MockLocationService::class.java).apply {
            action = MockLocationService.ACTION_START
            putExtra(MockLocationService.EXTRA_LAT, startLat)
            putExtra(MockLocationService.EXTRA_LNG, startLng)
            putExtra(MockLocationService.EXTRA_SPEED, (args["speed"] as? Number)?.toDouble() ?: 0.0)
            putExtra(MockLocationService.EXTRA_BEARING, (args["bearing"] as? Number)?.toDouble() ?: 0.0)
            putExtra(MockLocationService.EXTRA_INTERVAL, (args["intervalMs"] as? Number)?.toLong() ?: 500L)
            putExtra(MockLocationService.EXTRA_JITTER, (args["jitter"] as? Number)?.toDouble() ?: 0.0)
            putExtra(MockLocationService.EXTRA_LOOP, args["loop"] as? Boolean ?: false)
            putExtra(MockLocationService.EXTRA_ROUTE_LAT, toDoubleArray(args["routeLat"]))
            putExtra(MockLocationService.EXTRA_ROUTE_LNG, toDoubleArray(args["routeLng"]))
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    startForegroundService(intent)
                } catch (t: Throwable) {
                    // API 31+ throws ForegroundServiceStartNotAllowedException when the
                    // activity is not actually in the foreground — most often right after
                    // returning from the Developer-options screen, where the task is still
                    // resuming. A plain startService() does NOT fix this: since Android 12
                    // that call is rejected from the background for the same reason, so
                    // the "fallback" was dead code on every modern device. Retrying once
                    // after a short beat, while the activity finishes resuming, is what
                    // actually works; the service then promotes itself in onStartCommand.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        val retried = retryForegroundStart(intent, attempts = 3)
                        if (!retried) throw t
                    } else {
                        try {
                            startService(intent)
                        } catch (_: Throwable) {
                            throw t
                        }
                    }
                }
            } else {
                startService(intent)
            }
            result.success(true)
        } catch (t: Throwable) {
            result.error("START_FAILED", t.message ?: "Could not start the mock service.", null)
        }
    }

    /**
     * Retries `startForegroundService` a few times with a short gap.
     *
     * The window this closes is narrow and specific: on API 31+ the call is legal only
     * while this activity holds a foreground-equivalent state. Coming back from a system
     * Settings screen, the task is momentarily behind the Settings activity, and the
     * first attempt lands inside that gap. Waiting ~120 ms lets the resume complete.
     *
     * Runs on a background thread so the platform channel is not blocked; the result is
     * posted back to the main handler.
     */
    private fun retryForegroundStart(intent: Intent, attempts: Int): Boolean {
        var ok = false
        val latch = java.util.concurrent.CountDownLatch(1)
        Thread {
            for (i in 0 until attempts) {
                try {
                    startForegroundService(intent)
                    ok = true
                    break
                } catch (_: Throwable) {
                    try {
                        Thread.sleep(120L)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            }
            latch.countDown()
        }.start()
        try {
            latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            return false
        }
        return ok
    }

    private fun updateConfig(args: Map<*, *>) {
        if (!MockLocationService.isRunning) return
        MockLocationService.speed = (args["speed"] as? Number)?.toDouble() ?: MockLocationService.speed
        MockLocationService.bearing = (args["bearing"] as? Number)?.toDouble() ?: MockLocationService.bearing
        MockLocationService.intervalMs = (args["intervalMs"] as? Number)?.toLong() ?: MockLocationService.intervalMs
        MockLocationService.jitterMeters = (args["jitter"] as? Number)?.toDouble() ?: MockLocationService.jitterMeters
        (args["loop"] as? Boolean)?.let { MockLocationService.loopRoute = it }
        (args["lat"] as? Number)?.let { MockLocationService.lat = it.toDouble() }
        (args["lng"] as? Number)?.let { MockLocationService.lng = it.toDouble() }
        if (args.containsKey("lat") || args.containsKey("lng")) {
            val la = (args["lat"] as? Number)?.toDouble() ?: MockLocationService.lat
            val ln = (args["lng"] as? Number)?.toDouble() ?: MockLocationService.lng
            MockLocationService.rememberTarget(la, ln)
            MockLocationService.persistTarget(la, ln)
        }
        if (args.containsKey("routeLat")) {
            MockLocationService.setRoute(
                toDoubleArray(args["routeLat"]), toDoubleArray(args["routeLng"])
            )
        }
    }

    private fun toDoubleArray(raw: Any?): DoubleArray {
        val list = raw as? List<*> ?: return DoubleArray(0)
        return DoubleArray(list.size) { (list[it] as? Number)?.toDouble() ?: 0.0 }
    }

    // ---------------------------------------------------------------- updater

    /**
     * The version actually installed on this device.
     *
     * Read from the package manager rather than from a build constant so it stays
     * truthful after an in-place update — a hardcoded string would go stale the moment
     * the updater does its job, and the force-update gate would then compare wrongly.
     */
    private fun installedVersion(): Map<String, Any?> = try {
        val info = packageManager.getPackageInfo(packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode.toInt()
        } else {
            @Suppress("DEPRECATION")
            info.versionCode
        }
        mapOf("versionCode" to code, "versionName" to (info.versionName ?: code.toString()))
    } catch (_: Throwable) {
        mapOf("versionCode" to 0, "versionName" to "?")
    }

    /**
     * Background manifest probe.
     *
     * Network on a worker thread, result posted to the main looper — the platform channel
     * requires the reply on the thread that owns the messenger, and a synchronous HTTP
     * call here would stall the first frame for up to 15 s on a bad network.
     */
    private fun checkUpdate(result: MethodChannel.Result) {
        Thread {
            val installed = installedVersion()
            val installedCode = (installed["versionCode"] as? Number)?.toInt() ?: 0

            val manifest = UpdateChecker.effectiveManifest(this)
            val reply = if (manifest == null) {
                // Fail open: no manifest reachable means "cannot confirm staleness",
                // which is not the same as "stale". See UpdateChecker's header note.
                mapOf(
                    "reachable" to false,
                    "installedCode" to installedCode,
                    "installedName" to installed["versionName"],
                    "updateAvailable" to false,
                    "blocked" to false,
                )
            } else {
                val belowFloor = installedCode < manifest.minVersionCode
                val newer = manifest.versionCode > installedCode
                mapOf(
                    "reachable" to true,
                    "installedCode" to installedCode,
                    "installedName" to installed["versionName"],
                    "latestCode" to manifest.versionCode,
                    "latestName" to manifest.versionName,
                    "notes" to manifest.notes,
                    "updateAvailable" to newer,
                    // Blocked when the build is below the hard floor, or when a forced
                    // update exists. A non-forced newer build only nudges.
                    "blocked" to (belowFloor || (newer && manifest.force)),
                    "manifest" to manifest.toMap(),
                )
            }

            Handler(Looper.getMainLooper()).post {
                runCatching { result.success(reply) }
            }
        }.start()
    }

    private fun downloadUpdate(result: MethodChannel.Result) {
        Thread {
            val manifest = UpdateChecker.fetchManifest(this)
            val reply = if (manifest == null) {
                mapOf("ok" to false, "error" to "Tidak bisa membaca info pembaruan.")
            } else {
                UpdateChecker.download(this, manifest)
            }
            Handler(Looper.getMainLooper()).post {
                runCatching { result.success(reply) }
            }
        }.start()
    }
}
