# SiteRoute — Flutter + Android mock location

Satu layar, satu pekerjaan: pilih satu koordinat, tahan di situ. Flutter untuk UI,
Kotlin untuk `LocationManager` test provider yang dijalankan lewat foreground service.

Tanpa root, tanpa Xposed, tanpa Play Services. Butuh satu sakelar di Developer
options.

---

## 1. Prasyarat di HP (sekali saja)

Android menolak semua `setTestProviderLocation` kecuali aplikasi dipilih sebagai
**aplikasi lokasi tiruan**.

1. Setelan → Tentang ponsel → ketuk **Nomor build** 7×.
2. Setelan → Sistem → **Opsi pengembang**.
3. **"Pilih aplikasi lokasi tiruan"** → pilih **SiteRoute**.

Lalu, supaya service tidak dibekukan ROM:

4. Saat app dibuka, baris peringatan baterai muncul di bawah kartu kontrol — tap **Ubah**
   untuk membuka halaman pengecualian baterai, lalu izinkan. Di ColorOS/MIUI aktifkan
   juga *Auto-start*. Baris peringatan hilang sendiri begitu kedua gate lolos.

| Izin | Kenapa |
|---|---|
| `ACCESS_FINE_LOCATION` | Android 14+ mensyaratkan izin lokasi untuk FGS bertipe `location`; juga untuk tombol "lokasi asli" |
| `POST_NOTIFICATIONS` (13+) | Notifikasi foreground service |
| `FOREGROUND_SERVICE_LOCATION` | Tipe service `location` |

---

## 2. Build

```bash
flutter pub get
flutter run
flutter build apk --release    # build/app/outputs/flutter-apk/
```

Flutter 3.24 · AGP 8.3.2 · Gradle 8.7 · Kotlin 1.9.22 · compileSdk/targetSdk 34 ·
minSdk 24 · JDK 17.

Release ditandatangani keystore tetap di `android/keystore/siteroute-release.jks`
(kredensial di `android/key.properties`). Keduanya git-ignored — **simpan salinannya**:
tanpa sertifikat yang sama, update tidak bisa dipasang di atas app yang sudah ada.

Tanpa `key.properties`, build jatuh ke debug key dan tidak bisa menimpa rilis.

---

## 3. Yang bisa dilakukan

- Tap peta, cari nama tempat (Nominatim), atau isi lat/lng lewat dialog koordinat.
- Simpan titik favorit; tombol bookmark di header membuka sheet berisi semua titik —
  tap untuk lompat, ikon pensil untuk rename, ikon hapus untuk membuang.
- Mulai / Stop mocking dari satu tombol.
- Ganti basemap saat berjalan: Google, Google Satelit, Esri, Esri Satelit, OSM.
- Semua setelan (basemap, titik terakhir, kamera) tersimpan antar-restart.

Tidak ada mode rute, kecepatan, arah gerak, atau jitter — posisi diam di satu titik.

---

## 4. Struktur

```
lib/
  main.dart                     # tema + root
  core/geo.dart                 # format koordinat & jarak
  core/mock_bridge.dart         # MethodChannel, MockStatus, ProviderHealth, probe
  core/update_bridge.dart       # MethodChannel updater, UpdateInfo
  models/map_source.dart        # 5 tile provider
  models/mock_request.dart      # payload statis ke service
  models/spot.dart              # titik favorit
  services/settings_store.dart  # AppSettings
  services/spot_store.dart      # favorit
  services/geocoder.dart        # Nominatim search
  screens/map_screen.dart       # peta + kartu kontrol + popup updater
  widgets/map_source_sheet.dart
  widgets/splash_overlay.dart   # splash animasi
  widgets/update_gate.dart      # popup pembaruan

android/app/src/main/kotlin/com/ajiputra/fake_gps/
  MainActivity.kt               # izin, gate AppOps, probe, start/stop, bridge updater
  MockLocationService.kt        # foreground service, test provider, auto-heal
  FixSynthesizer.kt             # sintesis fix per-provider
  WatchdogReceiver.kt           # exact alarm untuk membangunkan proses
  DetectionSurface.kt           # audit permukaan deteksi
  UpdateChecker.kt              # manifest, unduh, verifikasi SHA-256, installer
  UpdateConfig.kt               # URL manifest
```

