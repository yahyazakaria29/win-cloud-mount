<#
.SYNOPSIS
    Comprehensive uninstaller and cleanup script for WinCloudMount.

.DESCRIPTION
    Safely tears down the WinCloudMount environment:
    1. Stops all running rclone virtual drive processes.
    2. Unregisters the 'WinCloudMount-Autostart' scheduled task.
    3. Cleans up Windows Explorer registry entries (DriveIcons, Classes Explorer Drives, MountPoints2).
    4. Flushes the Windows Shell icon cache via SHChangeNotify.
    5. Optionally removes local VFS cache directories.
    6. Optionally uninstalls Rclone and WinFsp via Winget.

.PARAMETER PurgeCache
    Delete local VFS cache folders (e.g. the .cache/ directory).

.PARAMETER RemovePrerequisites
    Uninstall WinFsp and Rclone from Windows via Winget.

.EXAMPLE
    .\Uninstall.ps1
    .\Uninstall.ps1 -PurgeCache
    .\Uninstall.ps1 -PurgeCache -RemovePrerequisites
#>

[CmdletBinding()]
param (
    [switch]$PurgeCache,
    [switch]$RemovePrerequisites
)

$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ConfigFile = Join-Path $ProjectRoot "config\drives.json"

Write-Host "`n=======================================================" -ForegroundColor Red
Write-Host "         WinCloudMount - Uninstall & Cleanup           " -ForegroundColor Yellow
Write-Host "=======================================================" -ForegroundColor Red

