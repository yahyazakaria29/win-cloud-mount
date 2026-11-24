# UnitTests.ps1 - Automated Unit Tests for WinCloudMount
# Validates helpers, argument builders, token-aware parsers, config validation, and safety checks.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

$mountManagerPath = Join-Path $repoRoot "scripts\Mount-Manager.ps1"
if (-not (Test-Path $mountManagerPath)) {
    throw "Mount-Manager.ps1 not found at $mountManagerPath"
}

. $mountManagerPath -Action "version" | Out-Null

$totalTests = 0
$passedTests = 0
$failedTests = 0

function Assert-Equal {
    param ($Expected, $Actual, [string]$Message)
    $script:totalTests++
    if ($Expected -eq $Actual) {
        $script:passedTests++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:failedTests++
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        Write-Host "         Expected: '$Expected'" -ForegroundColor Yellow
        Write-Host "         Actual:   '$Actual'" -ForegroundColor Yellow
    }
}

function Assert-Throws {
    param ([scriptblock]$Script, [string]$Message)
    $script:totalTests++
    $threw = $false
    try {
        & $Script
    } catch {
        $threw = $true
    }
    if ($threw) {
        $script:passedTests++
        Write-Host "  [PASS] $Message (Threw as expected)" -ForegroundColor Green
    } else {
        $script:failedTests++
        Write-Host "  [FAIL] $Message (Did NOT throw)" -ForegroundColor Red
    }
}

function Assert-FlagValue {
    param ([string[]]$ArgList, [string]$Flag, [string]$ExpectedValue, [string]$Message)
    $script:totalTests++
    $idx = [Array]::IndexOf($ArgList, $Flag)
    if ($idx -ge 0 -and ($idx + 1) -lt $ArgList.Count -and $ArgList[$idx + 1] -eq $ExpectedValue) {
        $script:passedTests++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $actualVal = if ($idx -ge 0 -and ($idx + 1) -lt $ArgList.Count) { $ArgList[$idx + 1] } else { "<missing flag>" }
        $script:failedTests++
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        Write-Host "         Expected: '$Flag $ExpectedValue'" -ForegroundColor Yellow
        Write-Host "         Actual:   '$Flag $actualVal'" -ForegroundColor Yellow
    }
}