---

## 5. Cara kerjanya

**Provider.** Service mendaftarkan tiga test provider: `gps`, `network`, `fused`.
`fused` adalah nama yang dibaca konsumen Play Services (`FusedLocationProviderClient`).
Tiap provider dicatat statusnya — terpasang, jumlah kirim, jumlah gagal.

**Tick.** `HandlerThread` + `Handler`, basis 500 ms. Interval tiap tick diambil dari
`nextInterval()`: ±18 % jitter plus sesekali jeda lebih panjang — meniru cadence provider
asli, karena interval yang persis sama adalah sidik jari yang mudah dihitung klien.

**Pembentukan fix.** `FixSynthesizer` membangun tiap `Location` per provider:

- **Drift** — random walk terbatas (Ornstein–Uhlenbeck) 0,3–2,5 m. Ponsel yang diam pun
  bergerak sedikit; koordinat `double` yang identik selama berjam-jam bukan fix GPS.
- **Speed & bearing** — turunan dari drift itu, jadi konsisten dengan selisih posisi
  yang bisa dihitung klien.
- **Akurasi** — berubah tiap fix, bukan konstanta.
- **Metadata** — `satellites`, `meanCn0`, `fixType`, akurasi vertikal/kecepatan dipilih
  dari kelas lingkungan koordinat (urban / suburban / rural / lepas pantai). Koordinat
  di tengah laut tidak melaporkan 27 satelit.
- **Altitude** — hash deterministik koordinat: tempat sama selalu melaporkan ketinggian
  sama, seperti perangkat nyata.

**Batas jujurnya.** Flag `Location.isMock` **tidak** bisa dihapus tanpa root. Framework
mengklon `Location` kita, menyalakan flag pada klon itu, lalu mem-parcel-nya ke proses
lain — `mFieldsMask` tidak ikut di-parcel, jadi aplikasi konsumen membacanya `true`
apa pun yang terjadi di proses ini. Yang bisa dikendalikan tanpa root sudah dikendalikan:
nama paket netral (`com.ajiputra.telemetrykit`, tanpa kata *fake/mock/gps*), label netral,
dan semua inkonsistensi fix dihapus. Lihat bagian 7.

**Auto-heal.** Kalau `setTestProviderLocation` melempar (provider dicabut ROM, mock app
diganti, GMS restart), kegagalan dihitung dan provider didaftarkan ulang otomatis tiap
3 kegagalan. Tanpa ini service "hidup" tapi diam — dan pembacaan jatuh ke GPS asli.

**Detail yang bikin gagal kalau dilewat:**

- `Location.isComplete()` wajib true sejak Android 12 — `time`, `elapsedRealtimeNanos`,
  `accuracy`, `provider`, dan **flag mock** (`Location.setMock(true)`, API 31+).
- `addTestProvider` sebelum `setTestProviderEnabled`.
- Partial wake lock ditahan selama sesi; `foregroundServiceType="location"`.
- Provider dibersihkan saat stop, jadi aplikasi lain langsung kembali ke GPS asli.

**Lokasi asli.** `LocationManager` langsung di `MainActivity`: cache dulu, kalau kosong
satu update dengan timeout 10 detik. Tanpa plugin lokasi pihak ketiga.

**Komunikasi.** Satu `MethodChannel` (`com.ajiputra.fake_gps/control`); Flutter
memanggil `start`/`update`/`stop`, state dibaca dengan polling `status` 1×/detik. Nilai
gate (`mockSelected`, `batteryUnrestricted`, `locationGranted`) di-cache dan disegarkan
saat `onResume` lewat `refreshGates`, bukan dibaca ulang tiap detik.

---

## 6a. Deteksi oleh aplikasi driver — apa yang benar-benar bisa dan tidak

Urutan pemeriksaan yang dipakai aplikasi dispatch, dan statusnya:

