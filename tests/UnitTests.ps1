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
# Test Group 5: Prerequisites Removal Plan (Marker Matrix)
# ---------------------------------------------------------
Write-Host "`n[Test Group 5] Prerequisites Removal Plan Matrix" -ForegroundColor White

# Load Get-PrerequisiteRemovalPlan function from scripts/Uninstall.ps1 AST
$uninstallScript = Join-Path $repoRoot "scripts\Uninstall.ps1"
$uninstallAst = [System.Management.Automation.Language.Parser]::ParseFile($uninstallScript, [ref]$null, [ref]$null)
$funcAst = $uninstallAst.Find({
    param($ast)
    $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq "Get-PrerequisiteRemovalPlan"
}, $true)

if (-not $funcAst) {
    throw "Get-PrerequisiteRemovalPlan function not found in $uninstallScript"
}
. ([scriptblock]::Create($funcAst.Extent.Text))

$prereqTestDir = Join-Path ([System.IO.Path]::GetTempPath()) "wcm_prereq_test_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $prereqTestDir -Force | Out-Null

try {
    # Matrix Case 1a: No marker file (both tools pre-existing)
    $noMarkerPath = Join-Path $prereqTestDir "nonexistent_marker.json"
    $plan1a = Get-PrerequisiteRemovalPlan -MarkerPath $noMarkerPath
    Assert-Equal -Expected $false -Actual $plan1a.UninstallWinFsp -Message "Matrix 1a: WinFsp retained when marker is missing"
    Assert-Equal -Expected $false -Actual $plan1a.UninstallRclone -Message "Matrix 1a: Rclone retained when marker is missing"
    Assert-Equal -Expected $true -Actual (-not [string]::IsNullOrEmpty($plan1a.WarningMessage)) -Message "Matrix 1a: Explicit warning generated when marker is missing"

    # Matrix Case 1b: Marker exists with empty installed_by_wcm (both tools pre-existing)
    $emptyMarkerPath = Join-Path $prereqTestDir "empty_marker.json"
    @{ installed_by_wcm = @(); installed_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $emptyMarkerPath -Encoding UTF8
    $plan1b = Get-PrerequisiteRemovalPlan -MarkerPath $emptyMarkerPath
    Assert-Equal -Expected $false -Actual $plan1b.UninstallWinFsp -Message "Matrix 1b: WinFsp retained when marker records 0 WCM installs"
    Assert-Equal -Expected $false -Actual $plan1b.UninstallRclone -Message "Matrix 1b: Rclone retained when marker records 0 WCM installs"
    Assert-Equal -Expected $true -Actual (-not [string]::IsNullOrEmpty($plan1b.WarningMessage)) -Message "Matrix 1b: Explicit warning generated when no tools installed by WCM"

    # Matrix Case 2a: Only WinFsp installed by WCM (Rclone pre-existing)
    $winfspMarkerPath = Join-Path $prereqTestDir "winfsp_marker.json"
    @{ installed_by_wcm = @("winfsp"); installed_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $winfspMarkerPath -Encoding UTF8
    $plan2a = Get-PrerequisiteRemovalPlan -MarkerPath $winfspMarkerPath
    Assert-Equal -Expected $true -Actual $plan2a.UninstallWinFsp -Message "Matrix 2a: WinFsp uninstalled when installed by WCM"
    Assert-Equal -Expected $false -Actual $plan2a.UninstallRclone -Message "Matrix 2a: Rclone retained when pre-existing"

    # Matrix Case 2b: Only Rclone installed by WCM (WinFsp pre-existing)
    $rcloneMarkerPath = Join-Path $prereqTestDir "rclone_marker.json"
    @{ installed_by_wcm = @("rclone"); installed_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -LiteralPath $rcloneMarkerPath -Encoding UTF8
    $plan2b = Get-PrerequisiteRemovalPlan -MarkerPath $rcloneMarkerPath
    Assert-Equal -Expected $false -Actual $plan2b.UninstallWinFsp -Message "Matrix 2b: WinFsp retained when pre-existing"
    Assert-Equal -Expected $true -Actual $plan2b.UninstallRclone -Message "Matrix 2b: Rclone uninstalled when installed by WCM"

    # Matrix Case 3: Both installed by WCM
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

# ---------------------------------------------------------
# Summary
# ---------------------------------------------------------
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Test Summary: $passedTests / $totalTests passed" -ForegroundColor $(if ($failedTests -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failedTests -gt 0) {
    throw "$failedTests test(s) failed."
}
