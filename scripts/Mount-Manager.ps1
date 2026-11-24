<#
.SYNOPSIS
    Core orchestrator and daemon manager for WinCloudMount virtual drives.

.DESCRIPTION
    Manages multi-cloud virtual drive mounts using Rclone and WinFsp.
    Provides start, stop, restart, status reporting, and configuration testing.

.PARAMETER Action
    Action to execute: 'start', 'stop', 'restart', 'status', 'test', 'unmount', 'version'.

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

$AppVersion = "1.2.0"
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $ProjectRoot "logs"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Missing drives.json fails fast for mount/test actions; demo mode is opt-in via -UseExample.
if (-not $ConfigFile) {
    if ($UseExample) {
        $ConfigFile = Join-Path $ProjectRoot "config\drives.example.json"
    } else {
        $ConfigFile = Join-Path $ProjectRoot "config\drives.json"
    }
}

function Assert-DriveConfigExists {
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

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Rotates a log file to .1 when it exceeds MaxBytes.
    #>
    param (
        [string]$LogPath,
        [long]$MaxBytes = 5MB
    )

    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    try {
        $logItem = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
        if ($logItem -and $logItem.Length -gt $MaxBytes) {
            $oldLog = "$LogPath.1"
            if (Test-Path -LiteralPath $oldLog) {
                Remove-Item -LiteralPath $oldLog -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $LogPath -Destination $oldLog -Force -ErrorAction Stop
            return $true
        }
    } catch { $null = $_ }

    return $false
}

function Write-OrchestratorLog {
    param (
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $orchLog = Join-Path $LogDir "orchestrator.log"
        $null = Invoke-LogRotation -LogPath $orchLog -MaxBytes 5MB
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -LiteralPath $orchLog -Value "[$stamp] [$Level] $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { $null = $_ }
}

function Enter-OrchestratorLock {
    param ([int]$TimeoutSeconds = 15)

    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $normRoot = $ProjectRoot.TrimEnd('\').ToLowerInvariant()
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normRoot))
        $sha.Dispose()
        $hashHex = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 12)
        $mutexName = "Local\WinCloudMount-$hashHex"

        $mutex = New-Object System.Threading.Mutex($false, $mutexName)
        $acquired = $false
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        } catch [System.Threading.AbandonedMutexException] {
            # Recover gracefully if a previous process crashed while holding the mutex.
            $acquired = $true
        }

        if (-not $acquired) {
            $mutex.Dispose()
            return $null
        }
        return $mutex
    } catch {
        $null = $_
        return $null
    }
}

function Exit-OrchestratorLock {
    param ([System.Threading.Mutex]$Mutex)

    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { $null = $_ }
    try { $Mutex.Dispose() } catch { $null = $_ }
}

