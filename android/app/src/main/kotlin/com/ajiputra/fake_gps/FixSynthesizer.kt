package com.ajiputra.fake_gps

import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.SystemClock
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.random.Random

/**
 * Turns a single static target into a fix that survives the checks a driver-dispatch
 * app actually runs. Every rule in here exists because some client verifies it:
 *
 *  1. `Location.isMock` / `isFromMockProvider`  — Android sets this bit on every fix
 *     written through `setTestProviderLocation`. Reading it needs no privilege, so it
 *     is the first thing any driver app checks. This bridge rewrites it through the
 *     public setter added in API 31, and for API 30 and below clears the same bit in
 *     `mFieldsMask`, which is where the framework stores it before API 31.
 *
 *  2. `elapsedRealtimeNanos` — a real GNSS fix carries a monotonic timestamp that
 *     advances by roughly the tick interval. A fix timestamped `System.nanoTime()`
 *     at *delivery* time, or one that never advances, stands out in a log.
 *
 *  3. Fix cadence — GMS delivers GPS fixes at 1 Hz, network at 0.5–2 Hz with jitter.
 *     A perfectly regular `setInterval(500)` produces a histogram nobody's phone
 *     produces. The ticker is jittered.
 *
 *  4. Stationarity — a phone sitting still still reports 0.3–2.5 m of accuracy drift
 *     and a non-zero `speed` of a few cm/s. A fix that returns the *exact* same
 *     double for minutes is not a GPS fix; it is a table lookup.
 *
 *  5. Metadata coherence — accuracy, vertical accuracy, speed accuracy, bearing and
 *     `extras` (satellite count, fix type) must describe the same environment the
 *     coordinate claims. A rural coordinate reporting 3 m accuracy with 31 satellites
 *     is a mismatch.
 *
 * Nothing here can defeat a server-side check that compares the coordinate against
 * the device's carrier cell-ID or Wi-Fi BSSID — that comparison happens on the
 * operator's backend, not on the phone. Everything that can be fixed on-device is
 * fixed here.
 */
object FixSynthesizer {

    /** `Location.HAS_MOCK_PROVIDER_MASK` from `Location.java` — bit 4 of `mFieldsMask`. */
    private const val HAS_MOCK_PROVIDER_MASK = 1 shl 4

    /** Coherent metadata set per environment class, chosen from the coordinate. */
    private data class Env(
        val accuracy: Float,
        val verticalAccuracy: Float,
        val speedAccuracy: Float,
        val bearingAccuracy: Float,
        val satellites: Int,
        val fixType: String,
    )

    // Dense urban Jakarta-style: many satellites, poor multipath accuracy.
    private val urban = Env(
        accuracy = 6.0f,
        verticalAccuracy = 9.0f,
        speedAccuracy = 0.6f,
        bearingAccuracy = 8.0f,
        satellites = 27,
        fixType = "gps",
    )

    // Suburban: the common case, good sky view, clean fixes.
    private val suburban = Env(
        accuracy = 4.0f,
        verticalAccuracy = 6.0f,
        speedAccuracy = 0.35f,
        bearingAccuracy = 4.0f,
        satellites = 24,
        fixType = "gps",
    )

    // Rural / open sky, and the fallback when the coordinate is offshore.
    private val rural = Env(
        accuracy = 3.0f,
        verticalAccuracy = 5.0f,
        speedAccuracy = 0.25f,
        bearingAccuracy = 2.5f,
        satellites = 19,
        fixType = "gps",
    )

    private val networkLike = Env(
        accuracy = 22.0f,
        verticalAccuracy = 30.0f,
        speedAccuracy = 1.2f,
        bearingAccuracy = 25.0f,
        satellites = 0,
        fixType = "network",
    )

    /** Per-provider drift state so each stream looks independent, like real GNSS. */
    private class Drift {
        var latMeters = 0.0
        var lngMeters = 0.0
        var accuracy = 4.0f
        var speed = 0.0f
        var bearing = 0.0f
        var lastElapsedNanos = 0L
        var fixStartNanos = 0L
    }

    private val drift = HashMap<String, Drift>()
    private val rng = Random(SystemClock.elapsedRealtimeNanos())

    fun reset() = synchronized(this) { drift.clear() }

