# Update wajib — cara kerja dan cara merilis

## Ringkasan

App memeriksa satu file JSON di internet pada setiap cold start dan setiap kali kembali
dari background. Kalau build yang terpasang lebih rendah dari yang diwajibkan, UI
**dikunci total**: tidak ada tombol tutup, tombol back tidak menembus, dan tombol Start
di bawah tidak bisa ditekan sampai update terpasang.

Pemeriksaan dilakukan di thread background, jadi jaringan mati tidak menunda peta.

---

## Di mana file manifest diletakkan

Satu titik konfigurasi:

```
android/app/src/main/kotlin/com/ajiputra/fake_gps/UpdateConfig.kt
```

```kotlin
const val MANIFEST_URL: String = "https://raw.githubusercontent.com/ajiputra-tech/siteroute-release/main/update.json"
```

Ganti URL itu ke tempat kamu menyimpan `update.json`. Selama masih URL placeholder,
fetch akan gagal dan gate **terbuka** — app tetap bisa dipakai. Itu disengaja: lebih baik
app jalan daripada brick karena salah ketik URL.

---

## Format `update.json`

```json
{
  "versionCode": 3,
  "versionName": "1.2.0",
  "apkUrl": "https://example.com/SiteRoute-1.2.0.apk",
  "sha256": "8a2aa745b6ce5744b313dd4be691da177aa6eda89be92790999003d29a06684a",
  "notes": "Perbaikan freeze di ColorOS, splash baru.",
  "force": true,
  "minVersionCode": 3
}
```

| field | wajib | arti |
|---|---|---|
| `versionCode` | ya | Versi terbaru. Naik setiap rilis. |
| `versionName` | ya | Ditampilkan di layar gate. |
| `apkUrl` | ya | URL langsung ke file `.apk`. |
| `sha256` | tidak | Kalau diisi, unduhan diverifikasi. Salah satu-satunya cara mencegah APK rusak/diubah terpasang. **Isi selalu.** |
| `notes` | tidak | Ditampilkan sebagai kotak catatan di gate. |
| `force` | tidak | Default `true`. `false` = hanya penawaran, tidak memblokir. |
| `minVersionCode` | tidak | Batas bawah keras. Build di bawah ini **selalu** diblokir, terlepas dari `force`. |

### Kapan app diblokir

```
blocked = (installedCode < minVersionCode) OR (versionCode > installedCode AND force)
```

Jadi:

- Naikkan `versionCode` + `force: true` → semua orang wajib update.
- Naikkan `minVersionCode` saja → build lama di bawah batas itu terkunci, build lain hanya ditawari.
- `force: false` → tidak ada yang dipaksa, hanya muncul info.

### Hitung sha256

```bash
sha256sum SiteRoute-1.2.0.apk
```

Tempel hasilnya ke `sha256`. Kalau checksum tidak cocok, unduhan ditolak dan file dihapus
— tidak ada pemasangan APK rusak.

---

## Alur di device

1. App dibuka → manifest di-fetch di background.
2. Kalau diblokir → layar gate muncul di atas UI (UI tetap ter-build di bawahnya, jadi
   tidak ada flash hitam setelah update).
3. Tombol pertama berbunyi **"Izinkan pemasangan"** kalau izin "Install unknown apps"
   belum diberikan untuk paket ini. Menekannya membuka halaman settings yang tepat.
4. Setelah izin diberikan, tombol berubah **"Unduh pembaruan"** saat app resume.
5. Unduhan → verifikasi SHA-256 → tombol **"Pasang sekarang"**.
6. Installer sistem terbuka langsung (tanpa dialog pilih-aplikasi), operator tekan
   "Instal".
7. App diganti di tempat. **Data tidak hilang** — saved spots, target terakhir, basemap,
   semuanya bertahan.

---

## Kenapa update bisa menimpa tanpa hapus

Android mengizinkan install menimpa **hanya bila sertifikat penandatangan sama**. Karena
itu release build sekarang ditandatangani keystore tetap:

```
android/keystore/siteroute-release.jks
android/key.properties
```

**Keduanya wajib disimpan.** Kalau keystore hilang:

- Update tidak bisa dipasang di atas app yang sudah ada.
- Satu-satunya jalan adalah uninstall dulu — dan itu **menghapus semua saved spots**.

Simpan dua file itu di tempat aman (password manager, cloud storage pribadi, dua salinan).

### Sertifikat saat ini

```
CN=SiteRoute, OU=Ajiputra-tech, O=Ajiputra-tech, L=Bekasi, ST=Jawa Barat, C=ID
SHA-256: 08:71:0E:83:C7:41:53:D5:16:38:1E:6C:D0:B6:34:A2:76:2B:53:53:A0:11:74:2D:73:E6:55:18:CB:E0:66:C2
```

Cek sertifikat APK kapan saja:

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

### Peringatan migrasi satu kali

Build sebelum perubahan ini ditandatangani **debug key** (`CN=Android Debug`). APK baru
tidak bisa dipasang di atasnya. Untuk device yang masih memakai build lama, uninstall
sekali — data lama akan hilang pada langkah ini saja. Setelah itu semua update berikutnya
menimpa dengan aman.

---

## Cara merilis versi baru

```bash
# 1. Naikkan versi. Angka setelah '+' adalah versionCode — harus selalu naik.
#    pubspec:  version: 1.2.0+3
sed -i 's/^version: .*/version: 1.3.0+4/' pubspec.yaml

# 2. Build
flutter build apk --release

# 3. Hitung checksum
sha256sum build/app/outputs/flutter-apk/app-release.apk

# 4. Upload APK ke hosting, update update.json di MANIFEST_URL:
#    { "versionCode": 4, "versionName": "1.3.0", "apkUrl": "...", "sha256": "...",
#      "force": true, "minVersionCode": 4 }
```

Reinstall manual ke device sendiri:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`-r` = replace, mempertahankan data.

---

## Batas jujur

**Fail-open pada jaringan mati.** Kalau manifest tidak bisa diambil, gate terbuka.
Itu pilihan sadar: pengemudi di jalan dengan sinyal jelek tidak boleh terkunci dari app
kerja. Kalau perlu kunci yang tahan offline, isi `minVersionCode` dan biarkan cache
24 jam di `UpdateChecker.cached()` yang menegakkan — tapi tetap saja device yang belum
pernah berhasil fetch sama sekali akan lolos.

**Belum ada update parsial/delta.** Setiap update mengunduh APK penuh (~48 MB).

**Tidak ada signature verification di sisi klien** selain yang dilakukan Android saat
install. `sha256` memverifikasi integritas transfer, bukan penerbit. Penerbit diverifikasi
oleh platform lewat sertifikat yang sama.
