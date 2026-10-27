# WinCloudMount: Benchmarks & Resource Profiling

This document outlines the resource consumption model, benchmark methodology, and profiling data for WinCloudMount under Windows 11.

---

## 1. Resource Consumption & Footprint

WinCloudMount measurements below were taken on Windows 11 64-bit (Intel Core i7, NVMe SSD) running 4 simultaneous cloud mounts (`E:`, `F:`, `G:`, `O:`). WinCloudMount's own figures are reproducible with the command in §2. Third-party (Air Live Drive / RaiDrive / Google Drive Desktop) figures are qualitative estimates for orientation only — they were **not** independently measured for this project and must not be cited as benchmark data.

| Metric | Air Live Drive (Free) | RaiDrive (Standard) | Google Drive Desktop | **WinCloudMount (WinFsp + Rclone)** |
| :--- | :--- | :--- | :--- | :--- |
| **Max Concurrent Drives** | 1 Drive (License restricted) | 4–8 Drives | 4 Accounts (GDrive only) | **No software limit (all free Windows letters)** |
| **RAM Footprint (1 Drive Idle)** | hundreds of MB (heavyweight runtime) | hundreds of MB (heavyweight runtime) | hundreds of MB (heavyweight runtime) | **~24 MB – 28 MB Working Set (~68 MB Private)** |
| **RAM Footprint (4 Drives Idle)** | *N/A (Pro required)* | higher (additive per-drive) | *N/A (GDrive only)* | **~98 MB – 115 MB Working Set (Total)** |
| **CPU Usage (Idle)** | non-zero (UI polling) | non-zero (UI polling) | non-zero (UI polling) | **< 0.1% (Kernel event proxy via WinFsp)** |
| **Runtime Overhead** | WPF / WebView2 background | WPF / Chromium background | Electron / C++ | **Zero UI overhead (Compiled Go + C kernel driver)** |
| **Kernel Driver Engine** | Dokan / CBFS | CBFS / WinFsp | Proprietary VFS | **WinFsp (Native Windows File System Proxy)** |
| **Supported Backends** | ~15 Providers | ~18 Providers | Google Drive only | **40+ Backends (Google Drive, OneDrive, S3, WebDAV, SFTP...)** |
| **VFS Cache Relocation** | Default system `C:\` | Basic | Proprietary | **Full per-drive custom path, cap & min-free-space** |
| **License Cost** | Commercial ($19–$39) | Commercial ($24/year) | Free (Proprietary) | **100% Free & Open Source (MIT)** |

---

## 2. Real-World Process Profiling

To independently verify memory consumption on your machine, run this command in PowerShell while mounts are active:

```powershell
Get-Process -Name rclone | Select-Object Id, ProcessName,
    @{Name="WorkingSet_MB"; Expression={[math]::Round($_.WorkingSet64 / 1MB, 2)}},
    @{Name="PrivateBytes_MB"; Expression={[math]::Round($_.PrivateMemorySize64 / 1MB, 2)}},
    @{Name="Handles"; Expression={$_.Handles}}
```

### Typical Live Telemetry Sample (4 Active Cloud Drives)

```text
       Id ProcessName WorkingSet_MB PrivateBytes_MB Handles
       -- ----------- ------------- --------------- -------
    27448 rclone              24.16           68.04     158
    27480 rclone              27.91           71.49     174
    27512 rclone              23.63           67.06     158
    27544 rclone              25.04           69.17     162
```

### Understanding the Numbers: Working Set vs. Private Bytes
* **Working Set (~24–28 MB per drive):** The actual physical RAM currently committed by the Windows memory manager for the running Go binary and runtime structures.
* **Private Bytes (~67–71 MB per drive):** The virtual memory address space allocated by the Go runtime garbage collector (including pre-allocated heap spans and memory-mapped VFS structures). Go does not immediately return virtual space to the OS until system memory pressure warrants it.
* **Combined Footprint:** Even with 4 cloud drives actively mounted, the total combined physical RAM consumption sits around **100 MB**, roughly one-fourth of a single Chromium or Electron-based commercial cloud client.

---

## 3. Throughput & VFS Staging Performance

### Test Scenario: 2.5 GB Archive File Drag-and-Drop
* **Local Ingestion:**
  When copying files into a WinCloudMount drive, writes are handled by the local VFS cache (`--vfs-cache-mode full`). Windows File Explorer writes to the local NVMe/SSD at bus speed without hanging the Explorer UI thread.
* **Asynchronous Cloud Sync:**
  Once the file is safely staged locally, the rclone engine initiates an asynchronous multipart chunked upload via TLS 1.3 using `--drive-chunk-size 32M` (or configured chunk size).
* **Crash Resiliency:**
  Even if the system reboots or the network drops during an upload, rclone's `.cache/<drive>/vfsMeta` database tracks pending files (`"Dirty": true`) and automatically resumes synchronization upon reconnection.
* **Disk Space Safety:**
  With `--vfs-cache-min-free-space 10G`, rclone automatically monitors host partition space and evicts older, clean cached blocks before the host drive runs out of disk space.
