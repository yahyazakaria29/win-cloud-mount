# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.1.x   | :white_check_mark: |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

---

## Security Architecture & Threat Model

WinCloudMount is designed with a minimal attack surface and strict principle of least privilege:

1. **No Administrator Privileges Required:**  
   All mounting, caching, and registry branding operations run entirely within the current user context (`HKCU:\` and `%LOCALAPPDATA%`). No root/SYSTEM access is needed for daily operations.

2. **Credential Isolation & Non-Interactive Safety:**  
   WinCloudMount **never** requests, reads, stores, or transmits your cloud credentials or OAuth tokens. All authentication tokens are handled exclusively by [Rclone](https://rclone.org) inside `%APPDATA%
clone
clone.conf`.
   - Operations pass `--ask-password=false` to guarantee daemon commands fail fast rather than hang silently awaiting interactive password input in non-interactive / headless background contexts.
   - For shared or multi-user workstations, encrypting your `rclone.conf` with a master configuration password via `rclone config` is strongly recommended.
   - The repository's `.gitignore` explicitly blocks all configuration, log, and cache files from ever being committed.

3. **Argument Injection Defense:**  
   All user-supplied configuration parameters (remote identifiers, drive letters, volume labels, cache paths) undergo strict validation against command injection, control characters (`\p{Cc}`), and literal double quotes before execution. Parameters passed to native binaries are processed via Win32 `CommandLineToArgvW` escaping (`ConvertTo-RcloneArg`) to eliminate argument-breakout and trailing backslash traps.

4. **Strict Process & Registry Scoping:**  
   Mount management scripts only monitor and terminate `rclone.exe` instances launched specifically from the WinCloudMount installation directory and targeting configured virtual drives. Registry cleanup is confined to WinCloudMount drive branding keys and unmounted rclone mount points.

5. **Resource & Disk Exhaustion Safeguards:**  
   VFS cache operations enforce a minimum free disk space threshold (`--vfs-cache-min-free-space`, default `10G`) to protect the host operating system drive from storage exhaustion during large background writes. Log files automatically rotate at 5 MB to prevent unbounded disk growth.

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
