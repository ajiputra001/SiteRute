package com.ajiputra.fake_gps

/**
 * Where the update manifest lives.
 *
 * This is the single point of change when the app moves to another host. The updater
 * reads [MANIFEST_URL] on every cold start and whenever the operator taps "Periksa
 * pembaruan"; the JSON at that address decides whether the app is blocked.
 *
 * Expected JSON shape — the parser is deliberately lenient, see [UpdateChecker]:
 * ```json
 * {
 *   "versionCode": 3,
 *   "versionName": "1.2.0",
 *   "apkUrl": "https://example.com/SiteRoute-1.2.0.apk",
 *   "sha256": "9f2c...e41a",
 *   "notes": "Perbaikan freeze di ColorOS.",
 *   "force": true,
 *   "minVersionCode": 3
 * }
 * ```
 */
object UpdateConfig {

    /**
     * The manifest address.
     *
     * Placeholder on purpose: point this at the real file before shipping a build that
     * is meant to be updated. While it is left as-is the fetch fails against DNS and the
     * forced-update gate stays open (see `UpdateChecker.FAIL_OPEN`), so the app remains
     * usable rather than bricking itself on a URL that does not exist yet.
     */
    const val MANIFEST_URL: String = "https://raw.githubusercontent.com/ajiputra001/SiteRute/main/update.json"

    /** How long a manifest response is trusted before it is fetched again. */
    const val CACHE_TTL_MS: Long = 10 * 60 * 1000L

    /** Abort a stalled download after this long without progress. */
    const val CONNECT_TIMEOUT_MS: Int = 15_000
    const val READ_TIMEOUT_MS: Int = 30_000
}
