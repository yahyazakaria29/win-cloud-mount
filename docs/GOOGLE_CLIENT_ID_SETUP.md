# Panduan Membuat Google Client ID & Secret Pribadi (100% Gratis)

Membuat Google OAuth Client ID sendiri memberikan keuntungan performa yang masif:
1. **100% Gratis & Bebas Kartu Kredit**: Google menyediakan kuota **1 miliar query/hari** dan **20.000 request/100 detik** tanpa memungut biaya sepeser pun.
2. **Nol Rate Limiting**: Tidak ada lagi error `403 Rate Limit Exceeded` akibat berbagi kuota dengan jutaan pengguna publik Rclone di seluruh dunia.
3. **Kecepatan Transfer Maksimal**: Menghilangkan jeda *pacer throttling* saat mentransfer file besar (>1GB) atau banyak file sekaligus.

---

## Langkah 1: Buat Project di Google Cloud Console

1. Buka browser dan kunjungi: **[console.cloud.google.com](https://console.cloud.google.com)**.
2. Login menggunakan akun Google Anda.
3. Di bilah navigasi bagian atas (sebelah logo Google Cloud), klik pemilih project -> klik **"New Project"**.
4. Beri nama project, misalnya: `WinCloudMount` atau `MyCloudStorage`.
5. Klik **"Create"**. Tunggu beberapa detik hingga project selesai dibuat, lalu pastikan project tersebut terpilih di bar navigasi atas.

---

## Langkah 2: Aktifkan Google Drive API

1. Di kolom pencarian bagian atas, ketik: **`Google Drive API`**.
2. Klik hasil **"Google Drive API"** dari Marketplace / API Library.
3. Klik tombol biru **"Enable"** (Aktifkan).

---

## Langkah 3: Konfigurasi OAuth Consent Screen

1. Di menu navigasi kiri, pilih **APIs & Services** > **OAuth consent screen** (Layar persetujuan OAuth).
2. Pada pilihan **User Type**, pilih **External** (Eksternal), lalu klik **Create**.
3. Isi informasi dasar aplikasi:
   * **App name**: `WinCloudMount` (atau bebas).
   * **User support email**: Pilih email Google Anda.
   * **Developer contact information**: Masukkan email Google Anda.
4. Klik **Save and Continue**.
5. Pada bagian **Scopes (Cakupan)**, langsung klik **Save and Continue** (tidak perlu diubah).
6. Pada bagian **Test Users (Pengguna Uji Coba)**:
   * Klik **"+ ADD USERS"**.
   * Masukkan alamat email Google Anda sendiri.
   * Klik **Add**, lalu klik **Save and Continue**.
7. Klik **Back to Dashboard**.

---

## Langkah 4: Buat OAuth Client ID & Secret

1. Di menu navigasi kiri, klik **Credentials** (Kredensial).
2. Di bagian atas, klik tombol **"+ CREATE CREDENTIALS"** -> pilih **"OAuth client ID"**.
3. Pada dropdown **Application type**, pilih: **Desktop app**.
4. Beri nama: `WinCloudMount Client` (bebas).
5. Klik **Create**.
6. Jendela popup akan muncul menampilkan:
   * **Your Client ID** (format: `xxxxxxxxxx-xxxxxxxxxxxxxxxxxxxx.apps.googleusercontent.com`)
   * **Your Client Secret** (format: `GOCSPX-xxxxxxxxxxxxxxxxxxxxxxxx`)
7. Salin kedua nilai tersebut atau unduh file JSON-nya.

---

## Langkah 5: Masukkan Kredensial ke Rclone

Buka terminal PowerShell Anda, lalu jalankan:

```bash
rclone config
```

1. Pilih opsi **`e`** (*Edit existing remote*).
2. Pilih nomor remote Google Drive Anda (misal: `gdrive_personal`).
3. Pada wizard edit:
   * Saat muncul `client_id>` -> Paste **Client ID** yang baru saja Anda buat.
   * Saat muncul `client_secret>` -> Paste **Client Secret** Anda.
   * Pada pilihan `scope>` -> Pilih **`1`** (*Full access*).
   * Pada `service_account_file>` -> Kosongkan ([Enter]).
   * Pada `Edit advanced config?` -> Pilih **`n`**.
   * Pada `Use web browser to automatically authenticate?` -> Pilih **`y`**.
4. Browser akan otomatis terbuka. Login dengan akun Google Anda.
   * Jika muncul peringatan *"Google hasn't verified this app"*, klik **Advanced** (Lanjutan) lalu klik **"Go to WinCloudMount (unsafe)"**. Hal ini normal karena ini adalah aplikasi buatan Anda sendiri untuk pemakaian pribadi.
   * Beri centang seluruh izin akses Google Drive, lalu klik **Continue / Izinkan**.
5. Di terminal Rclone, konfirmasi penyimpanan: ketik **`y`** lalu **`q`** untuk keluar.

---

## Langkah 6: Restart Mount

Restart drive virtual untuk menerapkan kredensial baru dengan kecepatan maksimal:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action restart
```