| pemeriksaan | bisa diakali tanpa root? | status |
|---|---|---|
| `Location.isMock` pada fix yang diterima | **tidak** — platform menandai ulang klon di proses lain | terdeteksi |
| nama paket / label terhadap wordlist | ya | netral: id tanpa token *fake/mock/gps*, label "SiteRoute" |
| probe "ada app yang jadi mock provider" (`addTestProvider` → `SecurityException`) | tidak, selama app ini memegang slot | terdeteksi |
| `Settings.Secure.ALLOW_MOCK_LOCATION` | hanya API < 23 | tidak berlaku |
| korelasi server (cell-ID, BSSID, kecepatan, bentuk rute) | terjadi di backend operator | tidak tersentuh |

Yang dihilangkan `FixSynthesizer` adalah semua pemeriksaan yang **lebih murah** dari
`isMock` — koordinat beku, cadence metronom, akurasi mustahil, jumlah satelit palsu,
speed nol. Itu yang dijalankan aplikasi dispatch pada fix yang sudah diterima.

Yang **tidak** bisa dijamin tanpa root: lolos dari pemeriksaan `isMock`. Solusi yang
benar-benar menutupinya adalah hook level framework (LSPosed) pada proses konsumen, atau
modul sistem yang mem-patch `LocationManagerService`. Keduanya di luar cakupan aplikasi
APK biasa.

Catatan praktis: sinkronkan juga posisi HP fisik — matikan GPS asli dan andalkan jaringan
seluler, karena banyak aplikasi driver membandingkan fix dengan BSSID Wi-Fi di sekitarnya.

---

## 6b. Kalau posisi balik ke lokasi asli

1. **Optimasi baterai** — service dibekukan, tick berhenti.
2. **Provider `fused` gagal** — aplikasi berbasis Play Services bisa tetap dapat posisi
   asli.
3. **Mock app dicabut** setelah update APK — nama paket berubah, jadi pilih ulang di
   Opsi pengembang.
4. **Aplikasi target punya anti-mock** (`Location.isMock()`) — lihat 6a; bukan bug
   aplikasi ini.

---

## 7. Batasan

| Hal | Kenyataan |
|---|---|
| Play Integrity / SafetyNet | Mendeteksi mock. Bukan alat lolos attestation. |
| ROM tertentu | Kadang tidak mengekspos "Select mock location app". |
| Provider `fused` | Sebagian perangkat memakai engine GMS sendiri. |
| Nominatim | Endpoint demo publik, ~1 request/detik. |
| Tile Google/Esri | Endpoint raster publik tanpa API key, tanpa kontrak. |
| Root / system app | Tidak didukung. |

---

## 7b. Pembaruan wajib

App membaca `update.json` di `main` repo ini pada setiap cold start, setiap resume, dan
setiap 15 menit selama terbuka. Kalau build terpasang lebih rendah dari yang diwajibkan,
**popup** muncul di atas peta:

- `force: true` — tidak ada tombol tutup, back tidak menembus, Start di bawah tidak bisa
  ditekan sampai update terpasang.
- `force: false` — ada tombol **Nanti** dan scrim bisa di-tap; tidak muncul lagi untuk
  versi yang sama.
- Manifest tidak terjangkau → popup tidak muncul (fail-open, supaya sinyal jelek tidak
  mengunci app kerja).

Panduan rilis lengkap: [`docs/UPDATE.md`](docs/UPDATE.md).

Rilis terbaru: https://github.com/ajiputra001/SiteRute/releases

---

## 8. Verifikasi

```bash
flutter analyze   # 0 issue
flutter test      # 12 test
```

Uji manual:

1. Pilih mock app + kecualikan optimasi baterai.
2. Pilih titik → **Mulai mocking** → notifikasi muncul, status jadi `Mocking · 3/3`.
3. Buka Google Maps → titik biru ada di lokasi mock.
4. Buka app peta lain → titik berada di koordinat mock, tidak melompat.
5. **Stop** → posisi kembali ke GPS asli.
