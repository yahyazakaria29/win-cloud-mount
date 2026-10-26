# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

---

## Security Architecture & Threat Model

WinCloudMount is designed with a minimal attack surface and strict principle of least privilege:

1. **No Administrator Privileges Required:**  
   All mounting, caching, and registry branding operations run entirely within the current user context (`HKCU:\` and `%LOCALAPPDATA%`). No root/SYSTEM access is needed for daily operations.

2. **Credential Isolation:**  
   WinCloudMount **never** requests, reads, stores, or transmits your cloud credentials or OAuth tokens. All authentication tokens are handled exclusively by [Rclone](https://rclone.org) inside `%APPDATA%\rclone\rclone.conf`.
   - For shared or multi-user workstations, encrypting your `rclone.conf` with a master configuration password via `rclone config` is strongly recommended.
   - The repository's `.gitignore` explicitly blocks all configuration, log, and cache files from ever being committed.

3. **Strict Process & Registry Scoping:**  
   Mount management scripts only monitor and terminate `rclone.exe` instances launched specifically from the WinCloudMount installation directory and targeting configured virtual drives. Registry cleanup is confined to WinCloudMount drive branding keys and unmounted rclone mount points.

4. **Resource & Disk Exhaustion Safeguards:**  
   VFS cache operations enforce a minimum free disk space threshold (`--vfs-cache-min-free-space`, default `5G`) to protect the host operating system drive from storage exhaustion during large background writes.

---

## Reporting a Vulnerability

If you discover a security vulnerability or credential leak risk in WinCloudMount, please help us resolve it responsibly:

1. **Do not open a public issue.**
2. Report the vulnerability privately via **GitHub Private Vulnerability Reporting** on the repository page:
   `https://github.com/yahyazakaria29/win-cloud-mount/security/advisories/new`
3. Include detailed steps to reproduce the issue, your operating system build, and any proof-of-concept scripts or logs (with sensitive tokens redacted).

### Response Timeline
- **Initial Response:** Within 48 hours.
- **Status & Triage:** Within 5 business days.
- **Fix & Advisory Release:** Coordinated disclosure once a verified patch is available.
