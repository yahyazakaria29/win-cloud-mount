# Panduan Membuat Google Client ID & Secret Pribadi (100% Gratis)

Membuat Google OAuth Client ID sendiri memberikan tiga keuntungan utama:
1. **Gratis tanpa kartu kredit**: Google menyediakan kuota default Google Drive API yang jauh lebih besar dibanding berbagi kuota publik Rclone.
2. **Menghindari error `403 Rate Limit Exceeded`**: Anda tidak lagi berebut kuota dengan jutaan pengguna Rclone lain di shared `client_id` bawaan (yang juga dijadwalkan dipensiunkan).
3. **Satu pasang untuk semua akun Google Drive**: Satu Client ID & Secret bisa dipakai bersama oleh banyak remote (`gdrive_1`, `gdrive_2`, `gdrive_3`, dst.) milik Anda tanpa perlu membuat project baru per akun.

---

## Langkah 1: Buat Project di Google Cloud Console

1. Buka browser dan kunjungi **[console.cloud.google.com](https://console.cloud.google.com)**.
2. Login menggunakan akun Google utama Anda.
3. Di bilah atas, klik pemilih project lalu klik **New Project**.
4. Beri nama project, misalnya `WinCloudMount`, lalu klik **Create** dan pastikan project tersebut terpilih.

---

## Langkah 2: Aktifkan Google Drive API

1. Di kolom pencarian atas, ketik **Google Drive API**.
2. Buka hasil **Google Drive API** dari API Library.
3. Klik tombol **Enable**.

---

## Langkah 3: Lengkapi Google Auth Platform (Branding & Publish App)

Google Cloud kini mengelompokkan konfigurasi OAuth di bawah menu **Google Auth Platform** (atau **APIs & Services > OAuth consent screen** pada tampilan lama).

1. Di menu navigasi kiri, buka **Google Auth Platform > Branding**:
   * **App name**: `WinCloudMount` (atau nama bebas).
   * **User support email**: Pilih email Google Anda.
   * **App domain** (wajib diisi agar tombol *Publish app* aktif di UI terbaru):
     * **Application home page**: `https://github.com/yahyazakaria29/win-cloud-mount` (atau halaman pribadi Anda).
     * **Application privacy policy link**: `https://github.com/yahyazakaria29/win-cloud-mount/blob/main/SECURITY.md`
   * **Authorized domains**: Klik **+ Add domain**, lalu masukkan domain dari URL di atas (misalnya `github.com`).
   * **Developer contact information**: Masukkan alamat email Anda.
   * Klik **Save**.

2. Buka menu **Google Auth Platform > Audience**:
   * Pada **User type**, pilih **External**.
   * Pada **Publishing status**, klik **Publish app** lalu **Confirm** sehingga status berubah menjadi **In production**.
   * Anda **tidak perlu** mengajukan verifikasi Google (*Prepare for verification*) karena aplikasi ini hanya untuk pemakaian pribadi Anda sendiri.

> **Kenapa disarankan `In production` daripada mode `Testing`?**
> Pada mode `Testing`, token OAuth Google hangus setiap **7 hari** dan setiap akun Gmail baru harus didaftarkan manual di **Test users** (jika lupa, muncul error `Error 403: access_denied`). Dengan status **In production**, token bertahan jangka panjang dan seluruh akun Google Drive Anda langsung bisa login memakai Client ID yang sama.
>
> *(Alternatif jika tidak ingin mengisi App domain: biarkan di mode `Testing`, lalu tambahkan semua email akun Drive Anda di bagian **Audience > Test users > + Add users**, dengan konsekuensi harus `rclone config reconnect` tiap 7 hari.)*

---

## Langkah 4: Buat OAuth Client ID & Secret

1. Di menu navigasi kiri, buka **Google Auth Platform > Clients** (atau **APIs & Services > Credentials**).
2. Klik **+ Create client** (atau **+ CREATE CREDENTIALS > OAuth client ID**).
3. Pada **Application type**, pilih **Desktop app**.
4. Beri nama, misalnya `WinCloudMount Client`, lalu klik **Create**.
5. Salin **Client ID** (`...apps.googleusercontent.com`) dan **Client Secret** (`GOCSPX-...`).

---

## Langkah 5: Pasang Kredensial ke Rclone

Buka terminal PowerShell, lalu jalankan:

```powershell
rclone config
```

Ulangi langkah ini untuk setiap remote Google Drive Anda (`gdrive_1`, `gdrive_2`, dll.):
1. Pilih **`e`** (*Edit existing remote*), lalu pilih nomor remote Google Drive Anda.
2. Pada `client_id>`, tempel **Client ID** pribadi Anda.
3. Pada `client_secret>`, tempel **Client Secret** Anda.
4. Pada `scope>`, pilih **`1`** (*Full access all files*).
5. Pada `service_account_file>`, kosongkan (tekan **Enter**).
6. Pada `Edit advanced config?`, pilih **`n`**.
7. Pada `Use web browser to automatically authenticate?`, pilih **`y`**.
8. Pada `Configure this as a Shared Drive (Team Drive)?`, pilih **`n`** (kecuali remote tersebut memang Team Drive organisasi).
9. Di browser yang terbuka, login menggunakan akun Google milik remote tersebut:
   * Jika muncul layar **"Google hasn't verified this app"**, klik **Advanced** lalu klik **Go to WinCloudMount (unsafe)**. Ini normal untuk aplikasi pribadi yang belum diajukan ke review publik Google.
   * Centang seluruh izin Google Drive lalu klik **Continue**.
10. Kembali ke terminal Rclone, ketik **`y`** untuk menyimpan. Setelah semua remote selesai, ketik **`q`** untuk keluar.

---

## Langkah 6: Restart Mount & Verifikasi

Restart mount agar perubahan aktif (cache VFS tidak perlu dihapus):

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action restart
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action test
```

Pastikan pada output `-Action test` muncul baris:
`Client ID   : [CUSTOM] Personal OAuth client configured`

---

## Pemecahan Masalah Umum

* **`Error 403: access_denied` ("has not completed the Google verification process")**: Status aplikasi di Google Auth Platform masih **Testing** dan akun Gmail yang dipakai login belum masuk daftar **Test users**. Ubah status ke **In production** di menu **Audience** (Langkah 3), atau tambahkan akun Gmail tersebut ke **Test users**.
* **Tombol `Publish app` berwarna abu-abu / tidak bisa diklik**: Halaman **Branding** belum lengkap. Isi **Application home page**, **Application privacy policy link**, dan **Authorized domains** lalu klik **Save**.