function Ensure-RcloneInPath {
    $rclone = Get-Command rclone -ErrorAction SilentlyContinue
    if ($rclone) { return $true }

    # Reload PATH from registry in case rclone was installed in another session.
    $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    $rclone = Get-Command rclone -ErrorAction SilentlyContinue
    if ($rclone) { return $true }

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

function ConvertTo-RcloneArg {
    <#
    .SYNOPSIS
        Safely formats a parameter value for Rclone command-line arguments on Windows.
    .DESCRIPTION
        Encloses the value in double quotes and doubles trailing backslashes so Win32
        CommandLineToArgvW sees a literal backslash instead of escaping the closing quote.
    #>
    param([string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -match '["\p{Cc}]') {
        throw "Argument contains illegal double-quote or control character: $Value"
    }

    $escaped = $Value -replace '(\\+)$', '$1$1'
    return "`"$escaped`""
}

function Get-MountTargetFromCmdline {
    <#
    .SYNOPSIS
        Extracts the remote source and target drive letter from an rclone mount command line.
    #>
    param([string]$CommandLine)

    if (-not $CommandLine) { return $null }

    $pattern = '\bmount\s+(?:"(?<remote>[^"]+)"|(?<remote>\S+))\s+"?(?<drive>[A-Za-z]:)"?'
    if ($CommandLine -match $pattern) {
        return [PSCustomObject]@{
            Remote      = $Matches['remote']
            DriveLetter = $Matches['drive'].ToUpper()
        }
    }
    return $null
}

function Get-CacheDirFromCmdline {
    <#
    .SYNOPSIS
        Extracts the --cache-dir value from an rclone mount command line using token-aware matching.
    #>
    param([string]$CommandLine)

    if (-not $CommandLine) { return $null }

    $pattern = '--cache-dir\s+(?:"(?<dir>[^"]+)"|(?<dir>\S+))'
    if ($CommandLine -match $pattern) {
        return $Matches['dir'].Trim()
    }
    return $null
}

function Get-ConfigPropValue {
    param (
        $Object,
        [string]$PropertyName
    )

    if ($Object -and $Object.PSObject.Properties[$PropertyName]) {
        return $Object.$PropertyName
    }
    return $null
}

function Get-DriveConfigErrors {
    <#
    .SYNOPSIS
        Validates a single drive configuration object from drives.json without side effects.
    #>
    param ($DriveConfig)

    $errors = @()

    $name     = Get-ConfigPropValue $DriveConfig 'name'
    $remote   = Get-ConfigPropValue $DriveConfig 'remote'
    $driveLet = Get-ConfigPropValue $DriveConfig 'drive_letter'
    $volName  = Get-ConfigPropValue $DriveConfig 'volume_name'
    $cacheDir = Get-ConfigPropValue $DriveConfig 'cache_dir'

    if (-not $name)     { $errors += "missing required field 'name'" }
    if (-not $remote)   { $errors += "missing required field 'remote'" }
    if (-not $driveLet) { $errors += "missing required field 'drive_letter'" }
    if (-not $volName)  { $errors += "missing required field 'volume_name'" }

    if ($name -and ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')) {
        $errors += "name '$name' must match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'"
    }

    if ($driveLet -and $driveLet -notmatch '^[A-Za-z]:$') {
        $errors += "drive_letter '$driveLet' must match '^[A-Za-z]:$'"
    }

    # Prevent quote breakout or control character injection in native rclone arguments.
    foreach ($field in @('remote', 'volume_name', 'cache_dir', 'name', 'icon')) {
        $val = Get-ConfigPropValue $DriveConfig $field
        if ($val -and ($val -match '["\p{Cc}]')) {
            $errors += "$field contains an illegal double-quote or control character"
        }
    }

    if ($cacheDir -and ($cacheDir -match '[\\/]$')) {
        $errors += "cache_dir '$cacheDir' must not end with a trailing slash or backslash; use paths like 'D:\Cache' or '.cache\name'"
    }

    foreach ($field in @('cache_size', 'cache_min_free_space', 'read_chunk_size', 'read_chunk_limit', 'upload_chunk_size')) {
        $val = Get-ConfigPropValue $DriveConfig $field
        if ($null -ne $val -and "$val" -ne "" -and ("$val" -notmatch '^[1-9][0-9]*[KkMmGgTtPp][Ii]?$')) {
            $errors += "$field '$val' must match '^[1-9][0-9]*[KkMmGgTtPp][Ii]?$'"
        }
    }

    foreach ($field in @('buffer_size', 'vfs_read_ahead')) {
        $val = Get-ConfigPropValue $DriveConfig $field
        if ($null -ne $val -and "$val" -ne "" -and ("$val" -notmatch '^(0|[0-9]+[KkMmGgTtPp][Ii]?)$')) {
            $errors += "$field '$val' must match '^(0|[0-9]+[KkMmGgTtPp][Ii]?)$'"
        }
    }

    foreach ($field in @('dir_cache_time', 'attr_timeout', 'poll_interval', 'vfs_cache_max_age', 'vfs_write_back')) {
        $val = Get-ConfigPropValue $DriveConfig $field
        if ($null -ne $val -and "$val" -ne "" -and ("$val" -notmatch '^(0|[1-9][0-9]*(ms|s|m|h|d))$')) {
            $errors += "$field '$val' must match '^(0|[1-9][0-9]*(ms|s|m|h|d))$'"
        }
    }

    $streams = Get-ConfigPropValue $DriveConfig 'read_chunk_streams'
    if ($null -ne $streams) {
        $parsedStreams = 0
        if (($streams -is [bool]) -or -not [int]::TryParse("$streams", [ref]$parsedStreams) -or $parsedStreams -lt 0 -or $parsedStreams -gt 32) {
            $errors += "read_chunk_streams '$streams' must be an integer between 0 and 32"
        }
    }

    $transfers = Get-ConfigPropValue $DriveConfig 'transfers'
    if ($null -ne $transfers) {
        $parsedTransfers = 0
        if (($transfers -is [bool]) -or -not [int]::TryParse("$transfers", [ref]$parsedTransfers) -or $parsedTransfers -lt 1 -or $parsedTransfers -gt 32) {
            $errors += "transfers '$transfers' must be an integer between 1 and 32"
        }
    }

    $logLevel = Get-ConfigPropValue $DriveConfig 'log_level'
    if ($null -ne $logLevel -and "$logLevel" -ne "") {
        if ("$logLevel" -cnotin @('ERROR', 'NOTICE', 'INFO', 'DEBUG')) {
            $errors += "log_level '$logLevel' must be one of ERROR, NOTICE, INFO, DEBUG"
        }
    }

    $errors
}

function Get-DriveCollectionErrors {
    <#
    .SYNOPSIS
        Validates cross-drive uniqueness for drive_letter, name, and resolved cache_dir.
    #>
    param (
        $DriveConfigs,
        [string]$ProjectRootPath = $ProjectRoot
    )

    $errors = @()
    $seenLetters = @{}
    $seenNames   = @{}
    $seenCaches  = @{}

    foreach ($cfg in @($DriveConfigs)) {
        $rawLetter = Get-ConfigPropValue $cfg 'drive_letter'
        if ($rawLetter) {
            $normLet = "$rawLetter".ToUpperInvariant().TrimEnd(':') + ":"
            if ($seenLetters.ContainsKey($normLet)) {
                $errors += "Duplicate drive_letter '$normLet' found in configuration"
            } else {
                $seenLetters[$normLet] = $true
            }
        }

        $rawName = Get-ConfigPropValue $cfg 'name'
        if ($rawName) {
            $normName = "$rawName".ToLowerInvariant()
            if ($seenNames.ContainsKey($normName)) {
                $errors += "Duplicate drive name '$rawName' found in configuration"
            } else {
                $seenNames[$normName] = $true
            }
        }

        $rawCache = Get-ConfigPropValue $cfg 'cache_dir'
        $resolvedCache = $null
        if ($rawCache) {
            if ([System.IO.Path]::IsPathRooted("$rawCache")) {
                $resolvedCache = "$rawCache"
            } else {
                $resolvedCache = Join-Path $ProjectRootPath "$rawCache"
            }
        } elseif ($rawName) {
            $resolvedCache = Join-Path $ProjectRootPath ".cache\$rawName"
        }

        if ($resolvedCache) {
            try {
                $fullCache = [System.IO.Path]::GetFullPath($resolvedCache).TrimEnd('\', '/').ToLowerInvariant()
                if ($seenCaches.ContainsKey($fullCache)) {
                    $errors += "Duplicate cache_dir '$fullCache' shared by multiple drives"
                } else {
                    $seenCaches[$fullCache] = $true
                }
            } catch { $null = $_ }
        }
    }

    $errors
}

function Get-VfsCacheStats {
    param ([string]$CacheDir)

    $stats = [PSCustomObject]@{
        FileCount  = 0
        SizeMB     = 0.0
        DirtyCount = 0
    }

    if (-not $CacheDir -or -not (Test-Path -LiteralPath $CacheDir)) {
        return $stats
    }

    try {
        $vfsDir = Join-Path $CacheDir "vfs"
        if (Test-Path -LiteralPath $vfsDir) {
            [long]$totalBytes = 0
            [int]$count = 0
            $files = Get-ChildItem -LiteralPath $vfsDir -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                $totalBytes += $f.Length
                $count++
            }
            $stats.FileCount = $count
            $stats.SizeMB = [math]::Round($totalBytes / 1MB, 2)
        }

        $vfsMetaDir = Join-Path $CacheDir "vfsMeta"
        if (Test-Path -LiteralPath $vfsMetaDir) {
            [int]$dirty = 0
            $metaFiles = Get-ChildItem -LiteralPath $vfsMetaDir -Recurse -File -ErrorAction SilentlyContinue
            foreach ($m in $metaFiles) {
                $raw = Get-Content -LiteralPath $m.FullName -Raw -ErrorAction SilentlyContinue
                if ($raw -and ($raw -match '"Dirty"\s*:\s*true')) {
                    $dirty++
                }
            }
            $stats.DirtyCount = $dirty
        }
    } catch { $null = $_ }

    return $stats
}

function Get-ConfiguredDriveLetters {
    $letters = @()
    try {
        if (Test-Path -LiteralPath $ConfigFile) {
            $cfg = Get-Content -Raw -Path $ConfigFile -ErrorAction Stop | ConvertFrom-Json
            foreach ($c in @($cfg)) {
                if ($c.drive_letter) { $letters += $c.drive_letter.ToUpper().TrimEnd(':') }
            }
        }
    } catch { $null = $_ }
    $letters
}

function Clear-StaleNetworkMountPoints {
    param (
        [string[]]$TargetLetters = @()
    )
    # Remove only MountPoints2 keys belonging to managed drive letters or this install directory.
    try {
        $mountPointsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
        if (-not (Test-Path $mountPointsKey)) { return }

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
                $val      = (Get-ItemProperty -Path $_.PSPath -Name '(Default)'     -ErrorAction SilentlyContinue).'(Default)'
                $labelVal = (Get-ItemProperty -Path $_.PSPath -Name '_LabelFromReg' -ErrorAction SilentlyContinue).'_LabelFromReg'
                if (($val      -and ($val      -match $projectRootEsc -or $val      -match 'WinCloudMount')) -or
                    ($labelVal -and ($labelVal -match $projectRootEsc -or $labelVal -match 'WinCloudMount'))) {
                    $shouldRemove = $true
                }
            }

            if ($shouldRemove) {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { $null = $_ }
}

function Wait-ForNetworkConnection {
    param (
        [string[]]$TargetHosts = @("oauth2.googleapis.com", "login.microsoftonline.com", "one.one.one.one"),
        [int]$TimeoutSeconds = 60,
        [int]$ConnectTimeoutMs = 2500
    )
    Write-Host "Verifying internet and TLS reachability ($($TargetHosts[0]):443...)..." -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        foreach ($hostName in $TargetHosts) {
            $client = $null
            try {
                # Probe TCP/443 instead of DNS alone so stale local DNS cache entries do not give false positives.
                $client = New-Object System.Net.Sockets.TcpClient
                $asyncResult = $client.BeginConnect($hostName, 443, $null, $null)
                $connected = $asyncResult.AsyncWaitHandle.WaitOne($ConnectTimeoutMs, $false)
                if ($connected -and $client.Connected) {
                    $client.EndConnect($asyncResult)
                    Write-Host "[OK] Network is online. TLS endpoint '$hostName`:443' reachable." -ForegroundColor Green
                    Write-OrchestratorLog "Network check passed (${hostName}:443 reachable)."
                    return $true
                }
            } catch { $null = $_ } finally {
                if ($client) {
                    try { $client.Close(); $client.Dispose() } catch { $null = $_ }
                }
            }
        }
        Start-Sleep -Seconds 2
    }
    Write-Warning "Network connectivity check reached timeout (${TimeoutSeconds}s). Proceeding with mount..."
    Write-OrchestratorLog -Level WARN -Message "Network connectivity check reached timeout (${TimeoutSeconds}s); attempting mounts anyway."
    return $false
}

