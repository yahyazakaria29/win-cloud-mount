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

    # Transparency: report effective teardown flags (including environment overrides).
    Write-Note "Purge cache      : $(if ($PurgeCache) { 'YES' } else { 'no' })"
    Write-Note "Remove prereqs   : $(if ($RemovePrereqs) { 'YES' } else { 'no' })"
    Write-Note "Delete directory : $(if ($DeleteDir) { 'YES' } else { 'no' })"

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
        # Folder delete prompt (only if install folder exists). Default is NO (safe).
        if (-not $DeleteDir -and (Test-Path $InstallDir)) {
            $ansDir = Read-Host "Delete WinCloudMount directory ($InstallDir)? [y/N]"
            if ($ansDir -match '^(y|yes)$') { $DeleteDir = $true }
        }
    }

    # 3. Stop running rclone mount processes
    Write-Step 'Stopping active virtual drive mounts...'
    $localMountMgr = Join-Path $InstallDir 'scripts\Mount-Manager.ps1'
    if (Test-Path $localMountMgr) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $localMountMgr -Action stop
    } else {
        $installDirEsc = [regex]::Escape($InstallDir)
        Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $cmd = $_.CommandLine
            # Precise ownership: install dir path only (see Stop-DriveMount rationale).
            $cmd -and ($cmd -match "\bmount\b") -and ($cmd -match $installDirEsc)
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Ok 'WinCloudMount rclone processes stopped.'
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

    # Ownership check: is a DefaultIcon value (or generic registry value) owned by WinCloudMount?
    function Test-WinCloudMountIconValue {
        param([string]$Value)
        if (-not $Value) { return $false }
        if ($Value -match [regex]::Escape($InstallDir)) { return $true }
        if ($Value -match 'WinCloudMount') { return $true }
        foreach ($icon in @('googledrive.ico','onedrive.ico','dropbox.ico','nextcloud.ico','box.ico','mega.ico','protondrive.ico','s3.ico')) {
            if ($Value -match [regex]::Escape($icon)) { return $true }
        }
        return $false
    }

    $letters = @()
    $configFile = Join-Path $InstallDir 'config\drives.json'
    if (Test-Path $configFile) {
        try {
            $configs = Get-Content -Raw -Path $configFile | ConvertFrom-Json
            foreach ($c in $configs) {
                if ($c.drive_letter) { $letters += $c.drive_letter.ToUpper().TrimEnd(':') }
            }
        } catch { $null = $_ }
    }
    # Verify ownership of E-Z letters before deleting: only remove a letter whose
    # DefaultIcon points into the install directory, mentions WinCloudMount, or
    # references a bundled project icon. Never remove third-party drive branding.
    foreach ($l in [char[]](69..90)) {
        $letter = [string]$l
        if ($letters -contains $letter) { continue }

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
        if ($owned) { $letters += $letter }
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

    # Clean stale MountPoints2 entries ONLY for verified WinCloudMount drives. Unverifiable
    # entries are left untouched (better a small orphan than deleting a third-party share).
    try {
        Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $child = $_.PSChildName
                $shouldRemove = $false
                foreach ($let in $letters) {
                    if ($child -eq $let) { $shouldRemove = $true; break }
                }
                if (-not $shouldRemove -and $child -like '*rclone*') {
                    $val = (Get-ItemProperty -Path $_.PSPath -Name '(Default)' -ErrorAction SilentlyContinue).'(Default)'
                    if (Test-WinCloudMountIconValue -Value $val) { $shouldRemove = $true }
                }
                if ($shouldRemove) {
                    Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
    } catch { $null = $_ }

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
    } catch { $null = $_ }
    Write-Ok 'Explorer drive branding removed and Shell notified.'

    # 6. Purge cache if requested
    if ($PurgeCache) {
        Write-Step 'Purging VFS cache files...'

        function Test-UnsafePurgePath {
            # Returns $true when a path must NEVER be purged (system-critical or user-profile roots).
            param([string]$Path)
            if (-not $Path) { return $true }

            $full = $null
            try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $true }
            if (-not $full) { return $true }

            $root = [System.IO.Path]::GetPathRoot($full)
            if ($root -and $full -eq $root.TrimEnd('\')) { return $true }

            foreach ($d in @(
                [Environment]::GetFolderPath('Windows'),
                [Environment]::GetFolderPath('System'),
                [Environment]::GetFolderPath('ProgramFiles'),
                [Environment]::GetFolderPath('ProgramFilesX86')
            )) {
                if ($d -and $full -eq $d.TrimEnd('\')) { return $true }
            }

            $userProfile = [Environment]::GetFolderPath('UserProfile')
            if ($userProfile -and $full -eq $userProfile.TrimEnd('\')) { return $true }
            $special = @(
                [Environment]::GetFolderPath('MyDocuments'),
                [Environment]::GetFolderPath('DesktopDirectory'),
                [Environment]::GetFolderPath('MyPictures'),
                [Environment]::GetFolderPath('MyMusic'),
                [Environment]::GetFolderPath('MyVideos')
            )
            if ($userProfile) {
                $special += (Join-Path $userProfile 'Downloads')
                $special += (Join-Path $userProfile 'OneDrive')
                $special += (Join-Path $userProfile 'Documents')
                $special += (Join-Path $userProfile 'Desktop')
            }
            foreach ($d in $special) {
                if ($d -and $full -eq $d.TrimEnd('\')) { return $true }
            }
            return $false
        }

        # Collect cache paths: relative paths resolve against install dir; absolute as-is.
        $cachePaths = @()
        if (Test-Path $configFile) {
            try {
                $configs = Get-Content -Raw -Path $configFile | ConvertFrom-Json
                foreach ($c in $configs) {
                    $cDir = $c.cache_dir
                    if ($cDir) {
                        if (-not [IO.Path]::IsPathRooted($cDir)) {
                            $cDir = Join-Path $InstallDir $cDir
                        }
                        $cachePaths += $cDir
                    }
                }
            } catch { $null = $_ }
        }
        $dotCache = Join-Path $InstallDir '.cache'
        if (-not ($cachePaths -contains $dotCache)) { $cachePaths += $dotCache }

        foreach ($path in $cachePaths) {
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }

            $full = [System.IO.Path]::GetFullPath($path)

            if (Test-UnsafePurgePath -Path $full) {
                Write-Note "SKIPPING unsafe purge path: $full (system/user-critical folder)"
                continue
            }

            $installPrefix = $InstallDir.TrimEnd('\') + '\'
            $outside = -not $full.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                       -not ($full -eq $InstallDir.TrimEnd('\'))
            if ($outside -and $env:WCM_ALLOW_EXTERNAL_CACHE_PURGE -ne '1') {
                Write-Note "SKIPPING external cache path (outside install dir; set WCM_ALLOW_EXTERNAL_CACHE_PURGE=1 to allow): $full"
                continue
            }

            $doPurge = $true
            if ($env:WCM_NONINTERACTIVE -ne '1') {
                $ans = Read-Host "Purge cache path: $full ? [y/N]"
                if ($ans -notmatch '^(y|yes)$') { $doPurge = $false }
            }
            if ($doPurge) {
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
                Write-Note "Purged: $full"
            }
        }
        Write-Ok 'Local VFS cache purge finished.'
    }

    function Get-PrerequisiteRemovalPlan {
        param ([string]$MarkerPath)

        $plan = [PSCustomObject]@{
            HasMarker       = $false
            UninstallWinFsp = $false
            UninstallRclone = $false
            InstalledByWcm  = @()
            WarningMessage  = $null
        }

        if (-not $MarkerPath -or -not (Test-Path -LiteralPath $MarkerPath)) {
            $plan.WarningMessage = "Prerequisites marker (.prerequisites.json) not found at $MarkerPath. Assuming all tools were pre-existing. Retaining WinFsp and Rclone."
            return $plan
        }

        $plan.HasMarker = $true
        try {
            $raw = Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction Stop
            $data = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($data -and $data.installed_by_wcm) {
                $installed = @($data.installed_by_wcm | ForEach-Object { "$_".ToLower().Trim() })
                $plan.InstalledByWcm = $installed
                if ($installed -contains 'winfsp') { $plan.UninstallWinFsp = $true }
                if ($installed -contains 'rclone') { $plan.UninstallRclone = $true }
            }
        } catch {
            $plan.WarningMessage = 'Could not parse prerequisites marker (.prerequisites.json). Retaining WinFsp and Rclone as a safeguard.'
            return $plan
        }

        if (-not $plan.UninstallWinFsp -and -not $plan.UninstallRclone) {
            $plan.WarningMessage = "No prerequisites were recorded as installed by WinCloudMount in $MarkerPath. Retaining WinFsp and Rclone."
        }

        return $plan
    }

    # 7. Remove Prerequisites if requested
    if ($RemovePrereqs) {
        $markerFile = Join-Path $InstallDir '.prerequisites.json'
        $plan = Get-PrerequisiteRemovalPlan -MarkerPath $markerFile

        if ($plan.WarningMessage) {
            Write-Warning $plan.WarningMessage
        }

        if ($plan.UninstallRclone) {
            Write-Step 'Uninstalling Rclone (installed by WinCloudMount) via Winget...'
            winget uninstall --id rclone.rclone --silent --accept-source-agreements
            Write-Ok 'Rclone uninstalled.'
        } else {
            Write-Note 'Retaining Rclone (pre-existing or not installed by WinCloudMount).'
        }

        if ($plan.UninstallWinFsp) {
            Write-Step 'Uninstalling WinFsp (installed by WinCloudMount) via Winget...'
            winget uninstall --id WinFsp.WinFsp --silent --accept-source-agreements
            Write-Ok 'WinFsp uninstalled.'
        } else {
            Write-Note 'Retaining WinFsp (pre-existing or not installed by WinCloudMount).'
        }

        if (Test-Path -LiteralPath $markerFile) {
            Remove-Item -LiteralPath $markerFile -Force -ErrorAction SilentlyContinue
        }
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
