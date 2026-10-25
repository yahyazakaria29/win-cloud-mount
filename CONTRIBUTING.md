# Contributing to WinCloudMount

Thank you for considering contributing to WinCloudMount! We welcome pull requests, bug reports, documentation enhancements, and performance optimizations.

---

## Branching & Contribution Workflow

To maintain repository hygiene and avoid breaking changes:

1. **Do not commit directly to `main`**:
   The `main` branch represents stable, release-ready code. All development occurs on feature branches or `develop`.

2. **Branch Naming Conventions**:
   * `feature/<feature-name>` (e.g. `feature/gui-tray-integration`)
   * `fix/<bug-description>` (e.g. `fix/drive-letter-conflict-check`)
   * `docs/<topic>` (e.g. `docs/nextcloud-webdav-tuning`)

3. **Step-by-Step Flow**:
   * Fork or clone the repository.
   * Create a branch from `main`:
     ```bash
     git checkout -b feature/my-enhancement
     ```
   * Implement changes and test thoroughly on Windows 10/11.
   * Ensure no personal credentials or paths are committed (verify against `.gitignore`).
   * Commit with clear, conventional messages (`feat: ...`, `fix: ...`, `docs: ...`).
   * Push your branch and open a Pull Request targeting `main`.

---

## Code Quality Standards

* **PowerShell Scripts**:
  * Follow cmdlet parameter standards (`[CmdletBinding()]`).
  * Ensure path handling supports both trailing slashes and spaces.
  * Avoid unconstrained loops; implement proper timeouts on process detection.
* **VFS Cache Safety**:
  * Never remove `--vfs-cache-mode full` without explicit documentation of trade-offs.
  * Always ensure cache directories default to a configurable, non-system partition.