function Resolve-DriveIcon {
    param (
        [string]$IconPath,
        [string]$RemoteName,
        [string]$VolumeLabel,
        [string]$ConfigName
    )
    if ($IconPath) {
        if (-not [System.IO.Path]::IsPathRooted($IconPath)) {
            $candidate = Join-Path $ProjectRoot $IconPath
            if (Test-Path $candidate) { return $candidate }
        } elseif (Test-Path $IconPath) {
            return $IconPath
        }

        $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($IconPath).ToLower()
        $candidate = Join-Path $ProjectRoot "assets\icons\$cleanName.ico"
        if (Test-Path $candidate) { return $candidate }
    }

    $identifier = "$RemoteName $VolumeLabel $ConfigName".ToLower()

    # Check specific names before overlapping substrings (dropbox before box, googledrive before google).
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

    # Require non-alphanumeric boundaries around short tokens ('s3', 'b2') to avoid substring collisions like 'lab2_nas'.
    foreach ($k in @('s3', 'b2')) {
        $boundaryPattern = '(^|[^a-z0-9])' + $k + '($|[^a-z0-9])'
        if ($identifier -match $boundaryPattern) {
            $cand = Join-Path $ProjectRoot "assets\icons\s3.ico"
            if (Test-Path $cand) { return $cand }
        }
    }

    $defaultCandidate = Join-Path $ProjectRoot "assets\icons\googledrive.ico"
    if (Test-Path $defaultCandidate) { return $defaultCandidate }
    return $null
}

function Invoke-ShellRefresh {
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
    } catch { $null = $_ }
}

function Set-DriveIcon {
    param (
        [string]$DriveLetter,
        [string]$IconPath,
        [string]$VolumeLabel,
        [string]$RemoteName,
        [string]$ConfigName,
        [switch]$SkipShellNotify
    )
    $resolvedIcon = Resolve-DriveIcon -IconPath $IconPath -RemoteName $RemoteName -VolumeLabel $VolumeLabel -ConfigName $ConfigName
    if ($resolvedIcon -and (Test-Path $resolvedIcon)) {
        $letterOnly = $DriveLetter.ToUpper().TrimEnd(':')

        $classesKey = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$letterOnly\DefaultIcon"
        try {
            if (-not (Test-Path $classesKey)) { New-Item -Path $classesKey -Force | Out-Null }
            Set-ItemProperty -Path $classesKey -Name "(Default)" -Value $resolvedIcon -Force
        } catch { $null = $_ }

        if ($VolumeLabel) {
            $labelKey = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$letterOnly\DefaultLabel"
            try {
                if (-not (Test-Path $labelKey)) { New-Item -Path $labelKey -Force | Out-Null }
                Set-ItemProperty -Path $labelKey -Name "(Default)" -Value $VolumeLabel -Force
            } catch { $null = $_ }
        }

        $explorerKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letterOnly\DefaultIcon"
        try {
            if (-not (Test-Path $explorerKey)) { New-Item -Path $explorerKey -Force | Out-Null }
            Set-ItemProperty -Path $explorerKey -Name "(Default)" -Value $resolvedIcon -Force
        } catch { $null = $_ }

        if (-not $SkipShellNotify) {
            Invoke-ShellRefresh
        }
    }
}

function Get-RemoteBackendInfo {
    <#
    .SYNOPSIS
        Inspects rclone backend type and custom OAuth client_id presence without retaining secret values.
    #>
    param ([string]$Remote)

    $info = [PSCustomObject]@{
        RootName          = ""
        Type              = "unknown"
        HasCustomClientId = $false
        Authoritative     = $false
    }

    if (-not $Remote) { return $info }
    $root = if ($Remote -match '^([^:]+:)') { $Matches[1] } else { $Remote }
    $rootName = $root.TrimEnd(':')
    $info.RootName = $rootName

    try {
        $rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
        if ($rcloneCmd) {
            $lines = @(& $rcloneCmd.Source --ask-password=false config show $rootName 2>$null)
            foreach ($line in $lines) {
                if ($line -match '^\s*type\s*=\s*(.+)$') {
                    $info.Type = $Matches[1].Trim().ToLowerInvariant()
                    $info.Authoritative = $true
                } elseif ($line -match '^\s*client_id\s*=\s*(.+)$') {
                    if ($Matches[1].Trim().Length -gt 0) {
                        $info.HasCustomClientId = $true
                    }
                }
            }
            if ($info.Authoritative) {
                return $info
            }
        }
    } catch { $null = $_ }

    $lowerRoot = $root.ToLowerInvariant()
    if ($lowerRoot -match '(gdrive|googledrive|google)') {
        $info.Type = "drive"
    } elseif ($lowerRoot -match '(onedrive|sharepoint)') {
        $info.Type = "onedrive"
    } elseif ($lowerRoot -match 'dropbox') {
        $info.Type = "dropbox"
    } elseif ($lowerRoot -match '(^|[^a-z0-9])(s3|b2)($|[^a-z0-9])|wasabi|backblaze|minio|r2') {
        $info.Type = "s3"
    }

    return $info
}

function Test-GoogleDriveRemote {
    param([string]$Remote)
    return ((Get-RemoteBackendInfo -Remote $Remote).Type -eq 'drive')
}

