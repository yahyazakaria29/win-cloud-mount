<div align="center">

# WinCloudMount 🚀

### *High-Performance, Ultra-Lightweight Multi-Cloud Virtual Drive Orchestrator for Windows.*

Seamlessly mount unlimited cloud storage accounts (Google Drive, OneDrive, Nextcloud, Mega, S3) as native Windows drives (`E:`, `F:`, `G:`, etc.) with full drag-and-drop, high-speed VFS caching, and zero background UI bloat.

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://microsoft.com/windows"><img src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20(64--bit)-0078D6?logo=windows" alt="Platform"></a>
  <a href="https://winfsp.dev"><img src="https://img.shields.io/badge/Engine-WinFsp%20%2B%20Rclone-success" alt="Engine"></a>
  <a href="docs/BENCHMARKS.md"><img src="https://img.shields.io/badge/RAM%20per%20drive-~25MB-brightgreen" alt="Memory Footprint"></a>
  <a href="https://ko-fi.com/anakrantau29"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=ko-fi&logoColor=white" alt="Support on Ko-fi"></a>
  <a href="CONTRIBUTING.md"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs Welcome"></a>
</p>

🌐 [English](README.md) • [Bahasa Indonesia](README.id.md)

[ 🚀 Quick Start ](#-quick-start-guide) • [ 🎨 Supported Providers & NAS ](#-supported-cloud-providers--home-server-nas) • [ 📊 Benchmarks ](docs/BENCHMARKS.md) • [ 💾 Backup Guide ](docs/BACKUP-RECOVERY.md) • [ 🔒 Security ](SECURITY.md) • [ ☕ Support ](#-support-the-project) • [ 🗑️ Uninstall ](#️-uninstallation--teardown)

---

<p align="center">
  <img src="docs/images/showcase.png" alt="WinCloudMount in Windows 11 File Explorer" width="950">
</p>

---

</div>

## ⚡ Why WinCloudMount Over Commercial Alternatives?

Commercial utilities like **Air Live Drive** and **RaiDrive** impose arbitrary limits on free tiers (e.g. max 1 drive, transfer throttling, nag screens) and consume hundreds of megabytes of RAM running heavyweight .NET/WPF and embedded Chromium browsers in the background.

| Feature | Air Live Drive (Free) | RaiDrive (Standard) | **WinCloudMount** |
| :--- | :--- | :--- | :--- |
| **Simultaneous Cloud Drives** | **1 Drive (Hard Limit)** | 4-8 Drives | **No software limit (all available drive letters)** |
| **Idle Memory Consumption** | ~250 MB – 400 MB | ~180 MB – 300 MB | **~25 MB – 35 MB working set per drive (~60–75 MB private bytes)** |
| **Idle CPU Usage** | 0.8% – 2.5% (polling) | 0.5% – 1.8% | **< 0.1% idle (Native WinFsp kernel proxy, zero UI polling)** |
| **Supported Cloud Backends** | ~15 Providers | ~18 Providers | **40+ Backends (via Rclone)** |
| **VFS Cache Relocation** | Default System `C:\` | Basic | **Per-Drive Partition & Disk Cap** |
| **Drag-and-Drop Reliability** | Can hang on large bursts | Can hang on large bursts | **Asynchronous Local VFS Staging** |
| **Background Execution** | Heavy UI / System Tray | Heavy UI / System Tray | **Zero-Window Silent Service** |
| **Cost** | Commercial ($19–$39) | Commercial ($24/year) | **100% Free & Open Source (MIT)** |

---

## 🛠️ Architecture

WinCloudMount combines two battle-tested open-source engines:
1. **[WinFsp (Windows File System Proxy)](https://winfsp.dev):** A high-performance kernel filter driver that exposes cloud storage as true NTFS/FAT virtual volumes.
2. **[Rclone](https://rclone.org):** The Swiss army knife of cloud storage, configured with tuned VFS read-ahead chunk streaming and cache quotas.

```text
[ Windows Explorer / Office / Adobe ]
                 │
                 ▼ Win32 File I/O
       [ WinFsp Kernel Proxy ]
                 │
                 ▼ Fast User-Mode Ring Buffer
   [ WinCloudMount (Rclone Engine) ]
                 │
         ┌───────┴───────────────────┐
         ▼                           ▼
[ Local VFS Cache (.cache/) ]   [ Remote Cloud APIs ]
(Instant drag-and-drop)          (TLS 1.3 Asynchronous Upload)
```

For complete technical specifications, see [ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## 🚀 Quick Start Guide

### 1. Install (choose one option)

Both options produce the same result. Pick whichever you are comfortable with.

#### Option A: One-line install (recommended for most users)
Open **PowerShell** (no need for "Run as administrator") and paste:

```powershell
irm https://raw.githubusercontent.com/yahyazakaria29/win-cloud-mount/v1.0.0/install.ps1 | iex
```

> 🔒 **Pinned release, not `main`:** the one-liner installs from the `v1.0.0` release tag, so you get a reviewed, versioned snapshot — not whatever is currently on the `main` branch. New releases require bumping the tag in this command.

What it does:
1. Downloads WinCloudMount to `%LOCALAPPDATA%\WinCloudMount` (no Git required).
2. Installs **WinFsp** and **Rclone** via `winget`. Windows may show one permission prompt (UAC) for the WinFsp driver.
3. Creates `config\drives.json` from the example template (an existing one is **never overwritten**).
4. Offers to open `rclone config` so you can connect your first cloud account.

Running the same command again later **updates** the scripts and keeps your config, cache and logs.

> 🔒 **Prefer to read the script first?** That's good practice. Download it, review it, then run it:
> ```powershell
> irm https://raw.githubusercontent.com/yahyazakaria29/win-cloud-mount/v1.0.0/install.ps1 -OutFile install.ps1
> notepad install.ps1
> powershell -ExecutionPolicy Bypass -File .\install.ps1
> ```
> Custom location: set `$env:WCM_INSTALL_DIR = "D:\WinCloudMount"` before running.

#### Option B: Manual install (Git / ZIP)
```powershell
git clone https://github.com/yahyazakaria29/win-cloud-mount.git
cd win-cloud-mount
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install-Prerequisites.ps1
```
*No Git? Click **Code → Download ZIP** on GitHub, extract it, open PowerShell in that folder, and run the last command.*

### 2. Configure Your Cloud Accounts
Add your cloud storage accounts using Rclone's interactive CLI:

```bash
rclone config
```
*Follow the interactive prompts (e.g., select `drive` for Google Drive or `onedrive` for Microsoft OneDrive). See [PROVIDERS_SETUP.md](docs/PROVIDERS_SETUP.md) for detailed configuration steps. For Google Drive users experiencing rate limits, follow [GOOGLE_CLIENT_ID_SETUP.md](docs/GOOGLE_CLIENT_ID_SETUP.md) to create your own free dedicated API client.*

### 3. Setup Your Drives
Copy the template configuration file:
```bash
cp config/drives.example.json config/drives.json
```
Edit `config/drives.json` to assign your cloud remotes to drive letters:

```json
[
  {
    "name": "gdrive-personal",
    "remote": "gdrive_personal:",
    "drive_letter": "E:",
    "volume_name": "GoogleDrive - Personal",
    "cache_dir": ".cache/gdrive_personal",
    "cache_size": "20G"
  },
  {
    "name": "onedrive-campus",
    "remote": "onedrive_campus:",
    "drive_letter": "F:",
    "volume_name": "OneDrive - Campus",
    "cache_dir": ".cache/onedrive_campus",
    "cache_size": "15G"
  }
]
```

### 4. Mount Drives
Mount all configured drives simultaneously:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action start
```

Inspect active drives and real-time RAM/CPU efficiency:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action status
```

### 5. Enable Silent Autostart on Windows Logon
To mount your drives automatically on system boot without any visible terminal windows:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Setup-Autostart.ps1 -Action enable
```

---

## ⚙️ VFS Performance Tuning

WinCloudMount applies fine-tuned VFS parameters out of the box:

* `--vfs-cache-mode full`: Mandatory for Windows Explorer. Enables sparse file emulation so Microsoft Office lock files and video editors can read/write without `0x80070032` errors.
* `--buffer-size 16M`: Keeps RAM consumption bounded at ~25MB per drive (unlike unconstrained tools that eat 400MB+).
* `--vfs-read-chunk-size 16M --vfs-read-chunk-size-limit 256M`: Streams files on-demand in small progressive chunks. Video playback begins in milliseconds without downloading entire gigabyte-sized files.
* `--cache-dir .cache/...`: Safely confines disk cache inside the project directory (or secondary partition), preventing system drive `C:` exhaustion.

---

## 🎨 Supported Cloud Providers & Home Server NAS

WinCloudMount natively supports 40+ backends and includes official high-resolution Windows `.ico` assets with **Smart Auto-Detection**:
* **Google Drive / Google Workspace** (`assets/icons/googledrive.ico`)
* **Microsoft OneDrive / SharePoint** (`assets/icons/onedrive.ico`)
* **Dropbox** (`assets/icons/dropbox.ico`)
* **Nextcloud / ownCloud** (`assets/icons/nextcloud.ico`)
* **Box.com** (`assets/icons/box.ico`)
* **MEGA Cloud** (`assets/icons/mega.ico`)
* **Proton Drive** (`assets/icons/protondrive.ico`)
* **Amazon S3 / Cloudflare R2 / Backblaze B2 / Wasabi / MinIO** (`assets/icons/s3.ico`)
* **Home Server / Homelab / NAS**: TrueNAS, Synology, QNAP, Linux servers via **SFTP/SSH**, **SMB/Samba**, **WebDAV**, or **MinIO S3**.

See [docs/PROVIDERS_SETUP.md](docs/PROVIDERS_SETUP.md) for step-by-step connection guides for every provider.

---

## 🔍 CLI Reference (`Mount-Manager.ps1`)

| Command | Description |
| :--- | :--- |
| `.\scripts\Mount-Manager.ps1 -Action start` | Mounts all configured drives. |
| `.\scripts\Mount-Manager.ps1 -Action start -DriveLetter E:` | Mounts only drive `E:`. |
| `.\scripts\Mount-Manager.ps1 -Action stop` | Unmounts all virtual cloud drives. |
| `.\scripts\Mount-Manager.ps1 -Action stop -DriveLetter E:` | Unmounts only drive `E:`. |
| `.\scripts\Mount-Manager.ps1 -Action restart` | Restarts all active mount processes. |
| `.\scripts\Mount-Manager.ps1 -Action status` | Shows process PIDs, RAM usage, and explorer volumes. |
| `.\scripts\Mount-Manager.ps1 -Action test` | Validates configuration integrity and rclone remotes. |

---

## 🗑️ Uninstallation & Teardown

### Option A: One-line uninstaller (instant cleanup)
Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/yahyazakaria29/win-cloud-mount/v1.0.0/uninstall.ps1 | iex
```

What it does interactively:
1. Stops all running virtual cloud drive daemons safely.
2. Removes the `WinCloudMount-Autostart` scheduled task.
3. Cleans custom drive labels, icons, and stale mount points from the Windows Registry (`HKCU`).
4. Asks if you want to purge local offline VFS cache files.
5. Asks if you want to uninstall WinFsp and Rclone via Winget.
6. Deletes the `%LOCALAPPDATA%\WinCloudMount` installation directory cleanly.

### Option B: Manual uninstaller
If you cloned the repository manually, run the local uninstaller script:

```powershell
# Standard unmount, remove autostart task, and clean registry drive branding
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Uninstall.ps1

# Optional: also purge local VFS cache files
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Uninstall.ps1 -PurgeCache

# Full wipe: unmount + remove autostart + purge cache + uninstall WinFsp & Rclone via Winget
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Uninstall.ps1 -PurgeCache -RemovePrerequisites
```

---

## 🛡️ Security & Privacy

* **Zero Cloud Intermediaries:** Credentials, OAuth tokens, and encryption keys remain exclusively on your local machine in `%APPDATA%\rclone\rclone.conf`.
* **Private by Default:** `config/drives.json` and all local cache/token files are strictly ignored by `.gitignore` to prevent accidental credential leakage to Git remotes.
* **Process & Registry Isolation:** Mount processes and Windows Explorer registry updates are scoped strictly to WinCloudMount-managed instances.
* **Symlink Handling (`--links`):** Symlink translation is kept enabled so Windows Explorer reparse-point probes don't spam logs with `symlinks not supported` errors. A symlink stored on an untrusted cloud share can resolve to a path *outside* the mounted tree; rclone's write-through VFS protects against writes via symlinks, but be cautious when mounting shares you don't fully trust.
* **Security Policy & Backups:** See [SECURITY.md](SECURITY.md) for our threat model and vulnerability disclosure policy, and [docs/BACKUP-RECOVERY.md](docs/BACKUP-RECOVERY.md) for safe configuration backup procedures.

---

<div align="center">

## ☕ Support the Project

If **WinCloudMount** saves your system RAM and cloud subscription budget, consider buying me a coffee to support ongoing development!

<p align="center">
  <a href="https://ko-fi.com/anakrantau29">
    <img src="https://img.shields.io/badge/Ko--fi-Buy_Me_a_Coffee-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Buy Me a Coffee on Ko-fi">
  </a>
  &nbsp;&nbsp;
  <a href="https://saweria.co/anakrantau29">
    <img src="https://img.shields.io/badge/Saweria-Traktir_Kopi_(QRIS)-FFC107?style=for-the-badge&logo=google-pay&logoColor=black" alt="Traktir Kopi via Saweria">
  </a>
</p>

<sub>🌍 **Global:** Credit Card • PayPal • Apple Pay • Google Pay</sub><br>
<sub>🇮🇩 **Indonesia:** QRIS • ShopeePay • GoPay • OVO • DANA • Bank Transfer</sub>

</div>

---

## 🤝 Contributing

Contributions, bug reports, and optimizations are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting pull requests.

## 📄 License

This project is licensed under the [MIT License](LICENSE).
