package com.ajiputra.fake_gps

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
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

    /**
     * Fetches the manifest and caches it. Never throws; returns null on any failure.
     *
     * A `?t=<minute>` cache-buster is appended because `raw.githubusercontent.com` serves
     * through a CDN that holds a branch path for a few minutes. Without it, a release
     * pushed moments ago is invisible to devices that fetched shortly before it — the app
     * would keep reporting the previous version until the edge cache expires. The query
     * string is ignored by the server but makes the CDN treat each minute as a new object.
     */
    fun fetchManifest(context: Context): Manifest? {
        val busted = UpdateConfig.MANIFEST_URL + manifestCacheBuster()
        val raw = try {
            httpGet(busted)
        } catch (_: Throwable) {
            // A cache-busted URL can miss on a proxy that keyed on the plain path, so one
            // retry at the bare URL is worth the extra round trip.
            try {
                httpGet(UpdateConfig.MANIFEST_URL)
            } catch (_: Throwable) {
                null
            }
        } ?: return null

        val parsed = parse(raw) ?: return null
        cache(context, raw)
        return parsed
    }

    /** Minute-granularity token; the CDN edge then keys on it. */
    private fun manifestCacheBuster(): String =
        "?t=" + (System.currentTimeMillis() / 60_000L)

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
     * Installs the downloaded APK through a [PackageInstaller] session.
     *
     * The previous implementation launched an `ACTION_VIEW` intent at the APK's MIME
     * type. On this device that resolved to `ResolverActivity` — the "open with" chooser
     * offering File Manager, Termux and WPS Office — so the operator got a picker instead
     * of an install, tapped the update button again, and the popup reappeared with the
     * version unchanged. Addressing the installer component directly was supposed to
     * avoid that and did not survive this ROM's resolver.
     *
     * A session is the correct mechanism: no chooser, and the platform reports what
     * actually happened through [InstallReceiver] — cancelled, blocked by Play Protect,
     * signature conflict — instead of failing silently.
     *
     * Returns immediately. The outcome is asynchronous; read [lastInstallStatus] and
     * [lastInstallMessage] afterwards.
     */
    fun install(context: Context, path: String): Map<String, Any?> {
        lastInstallStatus = STATUS_NONE
        lastInstallMessage = null
        lastSessionId = -1

        val file = File(path)
        if (!file.exists()) {
            return mapOf("ok" to false, "error" to "Berkas APK tidak ditemukan.")
        }

        return try {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            ).apply {
                // The size hint lets the platform fail early on a full disk instead of
                // midway through the copy, which is the difference between a clear
                // "storage" error and an unexplained abort.
                setSize(file.length())
            }

            val sessionId = installer.createSession(params)
            lastSessionId = sessionId

            installer.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, file.length()).use { out ->
                    file.inputStream().use { input -> input.copyTo(out, 64 * 1024) }
                    session.fsync(out)
                }

                val callback = PendingIntent.getBroadcast(
                    context,
                    sessionId,
                    Intent(context, InstallReceiver::class.java)
                        .putExtra(InstallReceiver.EXTRA_SESSION_ID, sessionId),
                    PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag(),
                )
                session.commit(callback.intentSender)
            }

            mapOf("ok" to true, "sessionId" to sessionId)
        } catch (t: Throwable) {
            // Abandon a half-written session so it does not linger in the installer queue.
            runCatching {
                if (lastSessionId >= 0) {
                    context.packageManager.packageInstaller.abandonSession(lastSessionId)
                }
            }
            mapOf("ok" to false, "error" to (t.message ?: "Sesi pemasangan gagal dibuat."))
        }
    }

    /**
     * Not a real `PackageInstaller` code; sits outside its -1…8 range. Used as the
     * "no attempt yet" sentinel — `0` would be read as `STATUS_SUCCESS`.
     *
     * Declared before [lastInstallStatus] because object property initialisers run in
     * source order and cannot see a constant declared further down.
     */
    const val STATUS_NONE: Int = Int.MIN_VALUE

    /**
     * Status of the last install attempt, mirroring `PackageInstaller.STATUS_*`.
     */
    @Volatile
    var lastInstallStatus: Int = STATUS_NONE

    @Volatile
    var lastInstallMessage: String? = null

    @Volatile
    var lastSessionId: Int = -1

    /** API 31+ requires an explicit mutability flag on a PendingIntent the system fills in. */
    private fun mutableFlag(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }

    // ---------------------------------------------------------------- helpers

    private fun httpGet(url: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = UpdateConfig.CONNECT_TIMEOUT_MS
            readTimeout = UpdateConfig.READ_TIMEOUT_MS
            instanceFollowRedirects = true
            requestMethod = "GET"
            // Belt to the cache-buster's braces: tells any intermediate cache — the CDN,
            // a carrier proxy — that this response must be revalidated rather than served
            // from a stale copy.
            setRequestProperty("Cache-Control", "no-cache")
            setRequestProperty("Pragma", "no-cache")
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
