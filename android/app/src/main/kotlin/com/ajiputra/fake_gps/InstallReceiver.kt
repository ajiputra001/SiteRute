package com.ajiputra.fake_gps

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

/**
 * Result callback for the self-update install.
 *
 * `PackageInstaller.commit()` does not install immediately — it hands the session to the
 * platform, which either asks the user to confirm or fails outright. Both outcomes arrive
 * here as a broadcast. Without this receiver the app launched an installer and then knew
 * nothing about what happened, which is exactly why a rejected update looked like "the
 * button does nothing".
 */
class InstallReceiver : BroadcastReceiver() {

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )

        when (status) {
            // The platform needs a confirmation tap. It hands back the dialog as an
            // Intent we must launch ourselves — this is the normal path, not an error.
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                UpdateChecker.lastInstallStatus = status
                UpdateChecker.lastInstallMessage = null
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                try {
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    if (confirm != null) context.startActivity(confirm)
                } catch (_: Throwable) {
                    UpdateChecker.lastInstallStatus = PackageInstaller.STATUS_FAILURE
                    UpdateChecker.lastInstallMessage =
                        "Tidak bisa membuka layar konfirmasi pemasangan."
                }
            }

            PackageInstaller.STATUS_SUCCESS -> {
                UpdateChecker.lastInstallStatus = status
                UpdateChecker.lastInstallMessage = null
            }

            else -> {
                UpdateChecker.lastInstallStatus = status
                // The platform's own message is often the only thing that distinguishes
                // "user cancelled" from "signature mismatch", so it is preferred when
                // present and only then replaced by our fallback text.
                UpdateChecker.lastInstallMessage =
                    intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                        ?.takeIf { it.isNotBlank() }
                        ?: describe(status)
            }
        }
    }

    private fun describe(status: Int): String = when (status) {
        PackageInstaller.STATUS_FAILURE_BLOCKED ->
            "Pemasangan diblokir sistem. Cek Play Protect."
        PackageInstaller.STATUS_FAILURE_ABORTED ->
            "Pemasangan dibatalkan."
        PackageInstaller.STATUS_FAILURE_INVALID ->
            "Berkas APK tidak valid atau rusak."
        PackageInstaller.STATUS_FAILURE_CONFLICT ->
            "Bentrok dengan versi terpasang — tanda tangan APK berbeda."
        PackageInstaller.STATUS_FAILURE_STORAGE ->
            "Penyimpanan tidak cukup untuk memasang."
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE ->
            "APK tidak kompatibel dengan perangkat ini."
        else -> "Pemasangan gagal (kode $status)."
    }
}