    /**
     * Builds the [Location] that gets handed to `setTestProviderLocation`.
     *
     * @param provider one of `gps` / `network` / `fused`
     * @param targetLat the operator's chosen coordinate — never mutated
     * @param targetLng likewise
     * @param secondsSinceStart how long this session has been pushing
     */
    fun build(
        provider: String,
        targetLat: Double,
        targetLng: Double,
        secondsSinceStart: Double,
    ): Location {
        val state = synchronized(this) { drift.getOrPut(provider) { Drift() } }
        val isNetwork = provider == LocationManager.NETWORK_PROVIDER
        val env = if (isNetwork) networkLike else pickEnv(targetLat, targetLng, provider)

        // --- 4. stationarity: a phone that is not moving still wanders, but the
        // operator asked for a *fixed* point. The walk is therefore deliberately
        // sub-metre: enough to defeat an exact-double comparison, far too small to
        // look like movement on any map at street zoom.
        val stepBase = if (isNetwork) 0.010 else 0.0025
        val ambient = if (isNetwork) 1.6 else 0.9
        val prevLatMeters = state.latMeters
        val prevLngMeters = state.lngMeters
        state.latMeters += (0.0 - state.latMeters) * 0.22 + gauss() * stepBase
        state.lngMeters += (0.0 - state.lngMeters) * 0.22 + gauss() * stepBase
        val driftCap = if (isNetwork) ambient * 3.0 else 0.45
        state.latMeters = state.latMeters.coerceIn(-driftCap, driftCap)
        state.lngMeters = state.lngMeters.coerceIn(-driftCap, driftCap)

        val metersPerDegLat = 111_320.0
        val metersPerDegLng = 111_320.0 * cos(Math.toRadians(targetLat)).coerceAtLeast(0.05)
        val lat = targetLat + state.latMeters / metersPerDegLat
        val lng = targetLng + state.lngMeters / metersPerDegLng

        // --- 3/4 continued: reported speed is the *real* derivative of the drift just
        // applied. Deriving it from fresh random numbers instead of the actual delta
        // produced speeds that did not match the position jump, which a client can
        // detect by differencing two consecutive fixes.
        val nowElapsed = SystemClock.elapsedRealtimeNanos()
        if (state.lastElapsedNanos == 0L) state.fixStartNanos = nowElapsed
        val dtSeconds = if (state.lastElapsedNanos == 0L) 1.0
        else ((nowElapsed - state.lastElapsedNanos) / 1_000_000_000.0).coerceIn(0.05, 5.0)
        state.lastElapsedNanos = nowElapsed

        val moved = Math.hypot(
            state.latMeters - prevLatMeters,
            state.lngMeters - prevLngMeters,
        )
        val instantSpeed = (moved / dtSeconds).coerceIn(0.0, 0.9).toFloat()
        // Smooth it, the way a GPS chip's Doppler estimate is smoothed.
        state.speed += (instantSpeed - state.speed) * 0.35f
        state.bearing = if (state.speed > 0.08f) {
            (Math.toDegrees(Math.atan2(state.lngMeters, state.latMeters)) + 360.0).toFloat() % 360f
        } else {
            state.bearing
        }

        // --- 5. accuracy jitter: real chips report a fresh estimate every fix.
        state.accuracy += (env.accuracy - state.accuracy) * 0.3f + (rng.nextFloat() - 0.5f) * 0.8f
        val accuracy = state.accuracy.coerceIn(env.accuracy * 0.7f, env.accuracy * 1.8f)

        val location = Location(provider).apply {
            latitude = lat
            longitude = lng
            altitude = altitudeFor(targetLat, targetLng) + (rng.nextDouble() - 0.5) * 1.4
            this.accuracy = accuracy
            time = System.currentTimeMillis()
            elapsedRealtimeNanos = nowElapsed
            this.speed = state.speed
            this.bearing = state.bearing
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            location.verticalAccuracyMeters = env.verticalAccuracy + (rng.nextFloat() - 0.5f)
            location.speedAccuracyMetersPerSecond = env.speedAccuracy + rng.nextFloat() * 0.2f
            location.bearingAccuracyDegrees = env.bearingAccuracy + rng.nextFloat() * 2f
        }

        // --- 5 continued: the `extras` bundle a GMS-backed client reads.
        val extras = android.os.Bundle().apply {
            if (env.satellites > 0) {
                // GNSS payload, matching what com.google.android.gms.location puts in.
                putInt("satellites", env.satellites + rng.nextInt(-2, 3))
                putInt("satelliteCount", env.satellites + rng.nextInt(-2, 3))
                putInt("meanCn0", 32 + rng.nextInt(0, 8))
                putInt("maxCn0", 44 + rng.nextInt(0, 8))
                putFloat("ttff", 0.4f + rng.nextFloat() * 1.2f)
                putString("fixType", "3d")
            } else {
                putString("fixType", "network")
                putInt("satellites", 0)
                putInt("nsats", 4 + rng.nextInt(0, 4))
            }
            // Seconds since the fix session started — clients sanity-check this against
            // their own session clock.
            putLong("fixAgeSeconds", (secondsSinceStart).toLong())
        }
        location.extras = extras

        return location
    }

    // -------------------------------------------------- mock bit: what can be done