# 1. Stop all active mounts
Write-Host "`n[1/5] Stopping all active virtual drive mounts..." -ForegroundColor Cyan
$mountManager = Join-Path $ScriptDir "Mount-Manager.ps1"
if (Test-Path $mountManager) {
    & $mountManager -Action stop
} else {
    $projectRootEsc = [regex]::Escape($ProjectRoot)
    Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $cmd = $_.CommandLine
        # Precise ownership: project root path only (see Stop-DriveMount rationale).
        $cmd -and ($cmd -match "\bmount\b") -and ($cmd -match $projectRootEsc)
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# 2. Disable and delete Task Scheduler autostart
Write-Host "`n[2/5] Removing Windows Task Scheduler autostart task..." -ForegroundColor Cyan
$setupAutostart = Join-Path $ScriptDir "Setup-Autostart.ps1"
if (Test-Path $setupAutostart) {
    & $setupAutostart -Action disable
} else {
    Unregister-ScheduledTask -TaskName "WinCloudMount-Autostart" -Confirm:$false -ErrorAction SilentlyContinue
}

# 3. Clean up Windows Registry (DriveIcons, Classes, MountPoints2)
Write-Host "`n[3/5] Cleaning up Windows Explorer drive registry customizations..." -ForegroundColor Cyan

# Ownership check: is a DefaultIcon value (or generic registry value) owned by WinCloudMount?
function Test-WinCloudMountIconValue {
    param([string]$Value)
    if (-not $Value) { return $false }
    if ($Value -match [regex]::Escape($ProjectRoot)) { return $true }
    if ($Value -match 'WinCloudMount') { return $true }
    foreach ($icon in @('googledrive.ico','onedrive.ico','dropbox.ico','nextcloud.ico','box.ico','mega.ico','protondrive.ico','s3.ico')) {
        if ($Value -match [regex]::Escape($icon)) { return $true }
    }
    return $false
}

# Gather configured drive letters (always treated as owned)
$driveLetters = @()
if (Test-Path $ConfigFile) {
    try {
        $configs = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
        foreach ($c in $configs) {
            if ($c.drive_letter) {
                $driveLetters += $c.drive_letter.ToUpper().TrimEnd(':')
            }
        }
    } catch {}
}

# Verify ownership of any E-Z letter carrying a drive-icon key BEFORE adding it to the
# delete list. A letter is only removed when its DefaultIcon points at this project's
# install directory, mentions WinCloudMount, or references one of the bundled icons.
foreach ($l in [char[]](69..90)) { # E through Z
    $letter = [string]$l
    if ($driveLetters -contains $letter) { continue }

    $owned = $false
    foreach ($key in @(
        "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$letter\DefaultIcon",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letter\DefaultIcon"
    )) {
        if (Test-Path $key) {
            $val = (Get-ItemProperty -Path $key -Name '(Default)' -ErrorAction SilentlyContinue).'(Default)'
            if (Test-WinCloudMountIconValue -Value $val) { $owned = $true }
        }
    }
    if ($owned) { $driveLetters += $letter }
}

foreach ($let in $driveLetters) {
    # Remove HKCU Classes Applications Explorer
    $k1 = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$let"
    if (Test-Path $k1) {
        Remove-Item -Path $k1 -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed: $k1" -ForegroundColor Gray
    }

    # Remove HKCU DriveIcons
    $k2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$let"
    if (Test-Path $k2) {
        Remove-Item -Path $k2 -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed: $k2" -ForegroundColor Gray
    }
}

# Clean stale MountPoints2 entries ONLY for verified WinCloudMount drives. Unverifiable
# entries are left untouched (better a small orphan than deleting a third-party share).
try {
    Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $child = $_.PSChildName
            $shouldRemove = $false
            foreach ($let in $driveLetters) {
                if ($child -eq $let) { $shouldRemove = $true; break }
            }
            if (-not $shouldRemove -and $child -like "*rclone*") {
                $val = (Get-ItemProperty -Path $_.PSPath -Name '(Default)' -ErrorAction SilentlyContinue).'(Default)'
                if (Test-WinCloudMountIconValue -Value $val) { $shouldRemove = $true }
            }
            if ($shouldRemove) {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
} catch {}

# Broadcast Shell refresh
try {
    $code = @"
using System;
using System.Runtime.InteropServices;
public class UnloadShellNotifier {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
"@
    if (-not ([System.Management.Automation.PSTypeName]'UnloadShellNotifier').Type) {
        Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
    }
    [UnloadShellNotifier]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
} catch {}
Write-Host "  [OK] Registry entries cleaned and Windows Shell notified." -ForegroundColor Green

# 4. Optional VFS Cache Purge
Write-Host "`n[4/5] Checking local VFS cache directories..." -ForegroundColor Cyan

function Test-UnsafePurgePath {
    # Returns $true when a path must NEVER be purged (system-critical or user-profile roots).
    param([string]$Path)
    if (-not $Path) { return $true }

    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $true }
    if (-not $full) { return $true }

    # Root drive (e.g. 'C:\')
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root -and $full -eq $root.TrimEnd('\')) { return $true }

    # Windows system directories
    $sysDirs = @(
        [Environment]::GetFolderPath('Windows'),
        [Environment]::GetFolderPath('System'),
        [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86')
    )
    foreach ($d in $sysDirs) {
        if ($d -and $full -eq $d.TrimEnd('\')) { return $true }
    }

    # User profile root and standard user folders
    $profile = [Environment]::GetFolderPath('UserProfile')
    if ($profile -and $full -eq $profile.TrimEnd('\')) { return $true }
    $special = @(
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('DesktopDirectory'),
        [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyMusic'),
        [Environment]::GetFolderPath('MyVideos')
    )
    if ($profile) {
        $special += (Join-Path $profile 'Downloads')
        $special += (Join-Path $profile 'OneDrive')
        $special += (Join-Path $profile 'Documents')
        $special += (Join-Path $profile 'Desktop')
    }
    foreach ($d in $special) {
        if ($d -and $full -eq $d.TrimEnd('\')) { return $true }
    }

    return $false
}

if ($PurgeCache) {
    Write-Host "  Purging cache as requested via -PurgeCache..." -ForegroundColor Yellow

    # Collect cache paths: relative paths resolve against project root; absolute paths as-is.
    $cachePaths = @()
    if (Test-Path $ConfigFile) {
        try {
            $configs = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
            foreach ($c in $configs) {
                $cDir = $c.cache_dir
                if ($cDir) {
                    if (-not [System.IO.Path]::IsPathRooted($cDir)) {
                        $cDir = Join-Path $ProjectRoot $cDir
                    }
                    $cachePaths += $cDir
                }
            }
        } catch {}
    }
    $projectDotCache = Join-Path $ProjectRoot ".cache"
    if (-not ($cachePaths -contains $projectDotCache)) {
        $cachePaths += $projectDotCache
    }

    foreach ($path in $cachePaths) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }

        $full = [System.IO.Path]::GetFullPath($path)

        # Guardrail 1: never purge system-critical / user-profile roots.
        if (Test-UnsafePurgePath -Path $full) {
            Write-Warning "  SKIPPING unsafe purge path: $full (system/user-critical folder)"
            continue
        }

        # Guardrail 2: absolute paths outside the project root require explicit consent.
        $projectRootPrefix = $ProjectRoot.TrimEnd('\') + '\'
        $outside = -not $full.StartsWith($projectRootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                   -not ($full -eq $ProjectRoot.TrimEnd('\'))
        if ($outside -and $env:WCM_ALLOW_EXTERNAL_CACHE_PURGE -ne '1') {
            Write-Warning "  SKIPPING external cache path (outside project root; set WCM_ALLOW_EXTERNAL_CACHE_PURGE=1 to allow): $full"
            continue
        }

        # Per-path confirmation in interactive mode.
        $doPurge = $true
        if ($env:WCM_NONINTERACTIVE -ne '1') {
            $ans = Read-Host "  Purge cache path: $full ? [y/N]"
            if ($ans -notmatch '^(y|yes)$') { $doPurge = $false }
        }
        if ($doPurge) {
            Write-Host "  Deleting cache folder: $full" -ForegroundColor Gray
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  [OK] Cache purge finished." -ForegroundColor Green
} else {
    Write-Host "  Skipping cache purge (use -PurgeCache switch if you wish to wipe local cache)." -ForegroundColor Gray
}

# 5. Optional Prerequisites Removal
Write-Host "`n[5/5] Checking prerequisites (WinFsp & Rclone)..." -ForegroundColor Cyan
if ($RemovePrerequisites) {
    Write-Host "  Uninstalling Rclone and WinFsp via Winget..." -ForegroundColor Yellow
    winget uninstall --id rclone.rclone --silent --accept-source-agreements
    winget uninstall --id WinFsp.WinFsp --silent --accept-source-agreements
    Write-Host "  [OK] Prerequisites uninstalled." -ForegroundColor Green
} else {
    Write-Host "  Retaining WinFsp and Rclone binaries (use -RemovePrerequisites switch to uninstall)." -ForegroundColor Gray
}

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host " [SUCCESS] WinCloudMount uninstallation complete!     " -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Green
Write-Host "To completely remove the repository folder, you can delete:" -ForegroundColor White
Write-Host "  $ProjectRoot`n" -ForegroundColor Gray