function Build-RcloneMountArgs {
    <#
    .SYNOPSIS
        Builds the rclone mount argument list from drive config and detected backend info.
    #>
    param (
        $DriveConfig,
        [string]$DriveLetter,
        [string]$VolumeName,
        [string]$SafeCacheDir,
        [string]$LogFile,
        $BackendInfo,
        [string]$Version = $AppVersion
    )

    $backendType = if ($BackendInfo -and $BackendInfo.Type) { $BackendInfo.Type.ToLowerInvariant() } else { "unknown" }
    $hasCustomClientId = if ($BackendInfo) { [bool]$BackendInfo.HasCustomClientId } else { $false }
    $authoritative = if ($BackendInfo) { [bool]$BackendInfo.Authoritative } else { $false }

    $cacheSizeProp    = Get-ConfigPropValue $DriveConfig 'cache_size'
    $minFreeProp      = Get-ConfigPropValue $DriveConfig 'cache_min_free_space'
    $maxAgeProp       = Get-ConfigPropValue $DriveConfig 'vfs_cache_max_age'
    $writeBackProp    = Get-ConfigPropValue $DriveConfig 'vfs_write_back'
    $bufferProp       = Get-ConfigPropValue $DriveConfig 'buffer_size'
    $readAheadProp    = Get-ConfigPropValue $DriveConfig 'vfs_read_ahead'
    $readChunkProp    = Get-ConfigPropValue $DriveConfig 'read_chunk_size'
    $readLimitProp    = Get-ConfigPropValue $DriveConfig 'read_chunk_limit'
    $readStreamsProp  = Get-ConfigPropValue $DriveConfig 'read_chunk_streams'
    $dirCacheProp     = Get-ConfigPropValue $DriveConfig 'dir_cache_time'
    $attrTimeoutProp  = Get-ConfigPropValue $DriveConfig 'attr_timeout'
    $pollIntervalProp = Get-ConfigPropValue $DriveConfig 'poll_interval'
    $transfersProp    = Get-ConfigPropValue $DriveConfig 'transfers'
    $uploadChunkProp  = Get-ConfigPropValue $DriveConfig 'upload_chunk_size'
    $logLevelProp     = Get-ConfigPropValue $DriveConfig 'log_level'
    $noModtimeProp    = Get-ConfigPropValue $DriveConfig 'no_modtime'
    $vfsRefreshProp   = Get-ConfigPropValue $DriveConfig 'vfs_refresh'
    $networkModeProp  = Get-ConfigPropValue $DriveConfig 'network_mode'
    $readOnlyProp     = Get-ConfigPropValue $DriveConfig 'read_only'

    $cacheSize      = if ($cacheSizeProp) { "$cacheSizeProp" } else { "20G" }
    $cacheMinFree   = if ($minFreeProp) { "$minFreeProp" } else { "10G" }
    $cacheMaxAge    = if ($maxAgeProp) { "$maxAgeProp" } else { "168h" }
    $writeBack      = if ($writeBackProp) { "$writeBackProp" } else { "5s" }
    $bufferSize     = if ($null -ne $bufferProp -and "$bufferProp" -ne "") { "$bufferProp" } else { "16M" }
    $readAhead      = if ($null -ne $readAheadProp -and "$readAheadProp" -ne "") { "$readAheadProp" } else { "128M" }
    $readChunkSize  = if ($readChunkProp) { "$readChunkProp" } else { "16M" }
    $readChunkLimit = if ($readLimitProp) { "$readLimitProp" } else { "256M" }

    # Avoid parallel read-ahead streams on unconfigured shared Google client_id to reduce 403 risk.
    if ($null -ne $readStreamsProp) {
        $readChunkStreams = [int]$readStreamsProp
    } elseif ($backendType -eq 'drive' -and $authoritative -and -not $hasCustomClientId) {
        $readChunkStreams = 0
    } else {
        $readChunkStreams = 4
    }

    if ($dirCacheProp) {
        $dirCacheTime = "$dirCacheProp"
    } elseif ($backendType -in @('drive', 'onedrive', 'dropbox')) {
        $dirCacheTime = "72h"
    } else {
        $dirCacheTime = "24h"
    }

    $attrTimeout  = if ($attrTimeoutProp) { "$attrTimeoutProp" } else { "1s" }
    $pollInterval = if ($pollIntervalProp) { "$pollIntervalProp" } else { "1m" }

    if ($null -ne $transfersProp) {
        $transfers = [int]$transfersProp
    } elseif ($backendType -eq 'drive' -and $hasCustomClientId) {
        $transfers = 6
    } else {
        $transfers = 4
    }

    $logLevel = if ($logLevelProp) { "$logLevelProp".ToUpperInvariant() } else { "NOTICE" }

    $argList = @(
        "mount",
        (ConvertTo-RcloneArg $DriveConfig.remote),
        (ConvertTo-RcloneArg $DriveLetter),
        "--volname", (ConvertTo-RcloneArg $VolumeName),
        "--vfs-cache-mode", "full",
        "--vfs-cache-max-size", $cacheSize,
        "--vfs-cache-min-free-space", $cacheMinFree,
        "--vfs-cache-max-age", $cacheMaxAge,
        "--vfs-cache-poll-interval", "1m",
        "--vfs-write-back", $writeBack,
        "--cache-dir", (ConvertTo-RcloneArg $SafeCacheDir),
        "--buffer-size", $bufferSize
    )

    if ($readAhead -notmatch '^0([KkMmGgTtPp][Ii]?)?$') {
        $argList += @("--vfs-read-ahead", $readAhead)
    }

    $argList += @("--vfs-read-chunk-size", $readChunkSize)
    if ($readChunkStreams -gt 0) {
        $argList += @("--vfs-read-chunk-streams", "$readChunkStreams")
    } else {
        $argList += @("--vfs-read-chunk-size-limit", $readChunkLimit)
    }

    $argList += @(
        "--vfs-fast-fingerprint",
        "--dir-cache-time", $dirCacheTime,
        "--attr-timeout", $attrTimeout,
        "--poll-interval", $pollInterval,
        "--transfers", "$transfers",
        "--links",
        "--user-agent", (ConvertTo-RcloneArg "WinCloudMount/$Version (Windows)"),
        "--log-file", (ConvertTo-RcloneArg $LogFile),
        "--log-level", $logLevel,
        "--ask-password=false"
    )

    # Global --no-modtime breaks Date Modified on Drive/OneDrive; limit default to object stores.
    $useNoModtime = $false
    if ($null -ne $noModtimeProp) {
        $useNoModtime = ($noModtimeProp -eq $true)
    } elseif ($backendType -in @('s3', 'swift', 'b2')) {
        $useNoModtime = $true
    }
    if ($useNoModtime) {
        $argList += "--no-modtime"
    }

    if ($vfsRefreshProp -eq $true) {
        $argList += "--vfs-refresh"
    }

    if ($backendType -eq 'drive') {
        $driveChunk = if ($uploadChunkProp) { "$uploadChunkProp" } else { "32M" }
        $argList += @("--drive-chunk-size", $driveChunk)
        # Aggressive pacer settings worsen 403 throttling on rclone's shared client_id.
        if ($hasCustomClientId) {
            $argList += @("--drive-pacer-min-sleep", "10ms", "--drive-pacer-burst", "200")
        }
    } elseif ($backendType -eq 'onedrive') {
        $onedriveChunk = if ($uploadChunkProp) { "$uploadChunkProp" } else { "50Mi" }
        $argList += @("--onedrive-chunk-size", $onedriveChunk)
    }

    if ($networkModeProp -eq $true) {
        $argList += "--network-mode"
    }

    if ($readOnlyProp -eq $true) {
        $argList += "--read-only"
    }

    return $argList
}

