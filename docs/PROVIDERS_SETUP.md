# Cloud Provider Setup Guide

WinCloudMount uses standard Rclone remotes configured in `%APPDATA%\rclone\rclone.conf`.

---

## 1. Google Drive (Personal & Workspace / Educational)

1. Open your terminal and run:
   ```bash
   rclone config
   ```
2. Press `n` for **New remote**.
3. Name your remote (e.g. `gdrive_personal` or `gdrive_ut`).
4. In storage type, enter `drive` (Google Drive).
5. Leave `client_id` and `client_secret` blank (or enter your own GCP OAuth credentials for higher API throughput).
6. Scope: select `1` (Full access all files).
7. Root folder ID: leave blank (unless you want to mount a specific subfolder).
8. Service account credentials: leave blank.
9. Edit advanced config: `n`.
10. Use auto config: `y` (This will launch your default web browser to authorize Google OAuth).
11. Grant permissions and return to terminal. Confirm with `y`.

---

## 2. Microsoft OneDrive (Personal & Business / SharePoint)

1. Run `rclone config` -> `n` (New remote).
2. Name: `onedrive_work`.
3. Storage type: enter `onedrive`.
4. Leave `client_id` and `client_secret` blank for standard login.
5. Choose region: `1` (Microsoft Cloud Global).
6. Auto config: `y` -> Authorize via web browser.
7. Select drive type: `1` (OneDrive Personal or Business).
8. Confirm configuration with `y`.

---

## 3. Nextcloud / ownCloud / WebDAV

1. Run `rclone config` -> `n` (New remote).
2. Name: `nextcloud_storage`.
3. Storage type: `webdav`.
4. URL: `https://your-nextcloud-domain.com/remote.php/dav/files/USERNAME/`
5. Vendor: `nextcloud`.
6. User: your Nextcloud username.
7. Password: generate and use an **App Password** from Nextcloud Security Settings.

---

## 4. Amazon S3 / Cloudflare R2 / MinIO / Ceph

1. Run `rclone config` -> `n` (New remote).
2. Name: `s3_backup`.
3. Storage type: `s3`.
4. Provider: select `AWS`, `Cloudflare`, `Minio`, or `Ceph`.
5. Enter your `Access Key ID` and `Secret Access Key`.
6. Region and Endpoint: configure according to your provider (e.g., `<accountid>.r2.cloudflarestorage.com` for Cloudflare R2).

---

## 5. Official Drive Icons & Custom Branding

WinCloudMount includes bundled high-resolution multi-size Windows `.ico` assets in `assets/icons/`:
- `googledrive.ico` - Google Drive & Google Workspace
- `onedrive.ico` - Microsoft OneDrive, OneDrive for Business & SharePoint
- `dropbox.ico` - Dropbox
- `nextcloud.ico` - Nextcloud & ownCloud
- `box.ico` - Box.com
- `mega.ico` - MEGA Cloud
- `protondrive.ico` - Proton Drive
- `s3.ico` - Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, & MinIO

### Auto-Detection
If you leave the `"icon"` property blank, WinCloudMount automatically detects the provider based on your remote name or volume label (e.g. any remote containing `onedrive`, `dropbox`, `nextcloud`, `box`, `mega`, `proton`, `s3`, `b2`, `wasabi`).

### Custom Icon Specification
You can also explicitly specify an icon in `config/drives.json`:
```json
{
  "name": "onedrive-office",
  "remote": "onedrive_work:",
  "drive_letter": "F:",
  "volume_name": "OneDrive - Office",
  "icon": "assets/icons/onedrive.ico"
}
```

---

## 6. Integrating with WinCloudMount

Once remotes are configured, append them to `config/drives.json`:

```json
[
  {
    "name": "gdrive-personal",
    "remote": "gdrive_personal:",
    "drive_letter": "E:",
    "volume_name": "GoogleDrive - Yahya",
    "cache_dir": "D:/HermesAgent/cache/gdrive_personal",
    "cache_size": "20G"
  },
  {
    "name": "onedrive-office",
    "remote": "onedrive_work:",
    "drive_letter": "F:",
    "volume_name": "OneDrive - Office",
    "cache_dir": "D:/HermesAgent/cache/onedrive_work",
    "cache_size": "15G"
  }
]
```
