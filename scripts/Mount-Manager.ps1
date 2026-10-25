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
    [ValidateSet("start", "stop", "restart", "status", "test", "unmount")]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [string]$DriveLetter,

    [Parameter()]
    [string]$ConfigFile
)

$ErrorActionPreference = "Continue"

# Resolve directories
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $ProjectRoot "logs"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Resolve Configuration
if (-not $ConfigFile) {
    $ConfigFile = Join-Path $ProjectRoot "config\drives.json"
    if (-not (Test-Path $ConfigFile)) {
        $ExampleConfig = Join-Path $ProjectRoot "config\drives.example.json"
        if (Test-Path $ExampleConfig) {
            Write-Warning "config/drives.json not found. Using config/drives.example.json as template..."
            $ConfigFile = $ExampleConfig
        } else {
            Write-Error "No configuration file found at $ConfigFile. Please create config/drives.json."
            exit 1
        }
    }
}

function Write-MountHeader {
    param ([string]$Title)
    Write-Host "`n=== WinCloudMount: $Title ===" -ForegroundColor Cyan
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

function Start-DriveMount {
    param ($DriveConfig)

    $driveLet = $DriveConfig.drive_letter.ToUpper()
    if (-not $driveLet.EndsWith(":")) { $driveLet = "$driveLet`:" }
    $letterOnly = $driveLet.TrimEnd(':')

    # Check if drive letter is currently taken
    $existing = Get-PSDrive -Name $letterOnly -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "Drive $driveLet is already in use by $($existing.Provider.Name) [$($existing.Description)]. Skipping..."
        return
    }

    # Prepare Cache Directory
    $cacheDir = $DriveConfig.cache_dir
    if (-not $cacheDir) {
        $cacheDir = Join-Path $ProjectRoot "cache\$($DriveConfig.name)"
    }
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    # Defaults for resource-efficient tuning
    $cacheSize      = if ($DriveConfig.cache_size) { $DriveConfig.cache_size } else { "20G" }
    $bufferSize     = if ($DriveConfig.buffer_size) { $DriveConfig.buffer_size } else { "16M" }
    $readChunkSize  = if ($DriveConfig.read_chunk_size) { $DriveConfig.read_chunk_size } else { "16M" }
    $readChunkLimit = if ($DriveConfig.read_chunk_limit) { $DriveConfig.read_chunk_limit } else { "256M" }
    $volName        = if ($DriveConfig.volume_name) { $DriveConfig.volume_name } else { "CloudDrive - $driveLet" }
    $logFile        = Join-Path $LogDir "$($DriveConfig.name)_mount.log"

    $uploadChunk    = if ($DriveConfig.upload_chunk_size) { $DriveConfig.upload_chunk_size } else { "32M" }

    $rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
    $rcloneExe = if ($rcloneCmd) { $rcloneCmd.Source } else { "rclone.exe" }

    $args = @(
        "mount",
        $DriveConfig.remote,
        $driveLet,
        "--volname=`"$volName`"",
        "--vfs-cache-mode=full",
        "--vfs-cache-max-size=$cacheSize",
        "--vfs-cache-max-age=24h",
        "--vfs-cache-poll-interval=1m",
        "--cache-dir=$cacheDir",
        "--buffer-size=$bufferSize",
        "--vfs-read-chunk-size=$readChunkSize",
        "--vfs-read-chunk-size-limit=$readChunkLimit",
        "--drive-chunk-size=$uploadChunk",
        "--vfs-fast-fingerprint",
        "--dir-cache-time=1h",
        "--attr-timeout=1s",
        "--no-modtime",
        "--log-file=$logFile",
        "--log-level=NOTICE"
    )

    if ($DriveConfig.read_only -eq $true) {
        $args += "--read-only"
    }

    Write-Host "-> Launching mount: $($DriveConfig.remote) => $driveLet [$volName]" -ForegroundColor Cyan
    Write-Host "   Cache: $cacheDir (Cap: $cacheSize) | Buffer: $bufferSize" -ForegroundColor Gray

    $proc = Start-Process -FilePath $rcloneExe -ArgumentList $args -WindowStyle Hidden -PassThru

    # Wait briefly and verify mount health
    Start-Sleep -Seconds 3
    $checkDrive = Get-PSDrive -Name $letterOnly -ErrorAction SilentlyContinue
    if ($checkDrive -or (-not $proc.HasExited)) {
        Write-Host "   [SUCCESS] Mounted $driveLet (PID: $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "   [FAILED] Failed to mount $driveLet. Check log: $logFile" -ForegroundColor Red
    }
}

function Stop-DriveMount {
    param ([string]$TargetDrive)

    $procs = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" | Where-Object {
        $_.CommandLine -match "mount"
    }

    if (-not $procs) {
        Write-Host "No active rclone mounts detected." -ForegroundColor Yellow
        return
    }

    foreach ($p in $procs) {
        $cmdLine = $p.CommandLine
        $matched = $false

        if ($TargetDrive) {
            $normalizedTarget = $TargetDrive.ToUpper().TrimEnd(':') + ":"
            if ($cmdLine -match [regex]::Escape($normalizedTarget)) {
                $matched = $true
            }
        } else {
            $matched = $true
        }

        if ($matched) {
            Write-Host "Stopping rclone mount PID: $($p.ProcessId)..." -ForegroundColor Yellow
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-Host "[OK] Stopped mount process $($p.ProcessId)." -ForegroundColor Green
            } catch {
                Write-Warning "Could not stop PID $($p.ProcessId): $_"
            }
        }
    }
}

function Show-Status {
    Write-MountHeader "Active Mount Status & Resource Efficiency"

    $procs = Get-Process -Name "rclone" -ErrorAction SilentlyContinue
    if (-not $procs) {
        Write-Host "No active rclone mount processes running." -ForegroundColor Yellow
    } else {
        Write-Host "`nRunning Rclone Processes:" -ForegroundColor White
        $procDetails = foreach ($p in $procs) {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)"
            $cmd = $cim.CommandLine
            $mountTarget = "Unknown"
            if ($cmd -match "mount\s+(\S+)\s+([A-Za-z]:)") {
                $mountTarget = "$($Matches[1]) -> $($Matches[2])"
            }

            [PSCustomObject]@{
                PID       = $p.Id
                Mount     = $mountTarget
                "RAM (MB)"= [math]::Round($p.WorkingSet64 / 1MB, 2)
                "CPU (s)" = [math]::Round($p.CPU, 2)
                StartTime = $p.StartTime.ToString("HH:mm:ss")
            }
        }
        $procDetails | Format-Table -AutoSize
    }

    Write-Host "Windows File Explorer Drives:" -ForegroundColor White
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.DisplayRoot -or $_.Name -notin @('C','D') }
    if ($drives) {
        $driveDetails = foreach ($d in $drives) {
            $usedGB = if ($d.Used) { [math]::Round($d.Used / 1GB, 2) } else { 0 }
            $freeGB = if ($d.Free) { [math]::Round($d.Free / 1GB, 2) } else { 0 }
            $totalGB = [math]::Round($usedGB + $freeGB, 2)

            [PSCustomObject]@{
                Drive = "$($d.Name):"
                Root  = $d.Root
                "Used (GB)"  = $usedGB
                "Free (GB)"  = $freeGB
                "Total (GB)" = $totalGB
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

        # Check if remote exists in rclone config
        $checkRemote = & rclone listremotes 2>$null | Where-Object { $_ -eq $d.remote }
        if ($checkRemote) {
            Write-Host "  Remote Check: [FOUND] Configured in rclone.conf" -ForegroundColor Green
        } else {
            Write-Host "  Remote Check: [NOT CONFIGURED] Run 'rclone config' to add this remote!" -ForegroundColor Yellow
        }
    }
}

# --- Execution Router ---
if (-not (Test-Prerequisites)) {
    exit 1
}

switch ($Action) {
    "start" {
        Write-MountHeader "Starting Configured Virtual Drives"
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
        Write-MountHeader "Restarting Virtual Drives"
        Stop-DriveMount -TargetDrive $DriveLetter
        Start-Sleep -Seconds 1
        & $MyInvocation.MyCommand.Path -Action start -DriveLetter $DriveLetter -ConfigFile $ConfigFile
    }

    "status" {
        Show-Status
    }

    "test" {
        Test-Config
    }
}
