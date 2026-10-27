<#
.SYNOPSIS
    Core orchestrator and daemon manager for WinCloudMount virtual drives.

.DESCRIPTION
    Manages multi-cloud virtual drive mounts using Rclone and WinFsp.
    Provides start, stop, restart, status reporting, and configuration testing.

.PARAMETER Action
    Action to execute: 'start', 'stop', 'restart', 'status', 'test', 'unmount'.

.PARAMETER DriveLetter
    Optional single drive letter to target (e.g. 'E:' or 'E').

.PARAMETER ConfigFile
    Path to custom configuration file. Defaults to '..\config\drives.json'.

.EXAMPLE
    .\Mount-Manager.ps1 -Action start
    .\Mount-Manager.ps1 -Action status
    .\Mount-Manager.ps1 -Action stop
    .\Mount-Manager.ps1 -Action restart -DriveLetter "E:"
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "restart", "status", "test", "unmount", "version")]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [string]$DriveLetter,

    [Parameter()]
    [string]$ConfigFile,

    [Parameter()]
    [switch]$UseExample
)

$AppVersion = "1.0.0"
$ErrorActionPreference = "Continue"

# Resolve directories
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $ProjectRoot "logs"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Resolve Configuration
# Note: we no longer silently fall back to drives.example.json. Missing drives.json is a
# hard error for actions that need a config (start/restart/test); 'status' and 'version'
# work without it. Demo mode is opt-in via -UseExample.
if (-not $ConfigFile) {
    if ($UseExample) {
        $ConfigFile = Join-Path $ProjectRoot "config\drives.example.json"
    } else {
        $ConfigFile = Join-Path $ProjectRoot "config\drives.json"
    }
}

function Assert-DriveConfigExists {
    # Fails fast with actionable guidance when drives.json is missing for a config-requiring action.
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "Configuration file not found: $ConfigFile"
        Write-Error "Create it first, then edit it to set your remotes and drive letters:"
        Write-Error "    Copy-Item config\drives.example.json config\drives.json"
        Write-Error "    notepad config\drives.json"
        Write-Error "Or run with -UseExample to demo against the sample configuration."
        exit 1
    }
}

function Write-MountHeader {
    param ([string]$Title)
    Write-Host "`n=== WinCloudMount v${AppVersion}: $Title ===" -ForegroundColor Cyan
}

function Ensure-RcloneInPath {
    $rclone = Get-Command rclone -ErrorAction SilentlyContinue
    if ($rclone) { return $true }

    # Attempt to reload PATH from registry (in case rclone was installed while terminal was open)
    $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    $rclone = Get-Command rclone -ErrorAction SilentlyContinue
    if ($rclone) { return $true }

    # Check Winget default installation directory
    $wingetRclone = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "rclone.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wingetRclone) {
        $binDir = Split-Path -Parent $wingetRclone.FullName
        $env:PATH = "$binDir;$env:PATH"
        return $true
    }

    return $false
}

function Test-Prerequisites {
    if (-not (Ensure-RcloneInPath)) {
        Write-Error "Rclone executable not found in PATH. Run .\scripts\Install-Prerequisites.ps1 first or restart your terminal."
        return $false
    }

    $winfsp = @(
        "$env:ProgramFiles\WinFsp",
        "${env:ProgramFiles(x86)}\WinFsp"
    ) | Where-Object { Test-Path $_ }

    if (-not $winfsp) {
        Write-Error "WinFsp is not installed. Run .\scripts\Install-Prerequisites.ps1 first."
        return $false
    }

    return $true
}

function Load-DriveConfig {
    try {
        $raw = Get-Content -Raw -Path $ConfigFile -ErrorAction Stop
        $drives = $raw | ConvertFrom-Json
        return $drives
    } catch {
        Write-Error "Failed to parse configuration JSON: $_"
        exit 1
    }
}