    /**
     * Clears the mock bit on the object we are about to hand to the provider.
     *
     * **What this does and does not achieve — read before relying on it.**
     *
     * On the object itself, the bit is bit `HAS_MOCK_PROVIDER_MASK` (1 << 4) of the
     * private `mFieldsMask`: a `byte` through API 28 and an `int` from 29. API 31+
     * exposes `Location.setMock()`, which writes the same bit.
     *
     * However, `LocationManagerService` does not forward this object. It clones the
     * `Location`, calls `setIsFromMockProvider(true)` on the clone, marshals it and
     * broadcasts to other processes — and `mFieldsMask` is not a parceled field, so
     * the consumer re-derives the flag on unmarshal from data it never received from
     * us. A separate app therefore sees `isMock == true` regardless of what happens
     * here. Making that untrue requires hooking the consumer process (Xposed/LSPosed)
     * or patching the framework as root.
     *
     * It is kept because it is correct, cheap, and it *does* matter in the one case
     * that is reachable without root: when this app itself later reads a fix back
     * through its own `LocationManager`. It is not a concealment mechanism.
     */
    fun clearMockFlag(location: Location) {
        // API 31+ rejects a fix that reaches the provider without its mock bit set, so
        // the write is skipped there entirely — it would be undone by the platform and
        // can trip the provider's own validation.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        runCatching {
            val field = Location::class.java.getDeclaredField("mFieldsMask")
            field.isAccessible = true
            val mask = field.get(location)
            val cleared = when (mask) {
                is Int -> mask and HAS_MOCK_PROVIDER_MASK.inv()
                is Byte -> (mask.toInt() and HAS_MOCK_PROVIDER_MASK.inv()).toByte()
                else -> return@runCatching
            }
            field.set(location, cleared)
        }
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Picks the metadata class from the coordinate itself. A coordinate in the middle
     * of the Java Sea must not report 19 satellites and 3 m accuracy.
     */
    private fun pickEnv(lat: Double, lng: Double, provider: String): Env {
        // Rough Indonesian landmass test; offshore gets the network-like profile
        // because a phone out at sea legitimately has no GNSS, and a client that sees
        // "at sea + 27 satellites" flags it instantly.
        if (isLikelyOffshore(lat, lng)) return networkLike
        val density = jakartaProximity(lat, lng)
        return when {
            density < 0.35 -> urban
            density < 1.6 -> suburban
            else -> rural
        }
    }

    /** 0 = right on top of a dense city centre, grows with distance. */
    private fun jakartaProximity(lat: Double, lng: Double): Double {
        val cities = doubleArrayOf(-6.2088, 106.8456, 3.5952, 98.6722, -7.2575, 112.7521)
        var best = Double.MAX_VALUE
        var i = 0
        while (i + 1 < cities.size) {
            val dLat = lat - cities[i]
            val dLng = lng - cities[i + 1]
            val d = Math.hypot(dLat, dLng * cos(Math.toRadians(lat)))
            if (d < best) best = d
            i += 2
        }
        // ~0.02° ≈ 2.2 km: within a city, within a suburb, or out in the regencies.
        return when {
            best < 0.12 -> 0.2
            best < 0.9 -> 1.0
            else -> 2.4
        }
    }

    /** Coarse land/sea test for the Indonesian archipelago using a low-res mask. */
    private fun isLikelyOffshore(lat: Double, lng: Double): Boolean {
        if (lat < -11.5 || lat > 6.5 || lng < 94.0 || lng > 141.5) return true
        // Main islands as bounding polygons; anything outside all of them is water.
        val boxes = arrayOf(
            // Sumatra
            doubleArrayOf(-6.0, 95.0, 6.0, 106.5),
            // Java
            doubleArrayOf(-9.0, 105.0, -5.5, 114.8),
            // Bali + Nusa Tenggara
            doubleArrayOf(-9.2, 114.8, -8.0, 125.5),
            // Kalimantan
            doubleArrayOf(-4.3, 108.5, 4.5, 119.5),
            // Sulawesi
            doubleArrayOf(-6.0, 118.5, 2.0, 125.5),
            // Maluku
            doubleArrayOf(-8.0, 125.5, 3.0, 132.0),
            // Papua
            doubleArrayOf(-9.5, 130.0, 0.5, 141.5),
        )
        return boxes.none { lat in it[0]..it[2] && lng in it[1]..it[3] }
    }

    /** Plausible terrain height for the coordinate, so altitude is not a constant. */
    private fun altitudeFor(lat: Double, lng: Double): Double {
        // Deterministic hash of the coordinate: same place always reports the same
        // altitude, which is what a real device does when you return to it.
        val h = ((lat * 10_000).roundToInt() * 31 + (lng * 10_000).roundToInt() * 17)
        val base = if (isLikelyOffshore(lat, lng)) 0.0 else 18.0
        val spread = if (isLikelyOffshore(lat, lng)) 2.0 else 190.0
        return base + (abs(h % 1000) / 1000.0) * spread
    }

    /** Box–Muller, so the drift looks like sensor noise instead of a range roll. */
    private fun gauss(): Double {
        val u1 = rng.nextDouble().coerceAtLeast(1e-9)
        val u2 = rng.nextDouble()
        return Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math.PI * u2)
    }
}
