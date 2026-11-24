# Changelog

All notable changes to **WinCloudMount** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.2.0] - 2026-11-24

### Added
- **Parallel Multi-Drive Startup & Wave Retries:** `Mount-Manager.ps1` launches unmounted drives concurrently and polls readiness in parallel waves, issuing a single `SHChangeNotify` refresh after mounts complete instead of refreshing Explorer per drive.
- **Backend-Aware VFS & Upload Tuning (`Build-RcloneMountArgs` / `Get-RemoteBackendInfo`):** Automatically detects backend type (`drive`, `onedrive`, `s3`, etc.) and whether Google Drive remotes use a custom OAuth `client_id`. Adds OneDrive multipart chunk tuning (`--onedrive-chunk-size 50Mi`), parallel read streams (`--vfs-read-chunk-streams 4`), disk read-ahead (`--vfs-read-ahead 128M`), extended cache retention (`--vfs-cache-max-age 168h`, `--dir-cache-time 72h`), and configurable `--transfers` / `--vfs-write-back` / `--log-level`.
- **Single-Instance Orchestrator Lock & Persistent Log (`logs/orchestrator.log`):** Serializes concurrent `start`/`stop`/`restart`/`unmount` calls via a project-scoped named `Mutex` and records startup, network, and error diagnostics with 5 MB rotation (`Invoke-LogRotation`).
- **Live VFS Cache & Dirty Upload Visibility:** `Mount-Manager.ps1 -Action status` displays per-drive `Cache (MB)`, `Dirty` upload counts, and filesystem `Format`, warning if any uploads are pending.
- **Cross-Drive Config Validation (`Get-DriveCollectionErrors`):** Rejects duplicate `drive_letter`, duplicate `name`, or shared `cache_dir` paths across `drives.json` entries, plus filename-safe `name` enforcement and expanded `schema.json` validation rules.
- **Headless Conhost Autostart & Network Recovery Trigger:** `Setup-Autostart.ps1` prefers native `conhost.exe --headless` on Windows 10 1903+ / Windows 11 (retaining `SilentRunner.vbs` as a fallback) and adds a NetworkProfile Event ID `10000` trigger so drives mount automatically when Wi-Fi or Ethernet connects after an offline boot.
- **Expanded Unit Tests (`tests/UnitTests.ps1`):** Added assertions for `Build-RcloneMountArgs`, `Get-DriveCollectionErrors`, `Get-CacheDirFromCmdline`, `Resolve-DriveIcon`, `Invoke-LogRotation`, `Test-UnsafePurgePath`, and expanded `Get-DriveConfigErrors` cases.

### Changed
- **Safer Kernel Attribute Caching & Timestamp Accuracy:** Lowered default `--attr-timeout` from `24h` to `1s` to prevent stale-size file truncation when remote files change outside Windows, and removed global `--no-modtime` so Google Drive and OneDrive preserve accurate modification timestamps (`--no-modtime` now defaults to S3/Swift/B2 or explicit `no_modtime: true`).
- **Guarded Google Drive Pacer Burst:** Applied `--drive-pacer-min-sleep 10ms --drive-pacer-burst 200` only when a custom OAuth `client_id` is configured, preventing shared-client 403 rate-limit storms.
- **TCP/TLS Network Readiness Check:** Upgraded `Wait-ForNetworkConnection` to probe port `443` reachability instead of relying on local DNS cache responses.
- **Graceful Dirty-Cache Drain & Permanent Error Short-Circuit:** `Stop-DriveMount` waits up to 15 seconds for dirty VFS uploads to flush before stopping, and startup skips remaining retry attempts when logs show permanent configuration or OAuth errors.
- **Streamlined Installer & Uninstaller:** `install.ps1` deploys only runtime files instead of copying `.github/` or `tests/`, and `uninstall.ps1` delegates to `scripts/Uninstall.ps1` to eliminate duplicated teardown code and double cache prompts.
- **Updated Documentation:** Rewrote `docs/GOOGLE_CLIENT_ID_SETUP.md` for the current Google Auth Platform (`Branding` + `Audience` + `Publish app`), updated `docs/ARCHITECTURE.md`, and completed all untranslated sections in `README.id.md`.

### Fixed
- **Drive-Letter Stop Matching Bug:** Fixed `Stop-DriveMount -DriveLetter C:` matching path substrings in `rclone.exe` command lines by comparing strictly against the parsed mount target drive letter.
- **Token-Aware `--cache-dir` Parsing (`Get-CacheDirFromCmdline`):** Fixed greedy regex capture on unquoted `--cache-dir` values.
- **Winget Uninstall Consistency:** Standardized `Rclone.Rclone --exact` and checked `$LASTEXITCODE` in `scripts/Uninstall.ps1`.
- **SECURITY.md Formatting & Linter Hygiene:** Fixed the broken `\r` escape inside `%APPDATA%\rclone\rclone.conf` in `SECURITY.md` and removed trailing whitespace in `Install-Prerequisites.ps1` and `Setup-Autostart.ps1`.