function Test-PermanentMountFailureLog {
    param ([string]$LogFile)

    if (-not $LogFile -or -not (Test-Path -LiteralPath $LogFile)) {
        return $false
    }

    try {
        $tail = (Get-Content -LiteralPath $LogFile -Tail 15 -ErrorAction SilentlyContinue) -join "`n"
        if ($tail -match "didn't find section in config file|invalid_grant|token expired|unknown flag|unauthorized_client|access_denied") {
            return $true
        }
    } catch { $null = $_ }

    return $false
}

function Start-ConfiguredMounts {
    param (
        $DriveConfigs,
        [string]$TargetDriveLetter
    )

    $allConfigs = @($DriveConfigs)
    $collectionErrors = @(Get-DriveCollectionErrors -DriveConfigs $allConfigs -ProjectRootPath $ProjectRoot)
    if ($collectionErrors.Count -gt 0) {
        Write-Error "Configuration contains cross-drive conflicts:"
        foreach ($e in $collectionErrors) {
            Write-Error "  - $e"
            Write-OrchestratorLog -Level ERROR -Message "Config conflict: $e"
        }
        return $false
    }

    foreach ($c in $allConfigs) {
        $cfgErrors = @(Get-DriveConfigErrors $c)
        if ($cfgErrors.Count -gt 0) {
            Write-Error "Drive '$($c.name)' has invalid configuration:"
            foreach ($e in $cfgErrors) {
                Write-Error "  - $e"
                Write-OrchestratorLog -Level ERROR -Message "Invalid config on '$($c.name)': $e"
            }
            return $false
        }
    }

    $selected = @()
    if ($TargetDriveLetter) {
        $targetNorm = $TargetDriveLetter.ToUpper().TrimEnd(':') + ":"
        $selected = @($allConfigs | Where-Object { $_.drive_letter.ToUpper().TrimEnd(':') + ":" -eq $targetNorm })
        if ($selected.Count -eq 0) {
            Write-Error "No drive configuration found matching drive letter '$targetNorm'."
            Write-OrchestratorLog -Level ERROR -Message "No drive configuration matched target '$targetNorm'."
            return $false
        }
    } else {
        $selected = $allConfigs
    }

    $existingDriveLetters = @()
    try {
        $existingDriveLetters = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.TrimEnd('\').ToUpper() })
    } catch { $null = $_ }

    $rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
    $rcloneExe = if ($rcloneCmd) { $rcloneCmd.Source } else { "rclone.exe" }

    $pending = @()
    foreach ($cfg in $selected) {
        $driveLet = $cfg.drive_letter.ToUpper().TrimEnd(':') + ":"
        $letterOnly = $driveLet.TrimEnd(':')

        Clear-StaleNetworkMountPoints -TargetLetters @($letterOnly)

        $existingPsDrive = Get-PSDrive -Name $letterOnly -ErrorAction SilentlyContinue
        $existingVolume = ($existingDriveLetters -contains $driveLet)
        if ($existingPsDrive -or $existingVolume) {
            $desc = if ($existingPsDrive) { "$($existingPsDrive.Provider.Name) [$($existingPsDrive.Description)]" } else { "an existing volume" }
            Write-Warning "Drive $driveLet is already in use by $desc. Skipping..."
            Write-OrchestratorLog "Skipped $driveLet ($($cfg.name)): already mounted ($desc)."
            continue
        }

        $cacheDir = Get-ConfigPropValue $cfg 'cache_dir'
        if (-not $cacheDir) {
            $cacheDir = Join-Path $ProjectRoot ".cache\$($cfg.name)"
        } elseif (-not [System.IO.Path]::IsPathRooted("$cacheDir")) {
            $cacheDir = Join-Path $ProjectRoot "$cacheDir"
        }
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }

        try {
            $cacheDriveRoot = [System.IO.Path]::GetPathRoot($cacheDir)
            if ($cacheDriveRoot) {
                $driveObj = [System.IO.DriveInfo]::new($cacheDriveRoot)
                $availGB = [math]::Round($driveObj.AvailableFreeSpace / 1GB, 2)
                if ($availGB -lt 5.0) {
                    Write-Warning "Host disk ($cacheDriveRoot) has only $availGB GB free space remaining."
                    Write-OrchestratorLog -Level WARN -Message "Low disk space on $cacheDriveRoot (${availGB} GB free) for $($cfg.name)."
                }
            }
        } catch { $null = $_ }

        $logFile = Join-Path $LogDir "$($cfg.name)_mount.log"
        if (Invoke-LogRotation -LogPath $logFile -MaxBytes 5MB) {
            Write-Host "   Rotated log file > 5 MB to $(Split-Path -Leaf $logFile).1" -ForegroundColor Gray
        }

        $safeCacheDir = $cacheDir.TrimEnd('\', '/')
        $volName = if ($cfg.volume_name) { $cfg.volume_name } else { "CloudDrive - $driveLet" }
        $backendInfo = Get-RemoteBackendInfo -Remote $cfg.remote

        if ($backendInfo.Type -eq 'drive' -and $backendInfo.Authoritative -and -not $backendInfo.HasCustomClientId) {
            Write-Warning "Remote '$($cfg.remote)' uses rclone's shared Google Drive client_id, which is rate-limited (403). Configure a personal Client ID via docs\GOOGLE_CLIENT_ID_SETUP.md."
            Write-OrchestratorLog -Level WARN -Message "Remote '$($cfg.remote)' ($driveLet) uses shared Google Drive client_id."
        }

        $argList = Build-RcloneMountArgs -DriveConfig $cfg -DriveLetter $driveLet -VolumeName $volName -SafeCacheDir $safeCacheDir -LogFile $logFile -BackendInfo $backendInfo -Version $AppVersion

        $cacheSizeDisp = if (Get-ConfigPropValue $cfg 'cache_size') { $cfg.cache_size } else { "20G" }
        $bufDisp       = if ($null -ne (Get-ConfigPropValue $cfg 'buffer_size')) { $cfg.buffer_size } else { "16M" }
        Write-Host "-> Queuing mount: $($cfg.remote) => $driveLet [$volName] ($($backendInfo.Type))" -ForegroundColor Cyan
        Write-Host "   Cache: $cacheDir (Cap: $cacheSizeDisp) | Buffer: $bufDisp" -ForegroundColor Gray

        $pending += [PSCustomObject]@{
            Config      = $cfg
            DriveLetter = $driveLet
            LetterOnly  = $letterOnly
            VolumeName  = $volName
            LogFile     = $logFile
            ArgList     = $argList
        }
    }

    if ($pending.Count -eq 0) {
        return $true
    }

    $maxAttempts = 3
    $pollIntervalSeconds = 2
    $attemptPollLimitSeconds = 45
    $mountedAny = $false
    $hasFailure = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($pending.Count -eq 0) { break }

        if ($attempt -gt 1) {
            Write-Host "   -> Network settling... retry attempt $attempt of $maxAttempts for $($pending.Count) drive(s) in 4s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 4
        }

        $wave = @()
        foreach ($item in $pending) {
            $proc = Start-Process -FilePath $rcloneExe -ArgumentList $item.ArgList -WindowStyle Hidden -PassThru
            $wave += [PSCustomObject]@{
                Item  = $item
                Proc  = $proc
                State = "Pending"
            }
        }

        $pollStart = Get-Date
        while (((Get-Date) - $pollStart).TotalSeconds -lt $attemptPollLimitSeconds) {
            $stillPending = @($wave | Where-Object { $_.State -eq "Pending" })
            if ($stillPending.Count -eq 0) { break }

            Start-Sleep -Seconds $pollIntervalSeconds

            $currentVolumes = @()
            try {
                $currentVolumes = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.TrimEnd('\').ToUpper() })
            } catch { $null = $_ }

            foreach ($entry in $stillPending) {
                try { $entry.Proc.Refresh() } catch { $null = $_ }
                if ($entry.Proc.HasExited) {
                    $entry.State = "Exited"
                    continue
                }
                $psDrivePresent = Get-PSDrive -Name $entry.Item.LetterOnly -ErrorAction SilentlyContinue
                if (($currentVolumes -contains $entry.Item.DriveLetter) -or $psDrivePresent) {
                    $entry.State = "Mounted"
                }
            }

            if (@($wave | Where-Object { $_.State -eq "Pending" }).Count -eq 0) {
                break
            }
        }

        $elapsed = [math]::Round(((Get-Date) - $pollStart).TotalSeconds, 1)
        $nextPending = @()

        foreach ($entry in $wave) {
            $item = $entry.Item
            if ($entry.State -eq "Mounted") {
                Set-DriveIcon -DriveLetter $item.DriveLetter -IconPath (Get-ConfigPropValue $item.Config 'icon') -VolumeLabel $item.VolumeName -RemoteName $item.Config.remote -ConfigName $item.Config.name -SkipShellNotify
                Write-Host "   [SUCCESS] Mounted $($item.DriveLetter) (PID: $($entry.Proc.Id)) after ~${elapsed}s" -ForegroundColor Green
                Write-OrchestratorLog "Mounted $($item.DriveLetter) ($($item.Config.remote)) PID=$($entry.Proc.Id) in ${elapsed}s (attempt $attempt)."
                $mountedAny = $true
                continue
            }

            try { $entry.Proc.Refresh() } catch { $null = $_ }
            $exited = $entry.Proc.HasExited
            $why = if ($exited) { 'rclone process exited' } else { 'drive not detected (WinFsp handshake timeout)' }
            Write-Host "   Attempt ${attempt} [$($item.DriveLetter)]: not mounted after ~${elapsed}s ($why)" -ForegroundColor Yellow

            if ($entry.Proc -and -not $exited) {
                Stop-Process -Id $entry.Proc.Id -Force -ErrorAction SilentlyContinue
            }

            $isPermanent = $exited -and (Test-PermanentMountFailureLog -LogFile $item.LogFile)
            if ($isPermanent -or $attempt -eq $maxAttempts) {
                $reasonMsg = if ($isPermanent) { "permanent configuration/auth failure" } else { "$why after $maxAttempts attempts" }
                Write-Host "   [FAILED] Failed to mount $($item.DriveLetter) ($reasonMsg). Check log: $($item.LogFile)" -ForegroundColor Red
                Write-OrchestratorLog -Level ERROR -Message "Failed to mount $($item.DriveLetter) ($($item.Config.remote)): $reasonMsg."
                if (Test-Path -LiteralPath $item.LogFile) {
                    try {
                        Write-Host "   Last log lines ($($item.LogFile)):" -ForegroundColor Yellow
                        Get-Content -LiteralPath $item.LogFile -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
                    } catch { $null = $_ }
                }
                $hasFailure = $true
            } else {
                $nextPending += $item
            }
        }

        $pending = $nextPending
    }

    if ($mountedAny) {
        Invoke-ShellRefresh
    }

    return (-not $hasFailure)
}

function Start-DriveMount {
    param ($DriveConfig)
    return (Start-ConfiguredMounts -DriveConfigs @($DriveConfig))
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
        # Match only rclone processes launched with this installation's paths (never '--user-agent' substring).
        $cmd -and ($cmd -match "\bmount\b") -and ($cmd -match $projectRootEsc)
    })

    if (-not $wcmProcs -or $wcmProcs.Count -eq 0) {
        Write-Host "No active WinCloudMount rclone processes detected." -ForegroundColor Yellow
        return
    }

    $stoppedLetters = @()
    $normalizedTarget = if ($TargetDrive) { $TargetDrive.ToUpper().TrimEnd(':') + ":" } else { $null }

    foreach ($p in $wcmProcs) {
        $cmdLine = $p.CommandLine
        $matched = $false
        $driveInCmd = $null

        $targetInfo = Get-MountTargetFromCmdline -CommandLine $cmdLine
        if ($targetInfo) {
            $driveInCmd = $targetInfo.DriveLetter
        }

        if ($normalizedTarget) {
            if ($driveInCmd -eq $normalizedTarget) {
                $matched = $true
            }
        } else {
            $matched = $true
        }

        if ($matched) {
            $targetCacheDir = Get-CacheDirFromCmdline -CommandLine $cmdLine
            if ($targetCacheDir) {
                $vfsStats = Get-VfsCacheStats -CacheDir $targetCacheDir
                if ($vfsStats.DirtyCount -gt 0) {
                    $driveLabel = if ($driveInCmd) { $driveInCmd } else { "PID $($p.ProcessId)" }
                    Write-Warning "Drive $driveLabel has $($vfsStats.DirtyCount) dirty file(s) pending upload in VFS cache. Waiting up to 15s for flush..."
                    Write-OrchestratorLog -Level WARN -Message "Drive $driveLabel has $($vfsStats.DirtyCount) dirty file(s) before stop; waiting up to 15s."

                    $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($waitSw.Elapsed.TotalSeconds -lt 15) {
                        Start-Sleep -Seconds 2
                        $vfsStats = Get-VfsCacheStats -CacheDir $targetCacheDir
                        if ($vfsStats.DirtyCount -eq 0) {
                            Write-Host "   All pending uploads for $driveLabel flushed cleanly." -ForegroundColor Green
                            break
                        }
                    }
                    if ($vfsStats.DirtyCount -gt 0) {
                        Write-Warning "   $($vfsStats.DirtyCount) file(s) still pending; remaining uploads will resume automatically on next mount."
                    }
                }
            }

            Write-Host "Stopping rclone mount PID: $($p.ProcessId) $(if ($driveInCmd) { "[$driveInCmd]" })..." -ForegroundColor Yellow
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-Host "[OK] Stopped mount process $($p.ProcessId)." -ForegroundColor Green
                Write-OrchestratorLog "Stopped mount PID=$($p.ProcessId) $(if ($driveInCmd) { "[$driveInCmd]" })."
                if ($driveInCmd) { $stoppedLetters += $driveInCmd }
            } catch {
                Write-Warning "Could not stop PID $($p.ProcessId): $_"
                Write-OrchestratorLog -Level WARN -Message "Could not stop PID $($p.ProcessId): $_"
            }
        }
    }

    if ($stoppedLetters.Count -gt 0) {
        Clear-StaleNetworkMountPoints -TargetLetters $stoppedLetters
    } elseif (-not $normalizedTarget) {
        Clear-StaleNetworkMountPoints
    }
}

