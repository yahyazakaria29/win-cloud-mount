<#
.SYNOPSIS
    WinCloudMount one-line bootstrap installer.

.DESCRIPTION
    Downloads WinCloudMount from GitHub, installs the prerequisites (WinFsp + Rclone)
    and prepares a starter config/drives.json. Safe to re-run: it updates the scripts
    in place and never overwrites your config/drives.json, cache, or logs.

    One-line usage (PowerShell):
        irm https://raw.githubusercontent.com/yahyazakaria29/win-cloud-mount/main/install.ps1 | iex

    Optional environment variables (set them before running the one-liner):
        WCM_INSTALL_DIR      Install location. Default: %LOCALAPPDATA%\WinCloudMount
        WCM_BRANCH           Git branch to download. Default: main
        WCM_SKIP_PREREQS     Set to 1 to skip the WinFsp/Rclone installation step.
        WCM_NONINTERACTIVE   Set to 1 to skip the "run rclone config now?" prompt.
        WCM_SOURCE_ZIP       Use a local .zip instead of downloading (for testing/offline).

.NOTES
    This script is designed to run through Invoke-Expression, so it never calls 'exit'
    (that would close the user's PowerShell window). Errors are reported and it returns.
#>

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is much faster without the progress bar

    $Repo       = 'yahyazakaria29/win-cloud-mount'
    $Branch     = if ($env:WCM_BRANCH) { $env:WCM_BRANCH } else { 'main' }
    $InstallDir = if ($env:WCM_INSTALL_DIR) { $env:WCM_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'WinCloudMount' }

    function Write-Step ([string]$m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
    function Write-Ok   ([string]$m) { Write-Host "[OK] $m"     -ForegroundColor Green }
    function Write-Note ([string]$m) { Write-Host "[INFO] $m"   -ForegroundColor Yellow }
    function Write-Fail ([string]$m) { Write-Host "[ERROR] $m"  -ForegroundColor Red }

    Write-Host '==========================================================' -ForegroundColor Cyan
    Write-Host '        WinCloudMount - One-Line Installer                ' -ForegroundColor White
    Write-Host '==========================================================' -ForegroundColor Cyan

    # ---------------------------------------------------------------- 1. Environment
    Write-Step 'Checking system...'
    if ($env:OS -ne 'Windows_NT') {
        Write-Fail 'WinCloudMount only runs on Windows 10/11.'
        return
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Fail 'A 64-bit Windows is required.'
        return
    }
    try {
        # Older Windows PowerShell 5.1 builds default to TLS 1.0, which GitHub rejects
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    Write-Ok "Windows $([Environment]::OSVersion.Version) (64-bit), PowerShell $($PSVersionTable.PSVersion)"
    Write-Note "Install location: $InstallDir"

    # ---------------------------------------------------------------- 2. Download
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ("wcm-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    try {
        $zipPath = Join-Path $workDir 'wcm.zip'
        if ($env:WCM_SOURCE_ZIP) {
            Write-Step "Using local package: $env:WCM_SOURCE_ZIP"
            Copy-Item -LiteralPath $env:WCM_SOURCE_ZIP -Destination $zipPath -Force
        } else {
            $url = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
            Write-Step "Downloading WinCloudMount ($Branch)..."
            try {
                Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
            } catch {
                Write-Fail "Download failed: $url"
                Write-Fail $_.Exception.Message
                Write-Note 'Check your internet connection, or use the manual install (git clone) from the README.'
                return
            }
        }
        Write-Ok ("Package ready ({0:N0} KB)" -f ((Get-Item $zipPath).Length / 1KB))

        # ------------------------------------------------------------ 3. Extract & install
        Write-Step 'Installing files...'
        $extractDir = Join-Path $workDir 'src'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        # GitHub archives contain a single top-level folder (win-cloud-mount-<branch>)
        $srcRoot = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $srcRoot -or -not (Test-Path (Join-Path $srcRoot.FullName 'scripts\Mount-Manager.ps1'))) {
            Write-Fail 'Downloaded package has an unexpected layout (scripts\Mount-Manager.ps1 not found).'
            return
        }

        $isUpdate = Test-Path (Join-Path $InstallDir 'scripts\Mount-Manager.ps1')
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        # Copies project files only. config\drives.json, .cache\ and logs\ are not part of the
        # package, so an existing setup is preserved during updates.
        Copy-Item -Path (Join-Path $srcRoot.FullName '*') -Destination $InstallDir -Recurse -Force

        # Remove the "downloaded from the internet" flag so the scripts run under RemoteSigned policy
        Get-ChildItem -LiteralPath $InstallDir -Recurse -File -Include *.ps1, *.vbs |
            Unblock-File -ErrorAction SilentlyContinue

        if ($isUpdate) { Write-Ok "Updated existing installation in $InstallDir" }
        else           { Write-Ok "Installed to $InstallDir" }
    }
    finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---------------------------------------------------------------- 4. Prerequisites
    if ($env:WCM_SKIP_PREREQS -eq '1') {
        Write-Note 'Skipping WinFsp/Rclone installation (WCM_SKIP_PREREQS=1).'
    } else {
        Write-Step 'Installing prerequisites (WinFsp + Rclone)...'
        Write-Note 'Windows may show ONE permission prompt (UAC) for the WinFsp driver - click Yes.'
        # Run in a child process: the prerequisites script uses 'exit', which must not close this window
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'scripts\Install-Prerequisites.ps1')
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Prerequisite installation reported an error (exit code $LASTEXITCODE)."
            Write-Note "Fix the issue above, then re-run: $InstallDir\scripts\Install-Prerequisites.ps1"
            return
        }
        # Make a freshly installed rclone visible in this session
        $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    # ---------------------------------------------------------------- 5. Starter config
    Write-Step 'Preparing drive configuration...'
    $cfg     = Join-Path $InstallDir 'config\drives.json'
    $example = Join-Path $InstallDir 'config\drives.example.json'
    if (Test-Path $cfg) {
        Write-Ok 'Existing config\drives.json kept (not overwritten).'
    } else {
        Copy-Item -LiteralPath $example -Destination $cfg
        Write-Ok 'Created config\drives.json from the example template.'
    }

    # ---------------------------------------------------------------- 6. Connect accounts
    $rclone = Get-Command rclone -ErrorAction SilentlyContinue
    if ($env:WCM_NONINTERACTIVE -ne '1' -and $rclone) {
        $answer = Read-Host "`nConnect a cloud account now with 'rclone config'? [Y/n]"
        if ($answer -notmatch '^(n|no)$') {
            & $rclone.Source config
        }
    }

    # ---------------------------------------------------------------- 7. Next steps
    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host ' [SUCCESS] WinCloudMount is installed!' -ForegroundColor Green
    Write-Host '==========================================================' -ForegroundColor Green
    Write-Host @"

 Next steps (copy-paste into PowerShell):

   cd "$InstallDir"
   rclone config                         # 1. connect your cloud accounts (if not done yet)
   notepad config\drives.json            # 2. set remotes + drive letters
   powershell -ExecutionPolicy Bypass -File .\scripts\Mount-Manager.ps1 -Action start      # 3. mount all drives
   powershell -ExecutionPolicy Bypass -File .\scripts\Setup-Autostart.ps1 -Action enable   # 4. (optional) autostart

 Docs: https://github.com/$Repo
"@
}
