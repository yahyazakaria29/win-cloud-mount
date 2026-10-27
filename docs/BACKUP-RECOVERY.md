# Backup & Recovery Guide / Panduan Pencadangan & Pemulihan

This guide outlines best practices for backing up your cloud configurations and recovering WinCloudMount on a new Windows installation or after a system reset.

---

## 1. Essential Configuration Files / Berkas Konfigurasi Utama

WinCloudMount separates authentication credentials from mount topology:

| File / Berkas | Location / Lokasi | Content / Isi | Sensitivity / Sensitivitas |
| ------------- | ----------------- | ------------- | -------------------------- |
| `rclone.conf` | `%APPDATA%\rclone\rclone.conf` | Cloud provider OAuth tokens & client IDs | **High / Rahasia** |
| `drives.json` | `%LOCALAPPDATA%\WinCloudMount\config\drives.json` | Drive letters, labels, cache paths, & flags | Low / Non-sensitif |

---

## 2. Automated Backup / Pencadangan Otomatis

You can quickly export both configurations to a secure backup directory using PowerShell:

```powershell
# Set your secure backup destination (e.g. encrypted external drive or secure folder)
$BackupDir = "$HOME\Documents\WinCloudMount-Backup-$(Get-Date -Format 'yyyyMMdd')"
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

# 1. Backup Rclone configuration
$rcloneConf = "$env:APPDATA\rclone\rclone.conf"
if (Test-Path $rcloneConf) {
    Copy-Item -LiteralPath $rcloneConf -Destination (Join-Path $BackupDir "rclone.conf") -Force
    Write-Host "[OK] Backed up rclone.conf" -ForegroundColor Green
}

# 2. Backup WinCloudMount drives topology
$drivesJson = "$env:LOCALAPPDATA\WinCloudMount\config\drives.json"
if (Test-Path $drivesJson) {
    Copy-Item -LiteralPath $drivesJson -Destination (Join-Path $BackupDir "drives.json") -Force
    Write-Host "[OK] Backed up drives.json" -ForegroundColor Green
}

Write-Host "Backup completed to: $BackupDir" -ForegroundColor Cyan
```

> **Security Warning / Peringatan Keamanan:**  
> Never upload `rclone.conf` to public repositories or unencrypted cloud storage. Store your backups in an encrypted container (BitLocker, VeraCrypt) or password-protected archive.

---

## 3. Restoring on a New PC / Pemulihan di PC Baru

### Step 1: Install WinCloudMount
On the target machine, run the one-line installer in PowerShell:
```powershell
irm https://raw.githubusercontent.com/yahyazakaria29/win-cloud-mount/v1.0.0/install.ps1 | iex
```

### Step 2: Restore Configuration Files
Restore your backed up configuration files to their respective locations:
```powershell
# Restore Rclone configuration
$rcloneDir = "$env:APPDATA\rclone"
if (-not (Test-Path $rcloneDir)) { New-Item -ItemType Directory -Path $rcloneDir -Force | Out-Null }
Copy-Item -LiteralPath "Path\To\Backup\rclone.conf" -Destination "$rcloneDir\rclone.conf" -Force

# Restore WinCloudMount drives topology
$wcmConfigDir = "$env:LOCALAPPDATA\WinCloudMount\config"
Copy-Item -LiteralPath "Path\To\Backup\drives.json" -Destination "$wcmConfigDir\drives.json" -Force
```

### Step 3: Test and Mount
```powershell
cd "$env:LOCALAPPDATA\WinCloudMount"
powershell -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action start
```

---

## 4. Troubleshooting Common Issues / Pemecahan Masalah

### Token Expiration or Authentication Errors
If a cloud drive fails to mount with `oauth2: token expired and refresh token is invalid`:
1. Run `rclone config` in terminal.
2. Select the expired remote (`e`) to edit.
3. Choose `Reconnect / Re-authenticate` to refresh the OAuth token in your browser.
4. Restart mounts:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action restart
   ```

### Clearing Stale VFS Cache
If local drive space is low or offline files become corrupted:
```powershell
# 1. Stop all mounts
powershell -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action stop

# 2. Clean cache directory
Remove-Item -Path "$env:LOCALAPPDATA\WinCloudMount\.cache\*" -Recurse -Force

# 3. Restart mounts
powershell -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action start
```