function Show-Status {
    Write-MountHeader "Active Mount Status & Resource Efficiency"

    $projectRootEsc = [regex]::Escape($ProjectRoot)
    $cimProcs = @(Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $cmd = $_.CommandLine
        $cmd -and ($cmd -match "\bmount\b") -and ($cmd -match $projectRootEsc)
    })

    $cmdByPid = @{}
    foreach ($c in $cimProcs) {
        $cmdByPid[[int]$c.ProcessId] = $c.CommandLine
    }

    $procs = @(Get-Process -Name "rclone" -ErrorAction SilentlyContinue | Where-Object { $cmdByPid.ContainsKey([int]$_.Id) })
    $totalDirty = 0

    if (-not $procs -or $procs.Count -eq 0) {
        Write-Host "No active rclone mount processes running." -ForegroundColor Yellow
    } else {
        Write-Host "`nRunning Rclone Processes:" -ForegroundColor White
        $procDetails = foreach ($p in $procs) {
            $cmd = $cmdByPid[[int]$p.Id]
            $mountTarget = "Unknown"
            $targetInfo = Get-MountTargetFromCmdline -CommandLine $cmd
            if ($targetInfo) {
                $mountTarget = "$($targetInfo.Remote) -> $($targetInfo.DriveLetter)"
            }

            $cacheDir = Get-CacheDirFromCmdline -CommandLine $cmd
            $cacheStats = Get-VfsCacheStats -CacheDir $cacheDir
            $totalDirty += $cacheStats.DirtyCount

            [PSCustomObject]@{
                PID            = $p.Id
                Mount          = $mountTarget
                "RAM WS (MB)"  = [math]::Round($p.WorkingSet64 / 1MB, 2)
                "Private (MB)" = [math]::Round($p.PrivateMemorySize64 / 1MB, 2)
                "CPU (s)"      = [math]::Round($p.CPU, 2)
                "Cache (MB)"   = $cacheStats.SizeMB
                Dirty          = $cacheStats.DirtyCount
                StartTime      = $p.StartTime.ToString("HH:mm:ss")
            }
        }
        $procDetails | Format-Table -AutoSize

        if ($totalDirty -gt 0) {
            Write-Warning "$totalDirty file(s) across mounted drives have pending VFS uploads (Dirty)."
        }
    }

    Write-Host "Windows File Explorer Drives:" -ForegroundColor White
    $managedLetters = @(Get-ConfiguredDriveLetters)
    $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object {
        $let = $_.Name.TrimEnd('\', ':').ToUpper()
        $fmtSafe = ""
        try { $fmtSafe = $_.DriveFormat } catch { $null = $_ }
        ($fmtSafe -eq 'FUSE-rclone') -or ($managedLetters -contains $let)
    }

    if ($drives) {
        $driveDetails = foreach ($d in $drives) {
            $freeGB  = $null
            $totalGB = $null
            $usedGB  = $null
            $label   = $d.Name.TrimEnd('\')
            $fmt     = "N/A"
            try {
                if ($d.DriveFormat) { $fmt = $d.DriveFormat }
                if ($d.IsReady) {
                    $freeGB  = [math]::Round($d.TotalFreeSpace / 1GB, 2)
                    $totalGB = [math]::Round($d.TotalSize / 1GB, 2)
                    $usedGB  = [math]::Round($totalGB - $freeGB, 2)
                    $label   = $d.VolumeLabel
                }
            } catch { $null = $_ }

            [PSCustomObject]@{
                Drive        = $d.Name.TrimEnd('\')
                Label        = $label
                Format       = $fmt
                "Used (GB)"  = if ($null -ne $usedGB) { $usedGB } else { "N/A" }
                "Free (GB)"  = if ($null -ne $freeGB) { $freeGB } else { "N/A" }
                "Total (GB)" = if ($null -ne $totalGB) { $totalGB } else { "N/A" }
            }
        }
        $driveDetails | Format-Table -AutoSize
    } else {
        Write-Host "No WinCloudMount cloud drives currently registered." -ForegroundColor Gray
    }
}

function Test-Config {
    Write-MountHeader "Testing Configuration Integrity"
    Write-Host "Checking config path: $ConfigFile" -ForegroundColor White
    $drives = @(Load-DriveConfig)
    Write-Host "Found $($drives.Count) drive configuration(s):" -ForegroundColor Green

    $collectionErrors = @(Get-DriveCollectionErrors -DriveConfigs $drives -ProjectRootPath $ProjectRoot)
    if ($collectionErrors.Count -gt 0) {
        Write-Host "`n[COLLECTION ERROR] Cross-drive conflicts detected:" -ForegroundColor Red
        foreach ($e in $collectionErrors) { Write-Host "  - $e" -ForegroundColor Red }
    }

    foreach ($d in $drives) {
        $backendInfo = Get-RemoteBackendInfo -Remote $d.remote
        $cacheSize   = if (Get-ConfigPropValue $d 'cache_size') { $d.cache_size } else { '20G (default)' }
        $minFree     = if (Get-ConfigPropValue $d 'cache_min_free_space') { $d.cache_min_free_space } else { '10G (default)' }
        $bufSize     = if ($null -ne (Get-ConfigPropValue $d 'buffer_size')) { $d.buffer_size } else { '16M (default)' }
        $readAhead   = if ($null -ne (Get-ConfigPropValue $d 'vfs_read_ahead')) { $d.vfs_read_ahead } else { '128M (default)' }
        $attrTime    = if (Get-ConfigPropValue $d 'attr_timeout') { $d.attr_timeout } else { '1s (default)' }
        $dirCache    = if (Get-ConfigPropValue $d 'dir_cache_time') { $d.dir_cache_time } else { if ($backendInfo.Type -in @('drive','onedrive','dropbox')) { '72h (auto)' } else { '24h (default)' } }
        $maxAge      = if (Get-ConfigPropValue $d 'vfs_cache_max_age') { $d.vfs_cache_max_age } else { '168h (default)' }

        $streamsProp = Get-ConfigPropValue $d 'read_chunk_streams'
        $streamsInfo = if ($null -ne $streamsProp) { "$streamsProp" } elseif ($backendInfo.Type -eq 'drive' -and $backendInfo.Authoritative -and -not $backendInfo.HasCustomClientId) { "0 (shared client_id safeguard)" } else { "4 (auto)" }

        $transfersProp = Get-ConfigPropValue $d 'transfers'
        $transfersInfo = if ($null -ne $transfersProp) { "$transfersProp" } elseif ($backendInfo.Type -eq 'drive' -and $backendInfo.HasCustomClientId) { "6 (auto)" } else { "4 (default)" }

        $uploadDefault = if ($backendInfo.Type -eq 'onedrive') { '50Mi (auto)' } else { '32M (auto)' }
        $uploadChunk   = if (Get-ConfigPropValue $d 'upload_chunk_size') { $d.upload_chunk_size } else { $uploadDefault }

        Write-Host "`n- Name        : $($d.name)" -ForegroundColor Cyan
        Write-Host "  Remote      : $($d.remote) [backend: $($backendInfo.Type)]"
        Write-Host "  Drive Letter: $($d.drive_letter)"
        Write-Host "  Volume Name : $($d.volume_name)"
        if ($backendInfo.Type -eq 'drive') {
            if ($backendInfo.HasCustomClientId) {
                Write-Host "  Client ID   : [CUSTOM] Personal OAuth client configured" -ForegroundColor Green
            } elseif ($backendInfo.Authoritative) {
                Write-Host "  Client ID   : [SHARED - WARNING] Shared rclone client_id (prone to 403 throttling)" -ForegroundColor Yellow
            }
        }
        Write-Host "  Cache Cap   : $cacheSize | Min Free: $minFree | Max Age: $maxAge"
        Write-Host "  Read Tuning : Buffer=$bufSize | ReadAhead=$readAhead | Streams=$streamsInfo"
        Write-Host "  Sync & Attr : UploadChunk=$uploadChunk | Transfers=$transfersInfo | AttrTimeout=$attrTime | DirCache=$dirCache"

        $cfgErrors = @(Get-DriveConfigErrors $d)
        if ($cfgErrors.Count -gt 0) {
            Write-Host "  Config: [INVALID]" -ForegroundColor Red
            foreach ($e in $cfgErrors) { Write-Host "    - $e" -ForegroundColor Red }
        } else {
            Write-Host "  Config: [OK]" -ForegroundColor Green
        }

        $remoteRoot = if ($d.remote -and $d.remote -match '^([^:]+:)') { $Matches[1] } elseif ($d.remote) { "$($d.remote):" } else { '' }
        if ($remoteRoot) {
            $checkRemote = & rclone --ask-password=false listremotes 2>$null | Where-Object { $_ -eq $remoteRoot }
            if ($checkRemote) {
                Write-Host "  Remote Check: [FOUND] '$remoteRoot' configured in rclone.conf" -ForegroundColor Green
            } else {
                Write-Host "  Remote Check: [NOT CONFIGURED] root '$remoteRoot' is not in rclone.conf. Run 'rclone config' to add it." -ForegroundColor Yellow
            }
        }
    }
}

$exitCode = 0
switch ($Action) {
    "start" {
        if (-not (Test-Prerequisites)) { exit 1 }
        Assert-DriveConfigExists
        $orchLock = Enter-OrchestratorLock -TimeoutSeconds 15
        if (-not $orchLock) {
            Write-Warning "Another WinCloudMount orchestration process is already running. Exiting."
            Write-OrchestratorLog -Level WARN -Message "Start skipped: another instance holds the orchestrator lock."
            exit 0
        }
        try {
            Write-MountHeader "Starting Configured Virtual Drives"
            Write-OrchestratorLog "Action 'start' initiated$(if ($DriveLetter) { " for $DriveLetter" })."
            $null = Wait-ForNetworkConnection
            $configs = @(Load-DriveConfig)
            $ok = Start-ConfiguredMounts -DriveConfigs $configs -TargetDriveLetter $DriveLetter
            if (-not $ok) {
                Write-Host "`n[ERROR] One or more drive mount(s) failed. Run '.\Mount-Manager.ps1 -Action status' to inspect." -ForegroundColor Red
                $exitCode = 1
            } else {
                Write-Host "`nAll mounts initiated. Run '.\Mount-Manager.ps1 -Action status' to inspect." -ForegroundColor Green
            }
        } finally {
            Exit-OrchestratorLock -Mutex $orchLock
        }
    }

    "stop" {
        $orchLock = Enter-OrchestratorLock -TimeoutSeconds 15
        if (-not $orchLock) {
            Write-Error "Another WinCloudMount orchestration process is running; unable to acquire lock to stop."
            Write-OrchestratorLog -Level ERROR -Message "Stop failed to acquire orchestrator lock."
            exit 1
        }
        try {
            Write-MountHeader "Stopping Virtual Drives"
            Write-OrchestratorLog "Action 'stop' initiated$(if ($DriveLetter) { " for $DriveLetter" })."
            Stop-DriveMount -TargetDrive $DriveLetter
        } finally {
            Exit-OrchestratorLock -Mutex $orchLock
        }
    }

    "unmount" {
        $orchLock = Enter-OrchestratorLock -TimeoutSeconds 15
        if (-not $orchLock) {
            Write-Error "Another WinCloudMount orchestration process is running; unable to acquire lock to unmount."
            Write-OrchestratorLog -Level ERROR -Message "Unmount failed to acquire orchestrator lock."
            exit 1
        }
        try {
            Write-MountHeader "Unmounting Drive"
            Write-OrchestratorLog "Action 'unmount' initiated$(if ($DriveLetter) { " for $DriveLetter" })."
            Stop-DriveMount -TargetDrive $DriveLetter
        } finally {
            Exit-OrchestratorLock -Mutex $orchLock
        }
    }

    "restart" {
        if (-not (Test-Prerequisites)) { exit 1 }
        Assert-DriveConfigExists
        $orchLock = Enter-OrchestratorLock -TimeoutSeconds 15
        if (-not $orchLock) {
            Write-Error "Another WinCloudMount orchestration process is running; unable to acquire lock to restart."
            Write-OrchestratorLog -Level ERROR -Message "Restart failed to acquire orchestrator lock."
            exit 1
        }
        try {
            Write-MountHeader "Restarting Virtual Drives"
            Write-OrchestratorLog "Action 'restart' initiated$(if ($DriveLetter) { " for $DriveLetter" })."
            Stop-DriveMount -TargetDrive $DriveLetter
            Start-Sleep -Seconds 1
            $null = Wait-ForNetworkConnection
            $configs = @(Load-DriveConfig)
            $ok = Start-ConfiguredMounts -DriveConfigs $configs -TargetDriveLetter $DriveLetter
            if (-not $ok) {
                Write-Host "`n[ERROR] One or more drive mount(s) failed during restart. Run '.\Mount-Manager.ps1 -Action status' to inspect." -ForegroundColor Red
                $exitCode = 1
            } else {
                Write-Host "`nAll mounts restarted. Run '.\Mount-Manager.ps1 -Action status' to inspect." -ForegroundColor Green
            }
        } finally {
            Exit-OrchestratorLock -Mutex $orchLock
        }
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

if ($exitCode -ne 0) {
    exit $exitCode
}