function Get-DriveConfigErrors {
    # Returns an array of human-readable validation errors for a single drive config.
    # Empty array = valid. Used by both 'test' and 'start' so a misconfigured drive is
    # rejected with a field-specific message before it ever reaches `rclone mount`.
    param ($DriveConfig)

    $errors = @()

    # Required fields
    if (-not $DriveConfig.remote)       { $errors += "missing required field 'remote'" }
    if (-not $DriveConfig.drive_letter) { $errors += "missing required field 'drive_letter'" }
    if (-not $DriveConfig.volume_name)  { $errors += "missing required field 'volume_name'" }

    # drive_letter must be a single letter plus colon (e.g. 'E:')
    if ($DriveConfig.drive_letter -and $DriveConfig.drive_letter -notmatch '^[A-Za-z]:$') {
        $errors += "drive_letter '$($DriveConfig.drive_letter)' must match '^[A-Za-z]:$'"
    }

    # Injection safety: values interpolated into the rclone command line must never
    # contain a double-quote or control character, or they could break out of the
    # argument quoting and inject a new rclone flag (e.g. --config, --log-file).
    foreach ($field in @('remote', 'volume_name', 'cache_dir', 'name')) {
        $val = $DriveConfig.$field
        if ($val -and ($val -match '["\p{Cc}]')) {
            $errors += "$field contains an illegal double-quote or control character"
        }
    }

    # Size fields, when set, must be <number><unit> with unit M/G/T/P (case-insensitive).
    foreach ($field in @('cache_size', 'cache_min_free_space', 'buffer_size', 'read_chunk_size', 'read_chunk_limit', 'upload_chunk_size')) {
        $val = $DriveConfig.$field
        if ($val -and ($val -notmatch '^[0-9]+[MGTPmgtp]$')) {
            $errors += "$field '$val' must match '^[0-9]+[MGTPmgtp]$'"
        }
    }

    $errors
}

function Get-ConfiguredDriveLetters {
    # Returns the list of drive letters declared in config/drives.json (uppercase, no colon).
    # Used to scope registry cleanup to managed drives only.
    $letters = @()
    try {
        $cfg = Get-Content -Raw -Path $ConfigFile -ErrorAction Stop | ConvertFrom-Json
        foreach ($c in @($cfg)) {
            if ($c.drive_letter) { $letters += $c.drive_letter.ToUpper().TrimEnd(':') }
        }
    } catch {}
    $letters
}

