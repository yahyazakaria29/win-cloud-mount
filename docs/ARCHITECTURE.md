# WinCloudMount: Technical Architecture

## 1. High-Level System Architecture

WinCloudMount bridges Windows user-space file operations directly to multi-cloud and NAS storage backends without third-party commercial sync clients.

```text
+-----------------------------------------------------------------------+
|                       Windows File Explorer                           |
|       (Word, Excel, Video Editors, Adobe Premiere, CMD/PowerShell)     |
+-----------------------------------------------------------------------+
                                  |
               Win32 File I/O API (CreateFile, ReadFile)
                                  v
+-----------------------------------------------------------------------+
|                    WinFsp Kernel Proxy Driver                         |
|             (Native C Virtual File System Filter Driver)              |
+-----------------------------------------------------------------------+
                                  |
              Fast User-Mode IPC (Zero-Copy Ring Buffers)
                                  v
+-----------------------------------------------------------------------+
|                        Rclone Core (Go Engine)                        |
|                                                                       |
|   +---------------------------------------------------------------+   |
|   |                      VFS Caching Layer                        |   |
|   |  - Sparse File Cache (cache-mode full)                        |   |
|   |  - Parallel Chunk Streaming & Disk Read-Ahead                 |   |
|   |  - Dirty Upload Flusher & Minimum Free Space Guard            |   |
|   +---------------------------------------------------------------+   |
|                                  |                                    |
|   +---------------------------------------------------------------+   |
|   |                   Cloud Provider Adapters                     |   |
|   |   Google Drive | OneDrive | Nextcloud | Mega | S3 | SFTP     |   |
|   +---------------------------------------------------------------+   |
+-----------------------------------------------------------------------+
                                  |
                  TLS 1.3 / HTTPS REST API Streams
                                  v
+-----------------------------------------------------------------------+
|                     Cloud Provider Storage Nodes                      |
+-----------------------------------------------------------------------+
```

---

## 2. Kernel & User-Space Bridging: WinFsp vs Dokan

Air Live Drive and older cloud mounters rely on **Dokan** or **CBFS**:
* Dokan wraps user-mode filesystems through additional managed layers. Under sustained heavy I/O (such as video rendering or scrubbing large archives), managed garbage collection and inter-process locking can induce Explorer stalls and CPU spikes.
* **WinFsp (Windows File System Proxy)** is written in native C, using kernel I/O completion routines and zero-copy user-mode buffers to provide NTFS/FAT volume emulation without managed runtime overhead.

---

## 3. The VFS (Virtual File System) Cache Pipeline

Windows Explorer requires random-access byte-range operations, while cloud APIs (such as Google Drive REST, Microsoft Graph, or AWS S3) operate via HTTP GET/PUT requests.

The VFS caching layer reconciles this mismatch:

```text
[Windows Read Request: Bytes 5000-8000]
                  |
                  v
       Is byte-range cached locally?
          /                      \
        YES                       NO
        /                          \
Read from local sparse file   Fetch chunk(s) via HTTP Range requests
(Instant NVMe/SSD speed)      Store in .cache/<drive_name> + read-ahead
                              Serve bytes 5000-8000 to Windows
```

### Key VFS Configuration Flags & Rationale (v1.2.0)

1. **`--vfs-cache-mode full`**:
   * *Problem:* Windows applications such as Microsoft Office create temporary hidden lock files (`~$Document.docx`) and perform in-place byte overwrites.
   * *Solution:* `full` cache mode creates a local sparse representation of opened files. Modifications happen immediately on local disk, and dirty blocks queue for background upload. This avoids Windows error `0x80070032: The request is not supported`.

2. **`--attr-timeout 1s`**:
   * *Problem:* Caching file sizes and attributes in the WinFsp kernel for hours (`24h`) risks file truncation or trailing garbage bytes if a remote file changes length on another device.
   * *Solution:* Keeping `--attr-timeout` at `1s` prevents excessive kernel callbacks while ensuring fresh file sizes from VFS/rclone. Directory listings remain fast via `--dir-cache-time 72h` paired with `--poll-interval 1m` invalidation on polling remotes.

3. **`--buffer-size 16M` + `--vfs-read-ahead 128M`**:
   * *Problem:* Large per-handle RAM buffers consume hundreds of megabytes when opening many files concurrently.
   * *Solution:* Keeping `--buffer-size` at `16M` caps RAM per open stream, while `--vfs-read-ahead 128M` pre-stages sequential reads on local SSD storage.

4. **`--vfs-read-chunk-size 16M` + `--vfs-read-chunk-streams 4`**:
   * *Problem:* Single-stream sequential fetches underutilize broadband links on high-latency cloud APIs, while downloading multi-gigabyte videos upfront stalls playback.
   * *Solution:* Reads start in `16M` range chunks across `4` parallel streams on capable remotes. When Google Drive uses rclone's shared `client_id`, WinCloudMount automatically falls back to single-stream progressive chunking (`--vfs-read-chunk-size-limit 256M`) and omits aggressive pacer overrides to avoid `403 RATE_LIMIT_EXCEEDED` throttling.

5. **Backend-Aware Upload & Timestamp Handling**:
   * **Google Drive** (with custom `client_id`): `--drive-chunk-size 32M --transfers 6 --drive-pacer-min-sleep 10ms --drive-pacer-burst 200`.
   * **OneDrive**: `--onedrive-chunk-size 50Mi --transfers 4` (respects OneDrive's 320 KiB chunk-multiple rule while replacing the slow 10 MiB default).
   * **Accurate Modification Times**: Global `--no-modtime` is disabled for Drive/OneDrive so Explorer *Date Modified* stays accurate, and enabled by default only on object stores (`s3`, `swift`, `b2`).

6. **`--vfs-cache-max-size`, `--vfs-cache-min-free-space`, and `--vfs-cache-max-age 168h`**:
   * *Problem:* Unbounded cache directories risk exhausting system drive `C:`, while short 24h expirations force repeated re-downloads of active files.
   * *Solution:* WinCloudMount keeps clean cached files for up to 7 days (`168h`) within explicit size caps and minimum host free-space thresholds, while `Stop-DriveMount` waits up to 15 seconds for dirty uploads to flush before stopping a process.
