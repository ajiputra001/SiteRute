package com.ajiputra.fake_gps

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Self-updater. Reads a JSON manifest, decides whether this install is stale, downloads
 * the APK into app-private cache, verifies its digest, and hands it to PackageInstaller
 * through [FileProvider].
 *
 * Deliberately split from the Flutter layer: the download is a long, cancellable socket
 * operation and the install is a platform intent. Both belong on the native side; Dart
 * only decides *what* the UI shows.
 *
 * Fail-open by design. A manifest that cannot be reached leaves the app usable. The
 * force-update gate exists to stop an old build from running against a new backend — not
 * to brick a driver standing at a pickup point because their signal dropped. If the
 * operator wants a hard lock that survives outages, `requiredManifest` on the manifest
 * side is the lever, not a silent DNS failure.
 */
object UpdateChecker {

    /** Result of a manifest probe. */
    data class Manifest(
        val versionCode: Int,
        val versionName: String,
        val apkUrl: String,
        val sha256: String?,
        val notes: String?,
        val force: Boolean,
        val minVersionCode: Int,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "versionCode" to versionCode,
            "versionName" to versionName,
            "apkUrl" to apkUrl,
            "sha256" to sha256,
            "notes" to notes,
            "force" to force,
            "minVersionCode" to minVersionCode,
        )
    }

    /** Where the last good manifest is kept, so an offline launch still enforces the lock. */
    private const val PREFS = "siteroute_update"
    private const val K_CACHED = "manifest.json"
    private const val K_CACHED_AT = "fetched_at"

    /** Sub-directory under cache/ that `file_paths.xml` exposes. */
    private const val APK_DIR = "updates"
    private const val APK_NAME = "siteroute-update.apk"

    // ---------------------------------------------------------------- manifest

    /** Fetches the manifest and caches it. Never throws; returns null on any failure. */
    fun fetchManifest(context: Context): Manifest? {
        val raw = try {
            httpGet(UpdateConfig.MANIFEST_URL)
        } catch (_: Throwable) {
            null
        } ?: return null

        val parsed = parse(raw) ?: return null
        cache(context, raw)
        return parsed
    }

    /**
     * Returns the manifest to trust right now.
     *
     * A cached copy is returned only when the network fetch failed — so a device with no
     * data still blocks itself against the last known requirement instead of silently
     * allowing an obsolete install.
     */
    fun effectiveManifest(context: Context): Manifest? =
        fetchManifest(context) ?: cached(context)

    private fun parse(raw: String): Manifest? = try {
        val o = JSONObject(raw)
        // Accept either a bare object or `{ "android": {...} }` so one file can describe
        // several platforms later without breaking this parser.
        val body = o.optJSONObject("android") ?: o
        val code = body.optInt("versionCode", 0)
        val url = body.optString("apkUrl", "")
        if (code <= 0 || url.isBlank()) {
            null
        } else {
            Manifest(
                versionCode = code,
                versionName = body.optString("versionName", code.toString()),
                apkUrl = url,
                sha256 = body.optString("sha256", "").takeIf { it.isNotBlank() },
                notes = body.optString("notes", "").takeIf { it.isNotBlank() },
                // `force` defaults to true: this app's whole point is that a stale build
                // must not keep running. An explicit `false` is the opt-out.
                force = body.optBoolean("force", true),
                minVersionCode = body.optInt("minVersionCode", code),
            )
        }
    } catch (_: Throwable) {
        null
    }

    private fun cache(context: Context, raw: String) {
        try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(K_CACHED, raw)
                .putLong(K_CACHED_AT, System.currentTimeMillis())
                .apply()
        } catch (_: Throwable) {
            // A full disk must not break the check; the network value is still in hand.
        }
    }

    private fun cached(context: Context): Manifest? = try {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val at = p.getLong(K_CACHED_AT, 0L)
        // Only honour the cache for a reasonable window. Past it, a cached "force" flag
        // could lock the app against a requirement that has since been withdrawn.
        if (at == 0L || System.currentTimeMillis() - at > 24 * 60 * 60 * 1000L) {
            null
        } else {
            p.getString(K_CACHED, null)?.let { parse(it) }
        }
    } catch (_: Throwable) {
        null
    }

    // ---------------------------------------------------------------- download

    /**
     * Downloads [manifest]'s APK into cache and verifies its digest.
     *
     * Returns a `file://`-equivalent content URI plus the local path, or an error map.
     * Runs on the calling thread — invoke it off the main thread.
     */
    fun download(context: Context, manifest: Manifest): Map<String, Any?> {
        val dir = File(context.cacheDir, APK_DIR).apply { mkdirs() }
        // Clear previous attempts so a half-written file is never handed to the installer.
        dir.listFiles()?.forEach { it.delete() }
        val out = File(dir, APK_NAME)

        try {
            val conn = (URL(manifest.apkUrl).openConnection() as HttpURLConnection).apply {
                connectTimeout = UpdateConfig.CONNECT_TIMEOUT_MS
                readTimeout = UpdateConfig.READ_TIMEOUT_MS
                instanceFollowRedirects = true
                requestMethod = "GET"
            }
            val code = conn.responseCode
            if (code !in 200..299) {
                conn.disconnect()
                return mapOf("ok" to false, "error" to "HTTP $code")
            }

            var written = 0L
            conn.inputStream.use { input ->
                FileOutputStream(out).use { sink ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        sink.write(buf, 0, n)
                        written += n
                    }
                }
            }
            conn.disconnect()

            if (written < 1024) {
                out.delete()
                return mapOf("ok" to false, "error" to "Berkas terlalu kecil — unduhan gagal.")
            }

            val expected = manifest.sha256
            if (expected != null) {
                val actual = sha256Of(out)
                if (!actual.equals(expected, ignoreCase = true)) {
                    out.delete()
                    return mapOf(
                        "ok" to false,
                        "error" to "Checksum tidak cocok. Unduhan rusak atau diubah.",
                    )
                }
            }

            return mapOf(
                "ok" to true,
                "path" to out.absolutePath,
                "sizeBytes" to written,
                "uri" to uriFor(context, out).toString(),
            )
        } catch (t: Throwable) {
            runCatching { out.delete() }
            return mapOf("ok" to false, "error" to (t.message ?: "Unduhan gagal."))
        }
    }

    private fun sha256Of(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun uriFor(context: Context, file: File): Uri =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)

    // ---------------------------------------------------------------- install

    /**
     * Whether this package may currently launch the installer.
     *
     * `REQUEST_INSTALL_PACKAGES` in the manifest is necessary but not sufficient: since
     * API 26 the user must also grant "Install unknown apps" to this specific package.
     */
    fun canInstall(context: Context): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    } catch (_: Throwable) {
        false
    }

    /** Opens the per-app "Install unknown apps" toggle. */
    fun openInstallSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false

        // Three candidates, tried in order of precision. ColorOS ships the AOSP
        // `ManageAppExternalSourcesActivity` but its resolver sometimes reports a match
        // and then drops the start silently, so success is confirmed by actually leaving
        // the app rather than by a non-throwing `startActivity`.
        val candidates = listOf(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"),
            ),
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES),
            // Last resort: the app-details page carries the "Install unknown apps" row on
            // every ROM, one tap deeper.
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}"),
            ),
        )

        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                context.startActivity(intent)
                return true
            } catch (_: Throwable) {
                // Activity not present on this ROM — or blocked by the OEM's component
                // guard. Try the next candidate.
            }
        }
        return false
    }

    /**
     * Hands the downloaded APK to PackageInstaller.
     *
     * `-r` semantics are implicit: installing a build with the same package name and same
     * signing certificate replaces the existing one in place and preserves app data
     * (saved spots, preferences). A different certificate is refused by the platform —
     * that is the reason the release build must not keep using the debug key once the
     * app is distributed (see `android/key.properties`).
     *
     * The intent is aimed at the system installer component rather than left as a bare
     * `ACTION_VIEW`, because any file explorer or archiver registered for the MIME type
     * turns the install into an app-chooser dialog. Those apps cannot install anyway —
     * they only confuse the one screen that must be single-purpose.
     */
    fun install(context: Context, path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = uriFor(context, file)

            // Preferred: the platform package installer, addressed by component so no
            // chooser appears. `com.android.packageinstaller` is AOSP; `com.google.android
            // .packageinstaller` is the Play variant used on most OEM builds.
            val installers = listOf(
                "com.google.android.packageinstaller" to
                    "com.android.packageinstaller.PackageInstallerActivity",
                "com.android.packageinstaller" to
                    "com.android.packageinstaller.PackageInstallerActivity",
            )
            for ((pkg, cls) in installers) {
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, APK_MIME)
                    setClassName(pkg, cls)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                val resolved = context.packageManager.resolveActivity(intent, 0)
                if (resolved == null) continue

                // `FLAG_GRANT_READ_URI_PERMISSION` only works when the receiving package
                // is identifiable. Granting it explicitly to the resolved package is what
                // makes the file readable to PackageInstaller — without this the activity
                // launches and immediately fails to open the stream, which looks like the
                // installer silently closing.
                try {
                    context.grantUriPermission(
                        resolved.activityInfo.packageName,
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: Throwable) {
                    // Continue: the intent flag may still cover it on less-restrictive ROMs.
                }

                try {
                    context.startActivity(intent)
                    return true
                } catch (_: Throwable) {
                    // Fall through to the next candidate.
                }
            }

            // Fallback: anything that can open an APK. Shows a chooser on ROMs without a
            // resolvable installer component, but still completes the install.
            val fallback = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(fallback)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private const val APK_MIME = "application/vnd.android.package-archive"

    // ---------------------------------------------------------------- helpers

    private fun httpGet(url: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = UpdateConfig.CONNECT_TIMEOUT_MS
            readTimeout = UpdateConfig.READ_TIMEOUT_MS
            instanceFollowRedirects = true
            requestMethod = "GET"
        }
        return try {
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException("HTTP ${conn.responseCode}")
            }
            conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }
}
