# Changelog

All notable changes to **WinCloudMount** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-10-26

### Added
- **Automated VFS Cache Minimum Free Space Enforcement:** Added `--vfs-cache-min-free-space` (default `10G`, configurable via `cache_min_free_space` in `drives.json` and validated by JSON schema) to safeguard host drives from disk exhaustion.
- **DNS & Network Race Condition Handler:** Intelligent DNS resolution retry (`Wait-ForNetworkConnection` with a fixed 2-second polling interval) before mounting drives during early Windows boot.
- **Automated Windows Autostart Manager:** Seamless Task Scheduler integration via `Setup-Autostart.ps1` with background launcher `launcher/SilentRunner.vbs` for zero-flash terminal experience.
- **One-Line Web Installer & Uninstaller:** Zero-click installation (`install.ps1`) and clean teardown (`uninstall.ps1`) via PowerShell `irm | iex`.
- **Explorer Custom Drive Icons & Labels:** Automated per-drive branding registry management with live shell cache refresh via `SHChangeNotify`.
- **CI / CD Quality Gates:** GitHub Actions workflow featuring PowerShell Language AST parsing, JSON schema validation, and PSScriptAnalyzer error-level linter checks.
- **Security Policy:** Added `SECURITY.md` defining supported versions, credential boundary threat model, and coordinated vulnerability disclosure channels.
- **Comprehensive Benchmark Suite:** Real-world verified performance benchmarks documented in `docs/BENCHMARKS.md` covering Working Set RAM, Private Bytes, and CPU utilization.

### Changed
- **Process Isolation Hardening:** Restricted process termination in `Mount-Manager.ps1` and uninstaller scripts to only match `rclone.exe` instances executed from the WinCloudMount installation directory.
- **Registry Cleanup Scoping:** Scoped Windows Explorer `MountPoints2` cleanup strictly to unmounted `*rclone*` entries and registered WinCloudMount drive letters, eliminating aggressive wildcard matching.
- **Performance Documentation Realignment:** Refined benchmark claims in `README.md` and `README.id.md` to reflect verified Windows 11 telemetry (< 0.1% idle CPU, ~25–35 MB Working Set vs ~60–75 MB Private Bytes per drive).

### Fixed
- Fixed drive initialization failure during Windows boot caused by transient DNS and network adapter race conditions.
- Fixed disconnected red-X drive icons in Windows Explorer using targeted `MountPoints2` registry sanitization.

[1.0.0]: https://github.com/yahyazakaria29/win-cloud-mount/releases/tag/v1.0.0