## [1.1.2] - 2026-10-28

### Added
- **Win32 Argument Quoting Helper (`ConvertTo-RcloneArg`):** Added a dedicated sanitization helper that quotes arguments and doubles trailing backslashes (`-replace '(\\+)$', '$1$1'`), eliminating Win32 `CommandLineToArgvW` quote-escaping vulnerabilities that could swallow subsequent arguments.
- **Strict Configuration Input Validation:** Enhanced `Get-DriveConfigErrors` to reject configuration values containing literal double quotes (`"`) or Unicode control characters (`[\p{Cc}]`), and reject trailing slashes or backslashes in `cache_dir`.
- **Token-Aware Remote Parser (`Get-MountTargetFromCmdline`):** Replaced whitespace-splitting regex in `Stop-DriveMount` and `Show-Status` with token-aware parser supporting remote names containing whitespace (e.g., `"kampus it:"`).
- **Defensive Non-Interactive Flag (`--ask-password=false`):** Added `--ask-password=false` to `rclone mount` and `rclone listremotes` invocations to guarantee fail-fast behavior instead of indefinite blocking in headless/background execution contexts.
- **Mount Log File Rotation:** Implemented automated log rotation in `Start-DriveMount` archiving log files exceeding 5 MB to `.1`, preventing unbounded disk consumption.
- **Prerequisites Tracking Marker (`.prerequisites.json`):** `Install-Prerequisites.ps1` records only packages explicitly installed by WinCloudMount into `.prerequisites.json` at the root installation directory (`$ProjectRoot`).
- **Safe Uninstallation Isolation:** `scripts/Uninstall.ps1` and `uninstall.ps1` consult `.prerequisites.json` when `-RemovePrerequisites` is specified, strictly retaining pre-existing tools and emitting warnings if the marker is missing or empty.
- **Automated Unit Test Suite:** Introduced `tests/UnitTests.ps1` covering argument escaping, regex parsing, configuration error validation, log rotation, and the 3-state prerequisites removal matrix (39 assertions total).
- **Linter Rule Suppression Policy:** Added `PSScriptAnalyzerSettings.psd1` codifying deliberate CLI style exceptions and elevated CI validation to `-Severity Warning`.
- **Documentation Callouts (`README.id.md`):** Added callouts for Architecture, VFS Performance Tuning, CLI Reference, and Contributing sections linking to `README.md`.

### Changed
- **Extended WinFsp Handshake Window:** Increased cold-start mount polling timeout from 30s to 45s (with 2s intervals) to prevent false `[FAILED]` reports during slow system boot handshakes.
- **Mount Start Failure Aggregation:** Updated inline `start` command router to track per-drive mount outcomes and terminate with exit code 1 if any drive fails.
- **CI / CD Quality Gates:** Elevated PSScriptAnalyzer linter threshold in `.github/workflows/validate.yml` from `Error` to `Warning` using repository settings.
- **Cleaned Example Drive Config:** Removed manual `"icon"` property from `home-nas` in `config/drives.example.json` to allow dynamic fallback.

### Fixed
- **PowerShell Automatic Variable Collision:** Renamed `$profile` to `$userProfile` across uninstallation scripts to avoid shadowing the built-in PowerShell automatic `$PROFILE` variable.
- **Empty Catch Block Violations:** Refactored silent catch blocks across scripts to `$null = $_`, ensuring strict adherence to PSScriptAnalyzer warning-level rules.

## [1.1.1] - 2026-10-27

### Fixed
- **Process Stop Scoping:** Scoped `Stop-DriveMount` path verification strictly to directory boundaries, preventing partial substring matches from stopping external processes.

## [1.1.0] - 2026-10-27

### Added
- Dynamic Google Drive backend auto-detection via `rclone config show`.
- Subpath remote verification in `Test-Config`.

### Changed
- Hardened installer release pinning and SHA256 integrity verification.

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

[1.2.0]: https://github.com/yahyazakaria29/win-cloud-mount/releases/tag/v1.2.0
[1.1.2]: https://github.com/yahyazakaria29/win-cloud-mount/releases/tag/v1.1.2
[1.1.1]: https://github.com/yahyazakaria29/win-cloud-mount/releases/tag/v1.1.1
[1.1.0]: https://github.com/yahyazakaria29/win-cloud-mount/releases/tag/v1.1.0
[1.0.0]: https://github.com/yahyazakaria29/win-cloud-mount/releases/tag/v1.0.0
