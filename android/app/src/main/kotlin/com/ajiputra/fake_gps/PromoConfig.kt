package com.ajiputra.fake_gps

/**
 * The in-app promo for AUTO PETRIP, and the one line the operator has to fill.
 *
 * ## Filling the contact
 *
 * Set [CONTACT_WA] to the admin's WhatsApp number, digits only, international form:
 * `"6281234567890"` — no `+`, no spaces, no leading zero. Rebuild once and the promo
 * appears inside SiteRoute.
 *
 * While [CONTACT_WA] is blank the promo stays hidden on purpose. A card whose button
 * opens nothing is worse than no card: it burns the one chance to convert a driver who
 * was interested, and it looks broken.
 *
 * ## Changing it without a rebuild
 *
 * The same block can be supplied remotely through `update.json`:
 *
 * ```json
 * "promo": {
 *   "id": "petrip-v2",
 *   "enabled": true,
 *   "title": "AUTO PETRIP",
 *   "tagline": "Isi petrip harian otomatis",
 *   "body": "…",
 *   "cta": "Hubungi admin",
 *   "wa": "6281234567890"
 * }
 * ```
 *
 * A remote block wins over the local defaults, so the number, the copy and even the
 * wording of the button can change without shipping an APK. Bumping `id` re-shows the
 * promo to operators who had dismissed the previous one.
 */
object PromoConfig {

    /**
     * Admin WhatsApp number, digits only in international form.
     *
     * Empty by default: the promo is hidden until this is set. See the class comment.
     */
    const val CONTACT_WA: String = ""

    // Local fallback copy, used when the manifest carries no promo block.
    const val ID: String = "petrip-v1"
    const val TITLE: String = "AUTO PETRIP"
    const val TAGLINE: String = "Isi petrip harian otomatis"
    const val BODY: String =
        "Setiap hari driver harus mengisi petrip secara manual. AUTO PETRIP mengisi " +
            "petrip harian otomatis, jadi tidak perlu isi form satu per satu. " +
            "Hubungi admin kalau berminat."
    const val CTA: String = "Hubungi admin"

    /**
     * Builds a `wa.me` link from a loosely-formatted number.
     *
     * Accepts what an operator is likely to paste — `0812-3456-7890`, `+62 812 3456
     * 7890` — normalises the Indonesian leading zero to the 62 country code, and returns
     * null when what is left cannot be a phone number. A half-typed number must not
     * become a link that opens WhatsApp on a stranger's chat.
     */
    fun waUrl(raw: String): String? {
        var digits = raw.filter { it.isDigit() }
        if (digits.isEmpty()) return null
        // Local form: 0812… → 62812…
        if (digits.startsWith("0")) digits = "62" + digits.substring(1)
        // Reject anything outside a plausible mobile length rather than guessing.
        if (digits.length < 10 || digits.length > 15) return null
        if (!digits.startsWith("62")) return null
        return "https://wa.me/$digits"
    }
}
