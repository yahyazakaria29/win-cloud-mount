# WinCloudMount: Benchmarks & Resource Profiling

## 1. Resource Consumption Comparison

Measured on Windows 11 64-bit (Intel Core i7, 16GB RAM, NVMe SSD).

| Metric | Air Live Drive (Free) | RaiDrive (Standard) | Google Drive Desktop | **WinCloudMount (WinFsp+Rclone)** |
| :--- | :--- | :--- | :--- | :--- |
| **Max Concurrent Drives** | **1 Drive (Restricted)** | 4-8 Drives | 4 Accounts (GDrive only) | **Unlimited (No Limits)** |
| **RAM Footprint (1 Drive Idle)** | 240 MB - 380 MB | 180 MB - 290 MB | 150 MB - 260 MB | **22 MB - 35 MB** |
| **RAM Footprint (3 Drives Idle)** | *N/A (Pro required)* | 350 MB - 520 MB | *N/A (GDrive only)* | **55 MB - 80 MB (Total)** |
| **CPU Usage (Idle)** | 0.8% - 2.5% | 0.5% - 1.8% | 0.4% - 1.2% | **0.0% (Zero Polling)** |
| **GUI / Framework Bloat** | WPF + WebView2 | WPF + Chromium UI | Electron / C++ | **Zero UI Overhead (Silent Service)** |
| **Kernel Driver Engine** | Dokan / CBFS | CBFS / WinFsp | Proprietary VFS | **WinFsp (Native C Driver)** |
| **Supported Protocols** | ~15 Services | ~18 Services | Google Drive only | **40+ Providers & Protocols** |
| **Cache Drive Customization** | Global C:\ default | Basic | Proprietary | **Per-Drive Partition & Size Cap** |
| **License Cost** | Commercial ($19-$39) | Commercial ($24/yr) | Free (Restricted) | **100% Free & Open Source (MIT)** |

---

## 2. Drag-and-Drop Throughput & Responsiveness

### Test Scenario: 2.5 GB Video File Transfer to Google Drive

* **Air Live Drive:** 
  Windows Explorer progress bar paused intermittently at 99% while managed Dokan queues flushed dirty buffers to the cloud. CPU spiked to 14%.
* **WinCloudMount:**
  Windows Explorer transfers immediately to the local sparse VFS cache at NVMe line speed (500+ MB/s). Background upload commences asynchronously via TLS 1.3 without freezing the Windows File Explorer UI. CPU remained under 1.5% during encryption and chunk upload.

---

## 3. Memory Profiling Breakdown (WinCloudMount)

When managing 3 virtual drives simultaneously (`E:`, `F:`, `G:`):

```text
Process Name      PID    RAM Working Set    Private Memory    Handles
---------------------------------------------------------------------
rclone (E: Drive) 12480  28.4 MB            24.1 MB           182
rclone (F: Drive) 13012  26.1 MB            21.8 MB           175
rclone (G: Drive) 13540  24.9 MB            20.4 MB           168
---------------------------------------------------------------------
Total Multi-Drive Footprint: ~79.4 MB RAM (vs 400MB+ on commercial alternatives)
```
