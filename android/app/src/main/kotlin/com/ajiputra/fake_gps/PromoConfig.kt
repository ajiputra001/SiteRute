package com.ajiputra.fake_gps

/**
 * The in-app promo for AUTO PETRIP, and its contact number.
 *
 * ## The contact
 *
 * [CONTACT_WA] holds the admin's WhatsApp number in the local `08…` form the operator
 * uses. [waUrl] converts it to the `62…` form the link needs, so pasting either form
 * works. Blank means the promo stays hidden on purpose: a card whose button opens
 * nothing is worse than no card — it burns the one chance to convert an interested
 * driver, and it looks broken.
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
 *   "wa": "6281234567890",
 *   "prefill": "Halo Admin AUTO PETRIP, saya tertarik…"
 * }
 * ```
 *
 * A remote block wins over the local defaults, so the number, the copy, the pre-filled
 * message and even the wording of the button can change without shipping an APK.
 * Bumping `id` re-shows the promo to operators who had dismissed the previous one.
 */
object PromoConfig {

    /**
     * Admin WhatsApp number.
     *
     * Stored in the local `08…` form the operator uses; [waUrl] converts it to the `62…`
     * form the link needs. Either form is accepted.
     */
    const val CONTACT_WA: String = "085641858425"

    // Local fallback copy, used when the manifest carries no promo block.
    const val ID: String = "petrip-v2"
    const val TITLE: String = "AUTO PETRIP"
    const val TAGLINE: String = "Isi petrip harian otomatis"
    const val CTA: String = "Hubungi admin"

    /**
     * The campaign copy.
     *
     * Written for WhatsApp, where `*text*` renders as bold. The app renders those markers
     * the same way instead of printing literal asterisks — see the promo sheet.
     */
    val BODY: String = """
        Masih capek isi form petrip manual setiap hari? 😫

        Sekarang tidak perlu lagi buang waktu buka dan input data satu per satu. Gunakan *AUTO PETRIP*, solusi otomatis untuk pengisian laporan petrip harian driver!

        Keunggulan menggunakan *AUTO PETRIP*:
        ✅ *Otomatis Setiap Hari* – Sistem memproses pengisian petrip secara otomatis tanpa perlu input manual berulang.
        ✅ *Hemat Waktu & Tenaga* – Tidak perlu lagi repot mengisi form satu per satu setelah selesai narik.
        ✅ *Anti Lupa & Tepat Waktu* – Laporan harian selalu tercatat rutin tanpa khawatir terlewat.
        ✅ *Praktis & Terima Beres* – Sekali aktivasi, driver cukup fokus bekerja di jalan.

        Tinggalkan cara lama yang ribet dan bikin urusan petrip harian jadi jauh lebih efisien.

        Tertarik mengaktifkan *AUTO PETRIP* atau ingin tanya-tanya lebih lanjut? Langsung balas pesan ini atau hubungi admin sekarang!
    """.trimIndent()

    /**
     * The message pre-filled into the chat box when the CTA is tapped.
     *
     * Written in the driver's voice, first person, and short enough to send without
     * editing. The operator can override it per-campaign with `promo.prefill`.
     */
    const val PREFILL: String =
        "Halo Admin AUTO PETRIP 👋 Saya tertarik dengan AUTO PETRIP dan ingin tahu " +
            "cara aktivasinya. Bisa dibantu?"

    /**
     * Builds a `wa.me` link from a loosely-formatted number, with [text] pre-filled.
     *
     * Accepts what an operator is likely to paste — `0812-3456-7890`, `+62 812 3456
     * 7890` — normalises the Indonesian leading zero to the 62 country code, and returns
     * null when what is left cannot be a phone number. A half-typed number must not
     * become a link that opens WhatsApp on a stranger's chat.
     */
    fun waUrl(raw: String, text: String = ""): String? {
        var digits = raw.filter { it.isDigit() }
        if (digits.isEmpty()) return null
        // Local form: 0812… → 62812…
        if (digits.startsWith("0")) digits = "62" + digits.substring(1)
        // Reject anything outside a plausible mobile length rather than guessing.
        if (digits.length < 10 || digits.length > 15) return null
        if (!digits.startsWith("62")) return null

        val base = "https://wa.me/$digits"
        if (text.isBlank()) return base

        // URLEncoder emits '+' for spaces, which wa.me shows literally as a plus sign.
        // Percent-encoding spaces keeps the drafted message readable in the chat box.
        val encoded = java.net.URLEncoder.encode(text, "UTF-8").replace("+", "%20")
        return "$base?text=$encoded"
    }
}
