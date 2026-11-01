package com.ajiputra.fake_gps

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * What a driver-dispatch app can actually learn about this installation, and what this
 * app does about the parts that are controllable without root.
 *
 * Detection surface, in the order clients usually try it:
 *
 * | check | reachable without root? | state here |
 * |---|---|---|
 * | `Location.isMock` on a received fix | **cannot be changed** — the platform re-marks the clone in another process (see `FixSynthesizer.clearMockFlag`) | detectable |
 * | installed package name / label wordlist | yes | neutralised: id has no `fake`/`mock`/`gps` token, label is neutral |
 * | `AppOpsManager.OPSTR_MOCK_LOCATION` for the *client's* own uid | no — reports on the asking app, not on us | not applicable |
 * | "is any app the selected mock provider" probe (`addTestProvider` throwing `SecurityException`) | yes, and unavoidable while this app holds the slot | detectable, but indistinguishable from a legitimate field-testing tool |
 * | `Settings.Secure.ALLOW_MOCK_LOCATION` | only on API < 23, always 0 above | not applicable |
 * | server-side correlation (cell-ID / BSSID / speed / route shape) | happens on the operator's backend | untouched; the synthetic metadata makes the on-device half coherent |
 *
 * The honest position: a determined client that reads `isMock` will see it. What this
 * class removes is everything *cheaper* than that, and what `FixSynthesizer` removes is
 * every inconsistency that a client could flag without touching the mock bit at all —
 * frozen coordinates, a metronome fix cadence, impossible accuracy, bogus satellite
 * counts. Those are the checks a dispatch app runs on a fix it has already accepted.
 */
object DetectionSurface {

    /**
     * Words a package-name scorer looks for. Kept here so the build id can be
     * regression-checked against it instead of being eyeballed.
     */
    private val FLAGGED_TOKENS = listOf(
        "fake", "mock", "spoof", "gps", "location", "joystick", "faker", "cheat",
    )

    /** Returns the tokens present in [packageName], empty when the id is clean. */
    fun flaggedTokens(packageName: String): List<String> {
        val lower = packageName.lowercase()
        return FLAGGED_TOKENS.filter { lower.contains(it) }
    }

    /** True when the installed id carries none of the words a client scores on. */
    fun isNeutralId(context: Context): Boolean =
        flaggedTokens(context.packageName).isEmpty()

    /**
     * Whether another app currently holds the mock-provider slot. A client uses the
     * same probe: `addTestProvider` throws `SecurityException` when the slot is taken
     * by a different package.
     *
     * Reported so the UI can stay honest about it — there is no non-root way to make
     * this probe return false while this app is the active provider.
     */
    fun slotOccupiedByAnotherApp(context: Context): Boolean = try {
        val lm = context.getSystemService(Context.LOCATION_SERVICE)
            as android.location.LocationManager
        lm.addTestProvider(
            "probe_${Build.MODEL}",
            false, false, false, false, true, true, true,
            android.location.Criteria.POWER_LOW,
            android.location.Criteria.ACCURACY_FINE,
        )
        runCatching { lm.removeTestProvider("probe_${Build.MODEL}") }
        false
    } catch (_: SecurityException) {
        true
    } catch (_: Throwable) {
        false
    }

    /** Package-manager identity, for the one screen that reports it. */
    fun selfInfo(context: Context): Map<String, Any?> = try {
        val pm = context.packageManager
        val info = pm.getPackageInfo(context.packageName, 0)
        mapOf(
            "packageName" to context.packageName,
            "label" to pm.getApplicationLabel(info.applicationInfo!!).toString(),
            "versionName" to info.versionName,
            "flags" to (info.applicationInfo.flags and
                android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE),
        )
    } catch (_: Throwable) {
        mapOf("packageName" to context.packageName)
    }

    /** Signature fingerprint, so a client that hashes the APK sees a stable identity. */
    @Suppress("DEPRECATION")
    fun signingSha256(context: Context): String? {
        return try {
            val pm = context.packageManager
            val signatures = pm.getPackageInfo(
                context.packageName,
                PackageManager.GET_SIGNATURES,
            ).signatures ?: return null
            val md = java.security.MessageDigest.getInstance("SHA-256")
            signatures.forEach { md.update(it.toByteArray()) }
            md.digest().joinToString("") { "%02x".format(it) }
        } catch (_: Throwable) {
            null
        }
    }
}
