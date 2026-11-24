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

    $PurgeCache    = $env:WCM_PURGE_CACHE -eq '1'
    $RemovePrereqs = $env:WCM_REMOVE_PREREQS -eq '1'
    $DeleteDir     = $env:WCM_DELETE_DIR -eq '1'

    Write-Note "Purge cache      : $(if ($PurgeCache) { 'YES' } else { 'no' })"
    Write-Note "Remove prereqs   : $(if ($RemovePrereqs) { 'YES' } else { 'no' })"
    Write-Note "Delete directory : $(if ($DeleteDir) { 'YES' } else { 'no' })"

    if ($env:WCM_NONINTERACTIVE -ne '1') {
        if (-not $PurgeCache) {
            $ansCache = Read-Host "`nPurge local offline VFS cache files? [y/N]"
            if ($ansCache -match '^(y|yes)$') { $PurgeCache = $true }
        }
        if (-not $RemovePrereqs) {
            $ansPrereq = Read-Host "Uninstall WinFsp and Rclone via Winget? [y/N]"
            if ($ansPrereq -match '^(y|yes)$') { $RemovePrereqs = $true }
        }
        if (-not $DeleteDir -and (Test-Path $InstallDir)) {
            $ansDir = Read-Host "Delete WinCloudMount directory ($InstallDir)? [y/N]"
            if ($ansDir -match '^(y|yes)$') { $DeleteDir = $true }
        }
    }

    $localUninstallScript = Join-Path $InstallDir 'scripts\Uninstall.ps1'
    if (Test-Path -LiteralPath $localUninstallScript) {
        # Delegate teardown to the installed script; suppress its duplicate cache prompts because
        # the user already confirmed options above.
        Write-Step 'Running WinCloudMount uninstaller...'
        $prevNonInteractive = $env:WCM_NONINTERACTIVE
        $env:WCM_NONINTERACTIVE = '1'
        try {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $localUninstallScript -PurgeCache:$PurgeCache -RemovePrerequisites:$RemovePrereqs
        } finally {
            if ($null -eq $prevNonInteractive) {
                Remove-Item Env:\WCM_NONINTERACTIVE -ErrorAction SilentlyContinue
            } else {
                $env:WCM_NONINTERACTIVE = $prevNonInteractive
            }
        }
    } else {
        # Fallback teardown when scripts\Uninstall.ps1 is already missing.
        Write-Step 'Stopping active virtual drive mounts...'
        $installDirEsc = [regex]::Escape($InstallDir)
        Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $cmd = $_.CommandLine
            $cmd -and ($cmd -match "\bmount\b") -and ($cmd -match $installDirEsc)
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Ok 'WinCloudMount rclone processes stopped.'

        Write-Step 'Removing autostart scheduled task...'
        Unregister-ScheduledTask -TaskName 'WinCloudMount-Autostart' -Confirm:$false -ErrorAction SilentlyContinue
        Write-Ok "Autostart task 'WinCloudMount-Autostart' unregistered."

        Write-Step 'Cleaning Windows Explorer registry entries...'
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

        foreach ($let in $letters) {
            foreach ($keyPath in @(
                "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$let",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$let",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\$let"
            )) {
                if (Test-Path $keyPath) {
                    Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Write-Ok 'Explorer drive branding cleaned.'

        if ($RemovePrereqs) {
            Write-Note 'scripts\Uninstall.ps1 not found; skipping automated Winget prerequisite removal to avoid removing pre-existing tools.'
        }
    }

    if ($DeleteDir -and (Test-Path $InstallDir)) {
        Write-Step "Deleting installation directory ($InstallDir)..."
        if ((Get-Location).Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) {
            Set-Location $env:USERPROFILE
        }
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $InstallDir)) {
            Write-Ok 'Installation folder deleted successfully.'
        } else {
            Write-Note "Some files in $InstallDir were in use. You can delete it manually."
        }
    }

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host ' [SUCCESS] WinCloudMount uninstallation complete!         ' -ForegroundColor Green
    Write-Host '==========================================================' -ForegroundColor Green
}
