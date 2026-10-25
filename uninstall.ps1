<#
.SYNOPSIS
    WinCloudMount one-line uninstaller & teardown bootstrap.

.DESCRIPTION
    Safely stops all cloud drive mounts, removes autostart tasks, cleans up Windows
    Explorer registry customizations (drive icons & labels), purges cache, and
    optionally removes the installation directory and prerequisites.

    One-line usage (PowerShell):
        irm https://raw.githubusercontent.com/yahyazakaria29/win-cloud-mount/main/uninstall.ps1 | iex

    Optional environment variables (for non-interactive / scripted teardown):
        WCM_INSTALL_DIR       Install location to clean. Default: %LOCALAPPDATA%\WinCloudMount
        WCM_PURGE_CACHE       Set to 1 to purge local VFS cache files.
        WCM_REMOVE_PREREQS    Set to 1 to uninstall WinFsp and Rclone via Winget.
        WCM_DELETE_DIR        Set to 1 to delete the installation folder completely.
        WCM_NONINTERACTIVE    Set to 1 to skip interactive confirmation prompts.

.NOTES
    Designed to run via Invoke-Expression (iex): never invokes 'exit' directly so
    it will not close the user's PowerShell console window.
#>

& {
    $ErrorActionPreference = 'Continue'
    $ProgressPreference    = 'SilentlyContinue'

    function Write-Step ([string]$m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
    function Write-Ok   ([string]$m) { Write-Host "[OK] $m"     -ForegroundColor Green }
    function Write-Note ([string]$m) { Write-Host "[INFO] $m"   -ForegroundColor Yellow }
    function Write-Fail ([string]$m) { Write-Host "[ERROR] $m"  -ForegroundColor Red }

    Write-Host '==========================================================' -ForegroundColor Red
    Write-Host '        WinCloudMount - One-Line Uninstaller              ' -ForegroundColor Yellow
    Write-Host '==========================================================' -ForegroundColor Red

    # 1. Locate installation directory
    $DefaultInstallDir = Join-Path $env:LOCALAPPDATA 'WinCloudMount'
    $InstallDir = if ($env:WCM_INSTALL_DIR) {
        $env:WCM_INSTALL_DIR
    } elseif (Test-Path (Join-Path (Get-Location) 'scripts\Uninstall.ps1')) {
        (Get-Location).Path
    } elseif (Test-Path (Join-Path $DefaultInstallDir 'scripts\Uninstall.ps1')) {
        $DefaultInstallDir
    } else {
        $DefaultInstallDir
    }

    Write-Note "Target installation: $InstallDir"

    # 2. Interactive questions if not non-interactive
    $PurgeCache = $env:WCM_PURGE_CACHE -eq '1'
    $RemovePrereqs = $env:WCM_REMOVE_PREREQS -eq '1'
    $DeleteDir = $env:WCM_DELETE_DIR -eq '1'

    if ($env:WCM_NONINTERACTIVE -ne '1') {
        # Cache purge prompt
        if (-not $PurgeCache) {
            $ansCache = Read-Host "`nPurge local offline VFS cache files? [y/N]"
            if ($ansCache -match '^(y|yes)$') { $PurgeCache = $true }
        }
        # Prerequisites removal prompt
        if (-not $RemovePrereqs) {
            $ansPrereq = Read-Host "Uninstall WinFsp and Rclone via Winget? [y/N]"
            if ($ansPrereq -match '^(y|yes)$') { $RemovePrereqs = $true }
        }
        # Folder delete prompt (only if install folder exists)
        if (-not $DeleteDir -and (Test-Path $InstallDir)) {
            $ansDir = Read-Host "Delete WinCloudMount directory ($InstallDir)? [Y/n]"
            if ($ansDir -notmatch '^(n|no)$') { $DeleteDir = $true }
        }
    }

    # 3. Stop running rclone mount processes
    Write-Step 'Stopping active virtual drive mounts...'
    $localMountMgr = Join-Path $InstallDir 'scripts\Mount-Manager.ps1'
    if (Test-Path $localMountMgr) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $localMountMgr -Action stop
    } else {
        Get-Process -Name 'rclone' -ErrorAction SilentlyContinue | Where-Object {
            try {
                (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine -match 'mount'
            } catch { $false }
        } | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok 'All rclone mount processes stopped.'
    }

    # 4. Remove Task Scheduler autostart
    Write-Step 'Removing autostart scheduled task...'
    $localAutostart = Join-Path $InstallDir 'scripts\Setup-Autostart.ps1'
    if (Test-Path $localAutostart) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $localAutostart -Action disable
    } else {
        Unregister-ScheduledTask -TaskName 'WinCloudMount-Autostart' -Confirm:$false -ErrorAction SilentlyContinue
        Write-Ok "Autostart task 'WinCloudMount-Autostart' unregistered."
    }

    # 5. Clean registry customizations (Drive icons and labels)
    Write-Step 'Cleaning Windows Explorer registry entries...'
    $letters = @()
    $configFile = Join-Path $InstallDir 'config\drives.json'
    if (Test-Path $configFile) {
        try {
            $configs = Get-Content -Raw -Path $configFile | ConvertFrom-Json
            foreach ($c in $configs) {
                if ($c.drive_letter) { $letters += $c.drive_letter.ToUpper().TrimEnd(':') }
            }
        } catch { }
    }
    # Check all possible letters E to Z
    foreach ($l in [char[]](69..90)) {
        $k = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$l"
        if (Test-Path $k) {
            if (-not ($letters -contains [string]$l)) { $letters += [string]$l }
        }
    }

    foreach ($let in $letters) {
        $k1 = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$let"
        if (Test-Path $k1) {
            Remove-Item -Path $k1 -Recurse -Force -ErrorAction SilentlyContinue
            Write-Note "Removed registry key: $k1"
        }
        $k2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$let"
        if (Test-Path $k2) {
            Remove-Item -Path $k2 -Recurse -Force -ErrorAction SilentlyContinue
            Write-Note "Removed registry key: $k2"
        }
    }

    # Clean stale network mount points
    try {
        Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like '*server*' -or $_.PSChildName -like '*rclone*' } |
            ForEach-Object { Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }

    # Refresh Windows Shell icon cache
    try {
        $code = @"
using System;
using System.Runtime.InteropServices;
public class ShellRefreshUninstaller {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
"@
        if (-not ([System.Management.Automation.PSTypeName]'ShellRefreshUninstaller').Type) {
            Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
        }
        [ShellRefreshUninstaller]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { }
    Write-Ok 'Explorer drive branding removed and Shell notified.'

    # 6. Purge cache if requested
    if ($PurgeCache) {
        Write-Step 'Purging VFS cache files...'
        if (Test-Path $configFile) {
            try {
                $configs = Get-Content -Raw -Path $configFile | ConvertFrom-Json
                foreach ($c in $configs) {
                    $cDir = $c.cache_dir
                    if ($cDir -and -not [IO.Path]::IsPathRooted($cDir)) {
                        $cDir = Join-Path $InstallDir $cDir
                    }
                    if ($cDir -and (Test-Path $cDir)) {
                        Remove-Item -Path $cDir -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Note "Purged: $cDir"
                    }
                }
            } catch { }
        }
        $dotCache = Join-Path $InstallDir '.cache'
        if (Test-Path $dotCache) {
            Remove-Item -Path $dotCache -Recurse -Force -ErrorAction SilentlyContinue
            Write-Note "Purged: $dotCache"
        }
        Write-Ok 'Local VFS cache purged.'
    }

    # 7. Remove Prerequisites if requested
    if ($RemovePrereqs) {
        Write-Step 'Uninstalling WinFsp and Rclone via Winget...'
        winget uninstall --id rclone.rclone --silent --accept-source-agreements
        winget uninstall --id WinFsp.WinFsp --silent --accept-source-agreements
        Write-Ok 'Prerequisites uninstalled.'
    }

    # 8. Delete installation directory if requested
    if ($DeleteDir -and (Test-Path $InstallDir)) {
        Write-Step "Deleting installation directory ($InstallDir)..."
        # Move away from install dir if current location is inside it
        if ((Get-Location).Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) {
            Set-Location $env:USERPROFILE
        }
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $InstallDir)) {
            Write-Ok "Installation folder deleted successfully."
        } else {
            Write-Note "Some files in $InstallDir were in use. You can delete it manually."
        }
    }

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host ' [SUCCESS] WinCloudMount uninstallation complete!         ' -ForegroundColor Green
    Write-Host '==========================================================' -ForegroundColor Green
}
