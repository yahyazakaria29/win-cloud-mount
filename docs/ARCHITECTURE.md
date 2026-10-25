# WinCloudMount: Technical Architecture

## 1. High-Level System Architecture

WinCloudMount bridges Windows user-space file operations directly to multi-cloud object/file storage backends without requiring third-party commercial sync clients.

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
|   |  - Chunked Streaming & Read-Ahead (16MB chunks)               |   |
|   |  - Bi-directional Dirty Cache Flusher                         |   |
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
* Dokan implements a .NET wrapper around user-mode filesystems. Under continuous heavy I/O (e.g. video rendering or scrubbing large archives), Dokan's managed garbage collection and inter-process locking frequently induce Explorer lockups and high CPU spikes.
* **WinFsp (Windows File System Proxy)** is written entirely in native C, using high-performance kernel I/O completion routines and zero-copy user-mode buffers. It provides true NTFS/FAT volume emulation with zero managed runtime overhead.

---

## 3. The VFS (Virtual File System) Cache Pipeline

Windows Explorer requires random-access byte-range operations. Cloud APIs (such as Google Drive REST or AWS S3), conversely, operate via immutable HTTP GET/PUT operations. 

The VFS caching layer reconciles this impedance mismatch:

```text
[Windows Read Request: Bytes 5000-8000]
                  |
                  v
       Is byte-range cached locally?
          /                      \
        YES                       NO
        /                          \
Read from local sparse file   Download 16MB chunk via HTTP Range request
(Instant memory/disk speed)   Store chunk in cache directory (D:/Cache)
                               Serve bytes 5000-8000 to Windows
```

### Key VFS Configuration Flags & Rationale

1. **`--vfs-cache-mode full`**:
   * *Problem:* Windows applications like Microsoft Office write temporary hidden lock files (`~$Document.docx`) and perform in-place byte overwrites.
   * *Solution:* `full` cache mode creates a local sparse representation of opened files. File modifications occur instantaneously on the local disk, and modified (dirty) blocks are queued for background upload. This eliminates Windows error `0x80070032: The request is not supported`.

2. **`--buffer-size 16M`**:
   * *Problem:* Default unconstrained buffers can quickly consume hundreds of megabytes of RAM when multiple files or folders are opened simultaneously.
   * *Solution:* Capping stream memory buffers at 16MB keeps memory consumption bounded between 20MB and 35MB per mounted drive.

3. **`--vfs-read-chunk-size 16M --vfs-read-chunk-size-limit 256M`**:
   * *Problem:* Downloading an entire 10GB video file just to preview the first 5 seconds creates extreme network congestion and disk thrashing.
   * *Solution:* Rclone fetches data in progressive 16MB increments. Streaming begins in milliseconds, scaling up to 256MB chunks only for sustained sequential transfers.

4. **`--cache-dir <Dedicated Data Drive>`**:
   * *Problem:* Storing cache on partition `C:` risks filling the system drive during heavy workloads, degrading Windows performance.
   * *Solution:* WinCloudMount isolates cache paths inside the project root (`.cache/<drive_name>`) or configurable secondary partitions, enforcing hard capacity ceilings (`--vfs-cache-max-size`).
