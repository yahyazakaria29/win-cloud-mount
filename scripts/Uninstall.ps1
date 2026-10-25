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
    Delete local VFS cache folders (located on drive D:).

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
    Get-Process -Name "rclone" -ErrorAction SilentlyContinue | Where-Object {
        (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine -match "mount"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
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

# Gather configured drive letters
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

# Also check any letters from E to Z that have WinCloudMount custom keys
foreach ($l in [char[]](69..90)) { # E through Z
    $classesKey = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$l"
    if (Test-Path $classesKey) {
        if (-not ($driveLetters -contains [string]$l)) { $driveLetters += [string]$l }
    }
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

# Clean stale network mount points
try {
    Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2" -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "*server*" -or $_.PSChildName -like "*rclone*" } |
        ForEach-Object {
            Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
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
if ($PurgeCache) {
    Write-Host "  Purging cache as requested via -PurgeCache..." -ForegroundColor Yellow
    if (Test-Path $ConfigFile) {
        try {
            $configs = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
            foreach ($c in $configs) {
                if ($c.cache_dir -and (Test-Path $c.cache_dir)) {
                    Write-Host "  Deleting cache folder: $($c.cache_dir)" -ForegroundColor Gray
                    Remove-Item -Path $c.cache_dir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    }
    Write-Host "  [OK] Cache directories purged." -ForegroundColor Green
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
