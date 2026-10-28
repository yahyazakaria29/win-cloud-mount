# UnitTests.ps1 - Automated Unit Tests for WinCloudMount
# Validates core helper functions, argument conversion, token-aware regex parsing, and config validation.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir

# Dot-source Mount-Manager.ps1 functions by dot-sourcing with a non-matching Action so it doesn't trigger execution router
$mountManagerPath = Join-Path $repoRoot "scripts\Mount-Manager.ps1"
if (-not (Test-Path $mountManagerPath)) {
    throw "Mount-Manager.ps1 not found at $mountManagerPath"
}

# Source functions from Mount-Manager.ps1 safely using -Action version
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
# Test Group 2: Get-MountTargetFromCmdline
# ---------------------------------------------------------
Write-Host "`n[Test Group 2] Get-MountTargetFromCmdline (Token-Aware Parser)" -ForegroundColor White

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

# ---------------------------------------------------------
# Test Group 3: Get-DriveConfigErrors (Validation)
# ---------------------------------------------------------
Write-Host "`n[Test Group 3] Get-DriveConfigErrors" -ForegroundColor White

$validCfg = [PSCustomObject]@{
    name         = "work_drive"
    remote       = "work_remote:"
    drive_letter = "W:"
    volume_name  = "Work Drive"
    cache_dir    = "D:\CloudCache\work"
}
$errorsValid = @(Get-DriveConfigErrors $validCfg)
Assert-Equal -Expected 0 -Actual $errorsValid.Count -Message "Valid config yields 0 errors"

$trailingSlashCfg = [PSCustomObject]@{
    name         = "work_drive"
    remote       = "work_remote:"
    drive_letter = "W:"
    volume_name  = "Work Drive"
    cache_dir    = "D:\CloudCache\work\"
}
$errorsSlash = @(Get-DriveConfigErrors $trailingSlashCfg)
Assert-Equal -Expected 1 -Actual $errorsSlash.Count -Message "Trailing backslash in cache_dir triggers validation error"

$quoteCfg = [PSCustomObject]@{
    name         = "work_drive"
    remote       = 'work_"remote:'
    drive_letter = "W:"
    volume_name  = "Work Drive"
}
$errorsQuote = @(Get-DriveConfigErrors $quoteCfg)
Assert-Equal -Expected 1 -Actual $errorsQuote.Count -Message "Double-quote in remote triggers validation error"

$missingCfg = [PSCustomObject]@{
    name = "incomplete"
}
$errorsMissing = @(Get-DriveConfigErrors $missingCfg)
Assert-Equal -Expected 3 -Actual $errorsMissing.Count -Message "Missing required remote, drive_letter, and volume_name trigger validation errors"

# ---------------------------------------------------------
# Test Group 4: Log Rotation Logic
# ---------------------------------------------------------
Write-Host "`n[Test Group 4] Log Rotation Simulation" -ForegroundColor White

$testTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "wcm_unit_test_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testTempDir -Force | Out-Null

try {
    $dummyLog = Join-Path $testTempDir "test_mount.log"
    # Create 6 MB dummy log file
    $dummyBytes = New-Object byte[] (6 * 1024 * 1024)
    [System.IO.File]::WriteAllBytes($dummyLog, $dummyBytes)

    Assert-Equal -Expected $true -Actual (Test-Path $dummyLog) -Message "Created 6 MB test log file"

    # Simulate rotation block
    if (Test-Path -LiteralPath $dummyLog) {
        $logItem = Get-Item -LiteralPath $dummyLog -ErrorAction SilentlyContinue
        if ($logItem -and $logItem.Length -gt 5MB) {
            $oldLog = "$dummyLog.1"
            if (Test-Path -LiteralPath $oldLog) {
                Remove-Item -LiteralPath $oldLog -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $dummyLog -Destination $oldLog -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-Equal -Expected $false -Actual (Test-Path $dummyLog) -Message "Original log moved away"
    Assert-Equal -Expected $true -Actual (Test-Path "$dummyLog.1") -Message "Archived log .1 created"
} finally {
    if (Test-Path $testTempDir) {
        Remove-Item -Path $testTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Test Summary: $passedTests / $totalTests passed" -ForegroundColor $(if ($failedTests -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failedTests -gt 0) {
    throw "$failedTests test(s) failed."
}