function Assert-Contains {
    param ([string[]]$Collection, [string]$Item, [bool]$ShouldContain, [string]$Message)
    $script:totalTests++
    $has = ($Collection -contains $Item)
    if ($has -eq $ShouldContain) {
        $script:passedTests++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:failedTests++
        Write-Host "  [FAIL] $Message (Expected contains=$ShouldContain, Actual=$has)" -ForegroundColor Red
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running WinCloudMount Unit Tests (v$AppVersion)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------
# Test Group 1: ConvertTo-RcloneArg
# ---------------------------------------------------------
Write-Host "`n[Test Group 1] ConvertTo-RcloneArg helper" -ForegroundColor White

Assert-Equal -Expected '"mount"' -Actual (ConvertTo-RcloneArg "mount") -Message "String is safely quoted"
Assert-Equal -Expected '"gdrive personal:"' -Actual (ConvertTo-RcloneArg "gdrive personal:") -Message "Remote with space is quoted"
Assert-Equal -Expected '"CloudDrive - E:"' -Actual (ConvertTo-RcloneArg "CloudDrive - E:") -Message "Volume name with spaces and dash is quoted"
Assert-Equal -Expected '"D:\CloudCache\\"' -Actual (ConvertTo-RcloneArg 'D:\CloudCache\') -Message "Trailing backslash is doubled before closing quote"
Assert-Equal -Expected '"D:\CloudCache\\\\"' -Actual (ConvertTo-RcloneArg 'D:\CloudCache\\') -Message "Two trailing backslashes are quadrupled before closing quote"
Assert-Equal -Expected '"D:\CloudCache"' -Actual (ConvertTo-RcloneArg 'D:\CloudCache') -Message "Path is cleanly double-quoted"
Assert-Equal -Expected '""' -Actual (ConvertTo-RcloneArg "") -Message "Empty string returns empty double quotes"

Assert-Throws -Script { ConvertTo-RcloneArg 'remote"name:' } -Message "Double-quote literal is rejected"
Assert-Throws -Script { ConvertTo-RcloneArg "remote`nname:" } -Message "Newline control character is rejected"
Assert-Throws -Script { ConvertTo-RcloneArg "remote`tname:" } -Message "Tab control character is rejected"

# ---------------------------------------------------------
# Test Group 2: Get-MountTargetFromCmdline & Get-CacheDirFromCmdline
# ---------------------------------------------------------
Write-Host "`n[Test Group 2] Token-Aware Command-Line Parsers" -ForegroundColor White

$cmd1 = 'rclone.exe mount "gdrive_personal:" E: --volname "CloudDrive - E:"'
$res1 = Get-MountTargetFromCmdline -CommandLine $cmd1
Assert-Equal -Expected "gdrive_personal:" -Actual $res1.Remote -Message "Standard remote parsed correctly"
Assert-Equal -Expected "E:" -Actual $res1.DriveLetter -Message "Standard drive letter parsed correctly"

$cmd2 = 'rclone.exe mount "kampus it:" K: --volname "CloudDrive - K:"'
$res2 = Get-MountTargetFromCmdline -CommandLine $cmd2
Assert-Equal -Expected "kampus it:" -Actual $res2.Remote -Message "Spaced remote parsed correctly"
Assert-Equal -Expected "K:" -Actual $res2.DriveLetter -Message "Drive letter with spaced remote parsed correctly"

$cmd3 = 'rclone mount gdrive: G: --vfs-cache-mode full'
$res3 = Get-MountTargetFromCmdline -CommandLine $cmd3
Assert-Equal -Expected "gdrive:" -Actual $res3.Remote -Message "Unquoted remote parsed correctly"
Assert-Equal -Expected "G:" -Actual $res3.DriveLetter -Message "Unquoted drive letter parsed correctly"

$cmd4 = 'rclone mount "onedrive personal:Documents/Work" O: --volname "OneDrive"'
$res4 = Get-MountTargetFromCmdline -CommandLine $cmd4
Assert-Equal -Expected "onedrive personal:Documents/Work" -Actual $res4.Remote -Message "Spaced remote with subpath parsed correctly"
Assert-Equal -Expected "O:" -Actual $res4.DriveLetter -Message "Drive letter with spaced subpath remote parsed correctly"

$cmd5 = 'rclone lsd "gdrive_personal:"'
$res5 = Get-MountTargetFromCmdline -CommandLine $cmd5
Assert-Equal -Expected $null -Actual $res5 -Message "Non-mount rclone command returns null"

$cacheCmd1 = 'rclone.exe mount "gdrive_1:" "E:" --cache-dir "C:\Users\Yahya Zakaria\.cache\gdrive 1" --buffer-size 16M'
Assert-Equal -Expected 'C:\Users\Yahya Zakaria\.cache\gdrive 1' -Actual (Get-CacheDirFromCmdline -CommandLine $cacheCmd1) -Message "Quoted --cache-dir with spaces parsed accurately"

$cacheCmd2 = 'rclone.exe mount gdrive: E: --cache-dir D:\Cache\g1 --log-file "D:\Logs\g1.log"'
Assert-Equal -Expected 'D:\Cache\g1' -Actual (Get-CacheDirFromCmdline -CommandLine $cacheCmd2) -Message "Unquoted --cache-dir stops before subsequent quoted flags"

Assert-Equal -Expected $null -Actual (Get-CacheDirFromCmdline -CommandLine $cmd1) -Message "Missing --cache-dir flag returns null"

# ---------------------------------------------------------
# Test Group 3: Get-DriveConfigErrors & Get-DriveCollectionErrors
# ---------------------------------------------------------
Write-Host "`n[Test Group 3] Single-Drive & Cross-Drive Validation" -ForegroundColor White

$validCfg = [PSCustomObject]@{
    name               = "work_drive"
    remote             = "work_remote:"
    drive_letter       = "W:"
    volume_name        = "Work Drive"
    cache_dir          = "D:\CloudCache\work"
    cache_size         = "20G"
    buffer_size        = "0"
    vfs_read_ahead     = "128M"
    upload_chunk_size  = "50Mi"
    attr_timeout       = "1s"
    dir_cache_time     = "72h"
    vfs_cache_max_age  = "168h"
    read_chunk_streams = 4
    transfers          = 6
    log_level          = "NOTICE"
}
Assert-Equal -Expected 0 -Actual @(Get-DriveConfigErrors $validCfg).Count -Message "Valid v1.2.0 config yields 0 errors"

$trailingSlashCfg = [PSCustomObject]@{
    name         = "work_drive"
    remote       = "work_remote:"
    drive_letter = "W:"
    volume_name  = "Work Drive"
    cache_dir    = "D:\CloudCache\work\"
}
Assert-Equal -Expected 1 -Actual @(Get-DriveConfigErrors $trailingSlashCfg).Count -Message "Trailing backslash in cache_dir triggers validation error"

$quoteCfg = [PSCustomObject]@{
    name         = "work_drive"
    remote       = 'work_"remote:'
    drive_letter = "W:"
    volume_name  = "Work Drive"
}
Assert-Equal -Expected 1 -Actual @(Get-DriveConfigErrors $quoteCfg).Count -Message "Double-quote in remote triggers validation error"

$missingCfg = [PSCustomObject]@{
    name = "incomplete"
}
Assert-Equal -Expected 3 -Actual @(Get-DriveConfigErrors $missingCfg).Count -Message "Missing required remote, drive_letter, and volume_name trigger 3 errors"

$missingNameCfg = [PSCustomObject]@{
    remote       = "work_remote:"
    drive_letter = "W:"
    volume_name  = "Work Drive"
}
Assert-Equal -Expected 1 -Actual @(Get-DriveConfigErrors $missingNameCfg).Count -Message "Missing required name triggers validation error"

$traversalNameCfg = [PSCustomObject]@{
    name         = "..\evil"
    remote       = "work_remote:"
    drive_letter = "W:"
    volume_name  = "Work Drive"
}
Assert-Equal -Expected 1 -Actual @(Get-DriveConfigErrors $traversalNameCfg).Count -Message "Path traversal in name triggers validation error"

$invalidTuningCfg = [PSCustomObject]@{
    name               = "bad_tuning"
    remote             = "work_remote:"
    drive_letter       = "W:"
    volume_name        = "Bad Tuning"
    cache_size         = "0G"
    attr_timeout       = "abc"
    read_chunk_streams = 99
    transfers          = 0
    log_level          = "VERBOSE"
}
Assert-Equal -Expected 5 -Actual @(Get-DriveConfigErrors $invalidTuningCfg).Count -Message "Invalid size, duration, stream count, transfers, and log_level trigger 5 errors"

$multiValid = @(
    [PSCustomObject]@{ name = "d1"; remote = "r1:"; drive_letter = "E:"; volume_name = "D1"; cache_dir = ".cache/d1" },
    [PSCustomObject]@{ name = "d2"; remote = "r2:"; drive_letter = "F:"; volume_name = "D2"; cache_dir = ".cache/d2" }
)
Assert-Equal -Expected 0 -Actual @(Get-DriveCollectionErrors -DriveConfigs $multiValid -ProjectRootPath $repoRoot).Count -Message "Distinct drives yield 0 collection errors"

$multiDup = @(
    [PSCustomObject]@{ name = "DriveA"; remote = "r1:"; drive_letter = "e:"; volume_name = "D1"; cache_dir = ".cache/shared" },
    [PSCustomObject]@{ name = "drivea"; remote = "r2:"; drive_letter = "E:"; volume_name = "D2"; cache_dir = ".cache\shared" }
)
Assert-Equal -Expected 3 -Actual @(Get-DriveCollectionErrors -DriveConfigs $multiDup -ProjectRootPath $repoRoot).Count -Message "Duplicate drive_letter, name, and cache_dir trigger 3 collection errors"

# ---------------------------------------------------------
# Test Group 4: Invoke-LogRotation (Real Function)
# ---------------------------------------------------------
Write-Host "`n[Test Group 4] Invoke-LogRotation (Real Function)" -ForegroundColor White

$testTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "wcm_unit_test_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testTempDir -Force | Out-Null

try {
    $dummyLog = Join-Path $testTempDir "test_mount.log"
    [System.IO.File]::WriteAllText($dummyLog, "small log line`n")
    $rotSmall = Invoke-LogRotation -LogPath $dummyLog -MaxBytes 5MB
    Assert-Equal -Expected $false -Actual $rotSmall -Message "Log under 5 MB is not rotated"
    Assert-Equal -Expected $true -Actual (Test-Path $dummyLog) -Message "Small log stays in place"

    $dummyBytes = New-Object byte[] (6 * 1024 * 1024)
    [System.IO.File]::WriteAllBytes($dummyLog, $dummyBytes)
    $rotLarge = Invoke-LogRotation -LogPath $dummyLog -MaxBytes 5MB
    Assert-Equal -Expected $true -Actual $rotLarge -Message "Log over 5 MB returns true when rotated"
    Assert-Equal -Expected $false -Actual (Test-Path $dummyLog) -Message "Original log moved away after rotation"
    Assert-Equal -Expected $true -Actual (Test-Path "$dummyLog.1") -Message "Archived log .1 created"

    [System.IO.File]::WriteAllBytes($dummyLog, $dummyBytes)
    $rotOverwrite = Invoke-LogRotation -LogPath $dummyLog -MaxBytes 5MB
    Assert-Equal -Expected $true -Actual $rotOverwrite -Message "Second rotation replaces existing .1 cleanly"
    Assert-Equal -Expected $true -Actual (Test-Path "$dummyLog.1") -Message "Archived log .1 remains present"
} finally {
    if (Test-Path $testTempDir) {
        Remove-Item -Path $testTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------
# Test Group 5: Resolve-DriveIcon
# ---------------------------------------------------------
Write-Host "`n[Test Group 5] Resolve-DriveIcon Smart Matching" -ForegroundColor White

$iconDropbox = Resolve-DriveIcon -RemoteName "my_dropbox:" -VolumeLabel "Dropbox" -ConfigName "dbx"
Assert-Equal -Expected "dropbox.ico" -Actual (Split-Path -Leaf $iconDropbox) -Message "Dropbox resolves to dropbox.ico (not box.ico)"

$iconLab2 = Resolve-DriveIcon -RemoteName "lab2_nas:" -VolumeLabel "Lab 2" -ConfigName "lab2"
Assert-Equal -Expected "googledrive.ico" -Actual (Split-Path -Leaf $iconLab2) -Message "lab2_nas does not false-match b2/s3.ico"

$iconS3 = Resolve-DriveIcon -RemoteName "s3_backup:" -VolumeLabel "Backup" -ConfigName "s3"
Assert-Equal -Expected "s3.ico" -Actual (Split-Path -Leaf $iconS3) -Message "s3_backup resolves to s3.ico"

$iconOneDrive = Resolve-DriveIcon -RemoteName "onedrive_work:" -VolumeLabel "OneDrive" -ConfigName "od"
Assert-Equal -Expected "onedrive.ico" -Actual (Split-Path -Leaf $iconOneDrive) -Message "onedrive_work resolves to onedrive.ico"

# ---------------------------------------------------------
# Test Group 6: Build-RcloneMountArgs (Backend & VFS Tuning)
# ---------------------------------------------------------
Write-Host "`n[Test Group 6] Build-RcloneMountArgs" -ForegroundColor White

$gdCfg = [PSCustomObject]@{ name = "gd1"; remote = "gdrive_1:"; drive_letter = "E:"; volume_name = "Google Drive 1" }
$gdCustomInfo = [PSCustomObject]@{ RootName = "gdrive_1"; Type = "drive"; HasCustomClientId = $true; Authoritative = $true }
$gdCustomArgs = @(Build-RcloneMountArgs -DriveConfig $gdCfg -DriveLetter "E:" -VolumeName "Google Drive 1" -SafeCacheDir "C:\Cache\gd1" -LogFile "C:\Logs\gd1.log" -BackendInfo $gdCustomInfo -Version "1.2.0")

Assert-FlagValue -ArgList $gdCustomArgs -Flag "--attr-timeout" -ExpectedValue "1s" -Message "Google Drive custom uses --attr-timeout 1s"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--dir-cache-time" -ExpectedValue "72h" -Message "Google Drive custom uses --dir-cache-time 72h"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--vfs-cache-max-age" -ExpectedValue "168h" -Message "Google Drive custom uses --vfs-cache-max-age 168h"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--vfs-read-ahead" -ExpectedValue "128M" -Message "Google Drive custom uses --vfs-read-ahead 128M"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--vfs-read-chunk-streams" -ExpectedValue "4" -Message "Google Drive custom uses --vfs-read-chunk-streams 4"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--drive-chunk-size" -ExpectedValue "32M" -Message "Google Drive custom uses --drive-chunk-size 32M"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--drive-pacer-min-sleep" -ExpectedValue "10ms" -Message "Google Drive custom enables 10ms pacer min sleep"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--drive-pacer-burst" -ExpectedValue "200" -Message "Google Drive custom enables 200 pacer burst"
Assert-FlagValue -ArgList $gdCustomArgs -Flag "--transfers" -ExpectedValue "6" -Message "Google Drive custom defaults to 6 transfers"
Assert-Contains -Collection $gdCustomArgs -Item "--no-modtime" -ShouldContain $false -Message "Google Drive does not enable --no-modtime by default"
Assert-Contains -Collection $gdCustomArgs -Item "--vfs-read-chunk-size-limit" -ShouldContain $false -Message "Parallel streams mode omits --vfs-read-chunk-size-limit"

$gdSharedInfo = [PSCustomObject]@{ RootName = "gdrive_1"; Type = "drive"; HasCustomClientId = $false; Authoritative = $true }
$gdSharedArgs = @(Build-RcloneMountArgs -DriveConfig $gdCfg -DriveLetter "E:" -VolumeName "Google Drive 1" -SafeCacheDir "C:\Cache\gd1" -LogFile "C:\Logs\gd1.log" -BackendInfo $gdSharedInfo -Version "1.2.0")
Assert-Contains -Collection $gdSharedArgs -Item "--drive-pacer-min-sleep" -ShouldContain $false -Message "Shared Google client_id omits aggressive pacer min sleep"
Assert-Contains -Collection $gdSharedArgs -Item "--drive-pacer-burst" -ShouldContain $false -Message "Shared Google client_id omits aggressive pacer burst"
Assert-FlagValue -ArgList $gdSharedArgs -Flag "--vfs-read-chunk-size-limit" -ExpectedValue "256M" -Message "Shared Google client_id falls back to progressive chunk limit"
Assert-Contains -Collection $gdSharedArgs -Item "--vfs-read-chunk-streams" -ShouldContain $false -Message "Shared Google client_id omits parallel chunk streams"
Assert-FlagValue -ArgList $gdSharedArgs -Flag "--transfers" -ExpectedValue "4" -Message "Shared Google client_id keeps 4 transfers"

$odCfg = [PSCustomObject]@{ name = "od1"; remote = "onedrive_personal:"; drive_letter = "O:"; volume_name = "OneDrive" }
$odInfo = [PSCustomObject]@{ RootName = "onedrive_personal"; Type = "onedrive"; HasCustomClientId = $false; Authoritative = $true }
$odArgs = @(Build-RcloneMountArgs -DriveConfig $odCfg -DriveLetter "O:" -VolumeName "OneDrive" -SafeCacheDir "C:\Cache\od1" -LogFile "C:\Logs\od1.log" -BackendInfo $odInfo -Version "1.2.0")
Assert-FlagValue -ArgList $odArgs -Flag "--onedrive-chunk-size" -ExpectedValue "50Mi" -Message "OneDrive defaults to --onedrive-chunk-size 50Mi"
Assert-Contains -Collection $odArgs -Item "--no-modtime" -ShouldContain $false -Message "OneDrive preserves modification times"
Assert-Contains -Collection $odArgs -Item "--drive-chunk-size" -ShouldContain $false -Message "OneDrive omits Google Drive flags"

$s3Cfg = [PSCustomObject]@{ name = "s3b"; remote = "s3_backup:"; drive_letter = "S:"; volume_name = "S3 Backup" }
$s3Info = [PSCustomObject]@{ RootName = "s3_backup"; Type = "s3"; HasCustomClientId = $false; Authoritative = $true }
$s3Args = @(Build-RcloneMountArgs -DriveConfig $s3Cfg -DriveLetter "S:" -VolumeName "S3 Backup" -SafeCacheDir "C:\Cache\s3b" -LogFile "C:\Logs\s3b.log" -BackendInfo $s3Info -Version "1.2.0")
Assert-Contains -Collection $s3Args -Item "--no-modtime" -ShouldContain $true -Message "S3 enables --no-modtime by default"
Assert-FlagValue -ArgList $s3Args -Flag "--dir-cache-time" -ExpectedValue "24h" -Message "S3 defaults to 24h dir-cache-time"

# ---------------------------------------------------------
# Test Group 7: Prerequisites Removal Plan & Unsafe Purge Guards
# ---------------------------------------------------------
Write-Host "`n[Test Group 7] Uninstall Safety Helpers (Marker Matrix & Purge Guard)" -ForegroundColor White

$uninstallScript = Join-Path $repoRoot "scripts\Uninstall.ps1"
$uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($uninstallScript, [ref]$null, [ref]$null)

foreach ($fnName in @("Get-PrerequisiteRemovalPlan", "Test-UnsafePurgePath")) {
    $funcAst = $uninstallAst.Find({
        param($ast)
        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $fnName
    }, $true)

    if (-not $funcAst) {
        throw "$fnName function not found in $uninstallScript"
    }
    . ([scriptblock]::Create($funcAst.Extent.Text))
}

$prereqTestDir = Join-Path ([System.IO.Path]::GetTempPath()) "wcm_prereq_test_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $prereqTestDir -Force | Out-Null

try {
    $noMarkerPath = Join-Path $prereqTestDir "nonexistent_marker.json"
    $plan1a = Get-PrerequisiteRemovalPlan -MarkerPath $noMarkerPath
    Assert-Equal -Expected $false -Actual $plan1a.UninstallWinFsp -Message "Matrix 1a: WinFsp retained when marker is missing"
    Assert-Equal -Expected $false -Actual $plan1a.UninstallRclone -Message "Matrix 1a: Rclone retained when marker is missing"
    Assert-Equal -Expected $true -Actual (-not [string]::IsNullOrEmpty($plan1a.WarningMessage)) -Message "Matrix 1a: Explicit warning generated when marker is missing"

    $emptyMarkerPath = Join-Path $prereqTestDir "empty_marker.json"
    @{ installed_by_wcm = @(); installed_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $emptyMarkerPath -Encoding UTF8
    $plan1b = Get-PrerequisiteRemovalPlan -MarkerPath $emptyMarkerPath
    Assert-Equal -Expected $false -Actual $plan1b.UninstallWinFsp -Message "Matrix 1b: WinFsp retained when marker records 0 WCM installs"
    Assert-Equal -Expected $false -Actual $plan1b.UninstallRclone -Message "Matrix 1b: Rclone retained when marker records 0 WCM installs"
    Assert-Equal -Expected $true -Actual (-not [string]::IsNullOrEmpty($plan1b.WarningMessage)) -Message "Matrix 1b: Explicit warning generated when no tools installed by WCM"

    $winfspMarkerPath = Join-Path $prereqTestDir "winfsp_marker.json"
    @{ installed_by_wcm = @("winfsp"); installed_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $winfspMarkerPath -Encoding UTF8
    $plan2a = Get-PrerequisiteRemovalPlan -MarkerPath $winfspMarkerPath
    Assert-Equal -Expected $true -Actual $plan2a.UninstallWinFsp -Message "Matrix 2a: WinFsp uninstalled when installed by WCM"
    Assert-Equal -Expected $false -Actual $plan2a.UninstallRclone -Message "Matrix 2a: Rclone retained when pre-existing"

    $rcloneMarkerPath = Join-Path $prereqTestDir "rclone_marker.json"
    @{ installed_by_wcm = @("rclone"); installed_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $rcloneMarkerPath -Encoding UTF8
    $plan2b = Get-PrerequisiteRemovalPlan -MarkerPath $rcloneMarkerPath
    Assert-Equal -Expected $false -Actual $plan2b.UninstallWinFsp -Message "Matrix 2b: WinFsp retained when pre-existing"
    Assert-Equal -Expected $true -Actual $plan2b.UninstallRclone -Message "Matrix 2b: Rclone uninstalled when installed by WCM"

    $bothMarkerPath = Join-Path $prereqTestDir "both_marker.json"
    @{ installed_by_wcm = @("winfsp", "rclone"); installed_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $bothMarkerPath -Encoding UTF8
    $plan3 = Get-PrerequisiteRemovalPlan -MarkerPath $bothMarkerPath
    Assert-Equal -Expected $true -Actual $plan3.UninstallWinFsp -Message "Matrix 3: WinFsp uninstalled when both installed by WCM"
    Assert-Equal -Expected $true -Actual $plan3.UninstallRclone -Message "Matrix 3: Rclone uninstalled when both installed by WCM"
    Assert-Equal -Expected $null -Actual $plan3.WarningMessage -Message "Matrix 3: No warning when all recorded tools are scheduled for removal"
} finally {
    if (Test-Path $prereqTestDir) {
        Remove-Item -Path $prereqTestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-Equal -Expected $true -Actual (Test-UnsafePurgePath "C:\") -Message "Root drive C:\ blocked from cache purge"
Assert-Equal -Expected $true -Actual (Test-UnsafePurgePath $env:SystemRoot) -Message "Windows system directory blocked from cache purge"
Assert-Equal -Expected $true -Actual (Test-UnsafePurgePath $env:USERPROFILE) -Message "User profile root blocked from cache purge"
Assert-Equal -Expected $true -Actual (Test-UnsafePurgePath (Join-Path $env:USERPROFILE "Documents")) -Message "User Documents folder blocked from cache purge"
Assert-Equal -Expected $true -Actual (Test-UnsafePurgePath "") -Message "Empty path blocked from cache purge"
Assert-Equal -Expected $false -Actual (Test-UnsafePurgePath (Join-Path $env:LOCALAPPDATA "WinCloudMount\.cache\gdrive_1")) -Message "Valid subfolder cache path allowed for purge"

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Test Summary: $passedTests / $totalTests passed" -ForegroundColor $(if ($failedTests -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failedTests -gt 0) {
    throw "$failedTests test(s) failed."
}