function Clear-StaleNetworkMountPoints {
    param (
        [string[]]$TargetLetters = @()
    )
    # Cleans up orphaned Windows Shell network mount point entries that cause disconnected
    # drive icons (red X). Ownership is strictly verified: we never sweep arbitrary *rclone*
    # keys, only exact managed drive letters or entries that provably reference this
    # project's install directory. Unverifiable entries are left untouched.
    try {
        $mountPointsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
        if (-not (Test-Path $mountPointsKey)) { return }

        # When no explicit letters are supplied (e.g. a generic stop), limit to drives.json.
        if (-not $TargetLetters -or $TargetLetters.Count -eq 0) {
            $TargetLetters = @(Get-ConfiguredDriveLetters)
        }
        $cleanLetters = @($TargetLetters | ForEach-Object { $_.ToUpper().TrimEnd(':') })
        $projectRootEsc = [regex]::Escape($ProjectRoot)

        Get-ChildItem $mountPointsKey -ErrorAction SilentlyContinue | ForEach-Object {
            $childName = $_.PSChildName
            $shouldRemove = $false

            if ($cleanLetters -contains $childName) {
                $shouldRemove = $true
            } elseif ($childName -like "*rclone*") {
                # rclone-named key: remove only if it references this project's install dir.
                $val      = (Get-ItemProperty -Path $_.PSPath -Name '(Default)'      -ErrorAction SilentlyContinue).'(Default)'
                $labelVal = (Get-ItemProperty -Path $_.PSPath -Name '_LabelFromReg'  -ErrorAction SilentlyContinue).'_LabelFromReg'
                if (($val      -and ($val      -match $projectRootEsc -or $val      -match 'WinCloudMount')) -or
                    ($labelVal -and ($labelVal -match $projectRootEsc -or $labelVal -match 'WinCloudMount'))) {
                    $shouldRemove = $true
                }
            }

            if ($shouldRemove) {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

function Wait-ForNetworkConnection {
    param (
        [string[]]$TargetHosts = @("www.googleapis.com", "login.microsoftonline.com", "one.one.one.one"),
        [int]$TimeoutSeconds = 60
    )
    Write-Host "Verifying internet and DNS resolution ($($TargetHosts[0])...)..." -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        foreach ($hostName in $TargetHosts) {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($hostName)
                if ($ips -and $ips.Count -gt 0) {
                    Write-Host "[OK] Network is online. DNS resolved '$hostName' successfully." -ForegroundColor Green
                    return $true
                }
            } catch {}
        }
        Start-Sleep -Seconds 2
    }
    Write-Warning "Network connectivity check reached timeout ($TimeoutSeconds s). Proceeding with mount..."
    return $false
}

function Resolve-DriveIcon {
    param (
        [string]$IconPath,
        [string]$RemoteName,
        [string]$VolumeLabel,
        [string]$ConfigName
    )
    # 1. Explicit path or shorthand provider name
    if ($IconPath) {
        if (-not [System.IO.Path]::IsPathRooted($IconPath)) {
            $candidate = Join-Path $ProjectRoot $IconPath
            if (Test-Path $candidate) { return $candidate }
        } elseif (Test-Path $IconPath) {
            return $IconPath
        }

        # Check shorthand name e.g. "onedrive" -> assets/icons/onedrive.ico
        $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($IconPath).ToLower()
        $candidate = Join-Path $ProjectRoot "assets\icons\$cleanName.ico"
        if (Test-Path $candidate) { return $candidate }
    }

    # 2. Smart auto-detection from Remote, VolumeLabel, or ConfigName
    $identifier = "$RemoteName $VolumeLabel $ConfigName".ToLower()

    # Ordered map so more-specific provider names are tested before shorter, overlapping
    # ones (dropbox before box, googledrive before google). This prevents a Dropbox drive
    # from being mis-detected as Box because "box" is a substring of "dropbox".
    $providerMap = [ordered]@{
        "onedrive"    = "onedrive.ico"
        "sharepoint"  = "onedrive.ico"
        "dropbox"     = "dropbox.ico"
        "nextcloud"   = "nextcloud.ico"
        "owncloud"    = "nextcloud.ico"
        "proton"      = "protondrive.ico"
        "googledrive" = "googledrive.ico"
        "gdrive"      = "googledrive.ico"
        "google"      = "googledrive.ico"
        "backblaze"   = "s3.ico"
        "wasabi"      = "s3.ico"
        "amazon"      = "s3.ico"
        "minio"       = "s3.ico"
        "mega"        = "mega.ico"
        "box"         = "box.ico"
    }

    foreach ($k in $providerMap.Keys) {
        if ($identifier -match $k) {
            $cand = Join-Path $ProjectRoot "assets\icons\$($providerMap[$k])"
            if (Test-Path $cand) { return $cand }
        }
    }

    # 's3' and 'b2' are matched with word boundaries so the short tokens do not
    # false-positive on substrings: 'lab2_nas' must NOT match 'b2', while 's3_backup'
    # (underscore counts as a boundary) matches 's3'.
    foreach ($k in @('s3', 'b2')) {
        $boundaryPattern = '(^|[^a-z0-9])' + $k + '($|[^a-z0-9])'
        if ($identifier -match $boundaryPattern) {
            $cand = Join-Path $ProjectRoot "assets\icons\s3.ico"
            if (Test-Path $cand) { return $cand }
        }
    }

    # 3. Default fallback
    $defaultCandidate = Join-Path $ProjectRoot "assets\icons\googledrive.ico"
    if (Test-Path $defaultCandidate) { return $defaultCandidate }
    return $null
}

function Set-DriveIcon {
    param (
        [string]$DriveLetter,
        [string]$IconPath,
        [string]$VolumeLabel,
        [string]$RemoteName,
        [string]$ConfigName
    )
    $resolvedIcon = Resolve-DriveIcon -IconPath $IconPath -RemoteName $RemoteName -VolumeLabel $VolumeLabel -ConfigName $ConfigName
    if ($resolvedIcon -and (Test-Path $resolvedIcon)) {
        $letterOnly = $DriveLetter.ToUpper().TrimEnd(':')

        # Method 1: Current User Classes (Primary location evaluated by Windows 11 Explorer for per-user drive icons)
        $classesKey = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$letterOnly\DefaultIcon"
        try {
            if (-not (Test-Path $classesKey)) { New-Item -Path $classesKey -Force | Out-Null }
            Set-ItemProperty -Path $classesKey -Name "(Default)" -Value $resolvedIcon -Force
        } catch {}

        if ($VolumeLabel) {
            $labelKey = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$letterOnly\DefaultLabel"
            try {
                if (-not (Test-Path $labelKey)) { New-Item -Path $labelKey -Force | Out-Null }
                Set-ItemProperty -Path $labelKey -Name "(Default)" -Value $VolumeLabel -Force
            } catch {}
        }

        # Method 2: Explorer DriveIcons (Legacy fallback)
        $explorerKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letterOnly\DefaultIcon"
        try {
            if (-not (Test-Path $explorerKey)) { New-Item -Path $explorerKey -Force | Out-Null }
            Set-ItemProperty -Path $explorerKey -Name "(Default)" -Value $resolvedIcon -Force
        } catch {}

        # Broadcast Shell change notification
        try {
            $code = @"
using System;
using System.Runtime.InteropServices;
public class ShellNotifier {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
"@
            if (-not ([System.Management.Automation.PSTypeName]'ShellNotifier').Type) {
                Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue
            }
            [ShellNotifier]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
        } catch {}
    }
}

function Test-GoogleDriveRemote {
    # Heuristic backend detection: returns $true when a remote's root name looks like a
    # Google Drive remote (gdrive/googledrive/google). Used to scope --drive-* flags.
    # NOTE: this is a name heuristic, not a rclone backend query; a precisely-named
    # non-drive remote (e.g. a WebDAV remote called 'google_photos') would be misclassified.
    param([string]$Remote)
    if (-not $Remote) { return $false }
    $root = if ($Remote -match '^([^:]+:)') { $Matches[1] } else { $Remote }
    return ($root.ToLower() -match '(gdrive|googledrive|google)')
}

function Start-DriveMount {
    param ($DriveConfig)

    # Reject invalid / injectable configuration before any side effect.
    $cfgErrors = @(Get-DriveConfigErrors $DriveConfig)
    if ($cfgErrors.Count -gt 0) {
        Write-Error "Drive '$($DriveConfig.name)' has invalid configuration:"
        foreach ($e in $cfgErrors) { Write-Error "  - $e" }
        return
    }

    $driveLet = $DriveConfig.drive_letter.ToUpper()
    if (-not $driveLet.EndsWith(":")) { $driveLet = "$driveLet`:" }
    $letterOnly = $driveLet.TrimEnd(':')

    Clear-StaleNetworkMountPoints -TargetLetters @($letterOnly)

    # Check if the drive letter is currently taken. Get-PSDrive is session-scoped and
    # misses some WinFsp volumes, so also query the kernel via DriveInfo (which catches
    # --network-mode mounts that may not appear as a regular PSDrive).
    $existingPsDrive = Get-PSDrive -Name $letterOnly -ErrorAction SilentlyContinue
    $existingVolume  = $null
    try {
        $existingVolume = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name.TrimEnd('\') -eq $driveLet }
    } catch {}
    if ($existingPsDrive -or $existingVolume) {
        $desc = if ($existingPsDrive) { "$($existingPsDrive.Provider.Name) [$($existingPsDrive.Description)]" } else { "an existing volume" }
        Write-Warning "Drive $driveLet is already in use by $desc. Skipping..."
        return
    }

    # Prepare Cache Directory
    $cacheDir = $DriveConfig.cache_dir
    if (-not $cacheDir) {
        $cacheDir = Join-Path $ProjectRoot ".cache\$($DriveConfig.name)"
    } elseif (-not [System.IO.Path]::IsPathRooted($cacheDir)) {
        $cacheDir = Join-Path $ProjectRoot $cacheDir
    }
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    # Preflight Disk Space Check for VFS Cache
    try {
        $resolvedCacheDir = if ([System.IO.Path]::IsPathRooted($cacheDir)) { $cacheDir } else { Join-Path $ProjectRoot $cacheDir }
        $cacheDriveRoot = [System.IO.Path]::GetPathRoot($resolvedCacheDir)
        if ($cacheDriveRoot) {
            $driveObj = [System.IO.DriveInfo]::new($cacheDriveRoot)
            $availGB = [math]::Round($driveObj.AvailableFreeSpace / 1GB, 2)
            if ($availGB -lt 5.0) {
                Write-Warning "Host disk ($cacheDriveRoot) has only $availGB GB free space remaining! Ensure sufficient space for local VFS caching."
            }
        }
    } catch {}

    # Defaults for resource-efficient tuning
    $cacheSize      = if ($DriveConfig.cache_size) { $DriveConfig.cache_size } else { "20G" }
    $cacheMinFree   = if ($DriveConfig.cache_min_free_space) { $DriveConfig.cache_min_free_space } else { "10G" }
    $bufferSize     = if ($DriveConfig.buffer_size) { $DriveConfig.buffer_size } else { "16M" }
    $readChunkSize  = if ($DriveConfig.read_chunk_size) { $DriveConfig.read_chunk_size } else { "16M" }
    $readChunkLimit = if ($DriveConfig.read_chunk_limit) { $DriveConfig.read_chunk_limit } else { "256M" }
    $volName        = if ($DriveConfig.volume_name) { $DriveConfig.volume_name } else { "CloudDrive - $driveLet" }
    $logFile        = Join-Path $LogDir "$($DriveConfig.name)_mount.log"

    $uploadChunk    = if ($DriveConfig.upload_chunk_size) { $DriveConfig.upload_chunk_size } else { "32M" }

    $rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
    $rcloneExe = if ($rcloneCmd) { $rcloneCmd.Source } else { "rclone.exe" }

    # Argument passing strategy (verified on this machine, PowerShell 5.1 + 7.6):
    #   Start-Process -ArgumentList does NOT re-quote raw array elements that contain
    #   whitespace; a raw array is joined with plain spaces, so "C:\Users\Some One\cache"
    #   would split into multiple tokens. Elements that themselves embed the surrounding
    #   double quotes, however, are preserved intact when the array is passed directly.
    #   We therefore keep each token pre-quoted where it contains whitespace (remote,
    #   drive letter, volume name, cache dir, log file) and pass the array straight to
    #   -ArgumentList WITHOUT a "-join ' '". Combined with Get-DriveConfigErrors (which
    #   rejects embedded double-quotes/control chars), the quoting cannot be escaped.
    $argList = @(
        "mount",
        "`"$($DriveConfig.remote)`"",
        "`"$driveLet`"",
        "--volname `"$volName`"",
        "--vfs-cache-mode full",
        "--vfs-cache-max-size $cacheSize",
        "--vfs-cache-min-free-space $cacheMinFree",
        "--vfs-cache-max-age 24h",
        "--vfs-cache-poll-interval 1m",
        "--cache-dir `"$cacheDir`"",
        "--buffer-size $bufferSize",
        "--vfs-read-chunk-size $readChunkSize",
        "--vfs-read-chunk-size-limit $readChunkLimit",
        "--vfs-fast-fingerprint",
        "--dir-cache-time 24h",
        "--attr-timeout 24h",
        "--poll-interval 1m",
        "--links",
        "--no-modtime",
        "--user-agent `"WinCloudMount/1.0.0 (Windows)`"",
        "--log-file `"$logFile`"",
        "--log-level NOTICE"
    )

    # Google Drive-specific backend flags are added ONLY when the remote is detected as a
    # Google Drive remote (by name). These flags are no-ops on S3/SFTP/WebDAV/NAS backends,
    # so applying them globally was misleading.
    if (Test-GoogleDriveRemote -Remote $DriveConfig.remote) {
        $argList += "--drive-chunk-size $uploadChunk"
        $argList += "--drive-pacer-min-sleep 10ms"
        $argList += "--drive-pacer-burst 200"
    }

    if ($DriveConfig.network_mode -eq $true) {
        # Optional network mode if user explicitly wants it in drives.json
        $argList += "--network-mode"
    }

    if ($DriveConfig.read_only -eq $true) {
        $argList += "--read-only"
    }

    Write-Host "-> Launching mount: $($DriveConfig.remote) => $driveLet [$volName]" -ForegroundColor Cyan
    Write-Host "   Cache: $cacheDir (Cap: $cacheSize, MinFree: $cacheMinFree) | Buffer: $bufferSize" -ForegroundColor Gray

    # Retry loop (up to 3 total attempts) to handle post-boot DNS/network settling
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "   -> Network settling... retry attempt $attempt of $maxAttempts for $driveLet in 4s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 4
        }

        $proc = Start-Process -FilePath $rcloneExe -ArgumentList $argList -WindowStyle Hidden -PassThru

        # Wait briefly and verify the drive actually appears in the OS. A live process alone
        # is NOT proof of a successful mount (WinFsp can leave rclone running without the
        # drive registering in Explorer).
        Start-Sleep -Seconds 3

        $mounted = $false
        try {
            $drivePresent   = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name.TrimEnd('\') -eq $driveLet }
            $psDrivePresent = Get-PSDrive -Name $letterOnly -ErrorAction SilentlyContinue
            if ($drivePresent -or $psDrivePresent) { $mounted = $true }
        } catch {}

        if ($mounted) {
            Set-DriveIcon -DriveLetter $DriveConfig.drive_letter -IconPath $DriveConfig.icon -VolumeLabel $volName -RemoteName $DriveConfig.remote -ConfigName $DriveConfig.name
            Write-Host "   [SUCCESS] Mounted $driveLet (PID: $($proc.Id))" -ForegroundColor Green
            return
        }

        # Not mounted yet: terminate this attempt's process so the next attempt does not
        # contend for the same drive letter with a stuck half-mount.
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "   [FAILED] Failed to mount $driveLet after $maxAttempts attempts. Check log: $logFile" -ForegroundColor Red
    # Tail the log so the user can diagnose without opening the file manually.
    if (Test-Path $logFile) {
        try {
            Write-Host "   Last log lines ($logFile):" -ForegroundColor Yellow
            Get-Content -Path $logFile -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        } catch {}
    }
}

function Stop-DriveMount {
    param ([string]$TargetDrive)

    $allProcs = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue
    if (-not $allProcs) {
        Write-Host "No active rclone mounts detected." -ForegroundColor Yellow
        return
    }

    $projectRootEsc = [regex]::Escape($ProjectRoot)
    $wcmProcs = @($allProcs | Where-Object {
        $cmd = $_.CommandLine
        if (-not $cmd -or ($cmd -notmatch "\bmount\b")) { return $false }
        # Match only processes belonging to WinCloudMount (by project root path, cache-dir/log-file, or user-agent)
        ($cmd -match $projectRootEsc) -or ($cmd -match "WinCloudMount")
    })

    if (-not $wcmProcs -or $wcmProcs.Count -eq 0) {
        Write-Host "No active WinCloudMount rclone processes detected." -ForegroundColor Yellow
        return
    }

    $stoppedLetters = @()

    foreach ($p in $wcmProcs) {
        $cmdLine = $p.CommandLine
        $matched = $false
        $driveInCmd = $null

        if ($cmdLine -match 'mount\s+"?[^"\s]+"?\s+"?([A-Za-z]:)"?') {
            $driveInCmd = $Matches[1].ToUpper()
        }

        if ($TargetDrive) {
            $normalizedTarget = $TargetDrive.ToUpper().TrimEnd(':') + ":"
            if ($driveInCmd -eq $normalizedTarget -or ($cmdLine -match [regex]::Escape($normalizedTarget))) {
                $matched = $true
            }
        } else {
            $matched = $true
        }

        if ($matched) {
            # Check for un-uploaded / dirty files in VFS cache before stopping
            if ($cmdLine -match '--cache-dir\s+"?([^"]+)"?') {
                $targetCacheDir = $Matches[1].Trim()
                $vfsMetaDir = Join-Path $targetCacheDir "vfsMeta"
                if (Test-Path $vfsMetaDir) {
                    try {
                        $dirtyMeta = Get-ChildItem -Path $vfsMetaDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                            (Get-Content -Path $_.FullName -Raw -ErrorAction SilentlyContinue) -match '"Dirty"\s*:\s*true'
                        }
                        if ($dirtyMeta -and $dirtyMeta.Count -gt 0) {
                            $driveLabel = if ($driveInCmd) { $driveInCmd } else { "PID $($p.ProcessId)" }
                            Write-Warning "Drive $driveLabel has $($dirtyMeta.Count) file(s) currently being uploaded to the cloud in VFS cache."
                            Write-Host "   Allowing 3 seconds grace period before terminating (any remaining files will resume uploading on next mount)..." -ForegroundColor Yellow
                            Start-Sleep -Seconds 3
                        }
                    } catch {}
                }
            }

            Write-Host "Stopping rclone mount PID: $($p.ProcessId) $(if ($driveInCmd) { "[$driveInCmd]" })..." -ForegroundColor Yellow
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-Host "[OK] Stopped mount process $($p.ProcessId)." -ForegroundColor Green
                if ($driveInCmd) { $stoppedLetters += $driveInCmd }
            } catch {
                Write-Warning "Could not stop PID $($p.ProcessId): $_"
            }
        }
    }

    if ($stoppedLetters.Count -gt 0) {
        Clear-StaleNetworkMountPoints -TargetLetters $stoppedLetters
    } else {
        Clear-StaleNetworkMountPoints
    }
}

function Show-Status {
    Write-MountHeader "Active Mount Status & Resource Efficiency"

    # Scope to WinCloudMount-owned rclone processes only (same filter as Stop-DriveMount),
    # so a user's separate out-of-project rclone mounts are not shown as this project's.
    $projectRootEsc = [regex]::Escape($ProjectRoot)
    $wcmPids = @(Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $cmd = $_.CommandLine
        $cmd -and ($cmd -match "\bmount\b") -and (($cmd -match $projectRootEsc) -or ($cmd -match "WinCloudMount"))
    } | ForEach-Object { $_.ProcessId })

    $procs = @(Get-Process -Name "rclone" -ErrorAction SilentlyContinue | Where-Object { $wcmPids -contains $_.Id })
    if (-not $procs -or $procs.Count -eq 0) {
        Write-Host "No active rclone mount processes running." -ForegroundColor Yellow
    } else {
        Write-Host "`nRunning Rclone Processes:" -ForegroundColor White
        $procDetails = foreach ($p in $procs) {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue
            $cmd = if ($cim) { $cim.CommandLine } else { "" }
            $mountTarget = "Unknown"
            if ($cmd -match 'mount\s+"?([^"\s]+)"?\s+"?([A-Za-z]:)"?') {
                $mountTarget = "$($Matches[1]) -> $($Matches[2])"
            }

            [PSCustomObject]@{
                PID            = $p.Id
                Mount          = $mountTarget
                "RAM WS (MB)"  = [math]::Round($p.WorkingSet64 / 1MB, 2)
                "Private (MB)" = [math]::Round($p.PrivateMemorySize64 / 1MB, 2)
                "CPU (s)"      = [math]::Round($p.CPU, 2)
                StartTime      = $p.StartTime.ToString("HH:mm:ss")
            }
        }
        $procDetails | Format-Table -AutoSize
    }

    Write-Host "Windows File Explorer Drives:" -ForegroundColor White
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -notmatch "^[CD]:\\" }
    if ($drives) {
        $driveDetails = foreach ($d in $drives) {
            $freeGB  = $null
            $totalGB = $null
            $usedGB  = $null
            $label   = $d.Name.TrimEnd('\')
            try {
                if ($d.IsReady) {
                    $freeGB  = [math]::Round($d.TotalFreeSpace / 1GB, 2)
                    $totalGB = [math]::Round($d.TotalSize / 1GB, 2)
                    $usedGB  = [math]::Round($totalGB - $freeGB, 2)
                    $label   = $d.VolumeLabel
                }
            } catch {}

            [PSCustomObject]@{
                Drive        = $d.Name.TrimEnd('\')
                Label        = $label
                "Used (GB)"  = if ($null -ne $usedGB) { $usedGB } else { "N/A" }
                "Free (GB)"  = if ($null -ne $freeGB) { $freeGB } else { "N/A" }
                "Total (GB)" = if ($null -ne $totalGB) { $totalGB } else { "N/A" }
            }
        }
        $driveDetails | Format-Table -AutoSize
    } else {
        Write-Host "No external/virtual cloud drives currently registered." -ForegroundColor Gray
    }
}

function Test-Config {
    Write-MountHeader "Testing Configuration Integrity"
    Write-Host "Checking config path: $ConfigFile" -ForegroundColor White
    $drives = @(Load-DriveConfig)
    Write-Host "Found $($drives.Count) drive configuration(s):" -ForegroundColor Green

    foreach ($d in $drives) {
        Write-Host "`n- Name        : $($d.name)" -ForegroundColor Cyan
        Write-Host "  Remote      : $($d.remote)"
        Write-Host "  Drive Letter: $($d.drive_letter)"
        Write-Host "  Volume Name : $($d.volume_name)"
        Write-Host "  Cache Cap   : $(if ($d.cache_size) { $d.cache_size } else { '20G (default)' })"
        Write-Host "  Buffer Size : $(if ($d.buffer_size) { $d.buffer_size } else { '16M (default)' })"
        Write-Host "  Upload Chunk: $(if ($d.upload_chunk_size) { $d.upload_chunk_size } else { '32M (optimized)' })"

        # Field validation: missing required fields, invalid patterns, injectable values.
        $cfgErrors = @(Get-DriveConfigErrors $d)
        if ($cfgErrors.Count -gt 0) {
            Write-Host "  Config: [INVALID]" -ForegroundColor Red
            foreach ($e in $cfgErrors) { Write-Host "    - $e" -ForegroundColor Red }
        } else {
            Write-Host "  Config: [OK]" -ForegroundColor Green
        }

        # rclone listremotes returns ROOT remotes only (e.g. 'home_nas:'), so a subpath
        # remote like 'home_nas:/mnt/storage' must be compared by its root, not the full path.
        $remoteRoot = if ($d.remote -and $d.remote -match '^([^:]+:)') { $Matches[1] } elseif ($d.remote) { "$($d.remote):" } else { '' }
        if ($remoteRoot) {
            $checkRemote = & rclone listremotes 2>$null | Where-Object { $_ -eq $remoteRoot }
            if ($checkRemote) {
                Write-Host "  Remote Check: [FOUND] '$remoteRoot' configured in rclone.conf" -ForegroundColor Green
            } else {
                Write-Host "  Remote Check: [NOT CONFIGURED] root '$remoteRoot' is not in rclone.conf. Run 'rclone config' to add it." -ForegroundColor Yellow
            }
        }
    }
}

# --- Execution Router ---
# Prerequisite gate is per-action: 'version' and 'status' must always work (they are the
# diagnostic tools for an incomplete install), so only config/mount actions gate on rclone+WinFsp.
switch ($Action) {
    "start" {
        if (-not (Test-Prerequisites)) { exit 1 }
        Assert-DriveConfigExists
        Write-MountHeader "Starting Configured Virtual Drives"
        $null = Wait-ForNetworkConnection
        $configs = @(Load-DriveConfig)
        foreach ($c in $configs) {
            if ($DriveLetter) {
                $targetNorm = $DriveLetter.ToUpper().TrimEnd(':') + ":"
                if ($c.drive_letter.ToUpper() -eq $targetNorm) {
                    Start-DriveMount -DriveConfig $c
                }
            } else {
                Start-DriveMount -DriveConfig $c
            }
        }
        Write-Host "`nAll mounts initiated. Run '.\Mount-Manager.ps1 -Action status' to inspect." -ForegroundColor Green
    }

    "stop" {
        Write-MountHeader "Stopping Virtual Drives"
        Stop-DriveMount -TargetDrive $DriveLetter
    }

    "unmount" {
        Write-MountHeader "Unmounting Drive"
        Stop-DriveMount -TargetDrive $DriveLetter
    }

    "restart" {
        if (-not (Test-Prerequisites)) { exit 1 }
        Assert-DriveConfigExists
        Write-MountHeader "Restarting Virtual Drives"
        Stop-DriveMount -TargetDrive $DriveLetter
        Start-Sleep -Seconds 1
        & $MyInvocation.MyCommand.Path -Action start -DriveLetter $DriveLetter -ConfigFile $ConfigFile
    }

    "status" {
        Show-Status
    }

    "test" {
        if (-not (Test-Prerequisites)) { exit 1 }
        Assert-DriveConfigExists
        Test-Config
    }

    "version" {
        Write-Host "WinCloudMount v$AppVersion (Rclone + WinFsp Virtual Drive Orchestrator)" -ForegroundColor Green
    }
}
