<#
.SYNOPSIS
    Automated prerequisites installer for WinCloudMount (WinFsp & Rclone).

.DESCRIPTION
    Checks system requirements and installs the required components:
    1. WinFsp (Windows File System Proxy) - kernel filesystem bridge.
    2. Rclone - multi-cloud storage engine.
    Uses Windows Package Manager (winget) for clean, silent, verified installations.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install-Prerequisites.ps1
#>

[CmdletBinding()]
param (
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param ([string]$Message)
    Write-Host "`n[STEP] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param ([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param ([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Yellow
}

function Write-Failure {
    param ([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# winget returns 0x8A15002B (-1978335189) when the package is already installed and no
# upgrade is applicable. Treat that as success; any other non-zero exit code is a failure.
$AlreadyInstalledExitCode = -1978335189

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       WinCloudMount - Prerequisites Installer            " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Check Winget availability
Write-Step "Checking Windows Package Manager (winget)..."
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetCmd) {
    Write-Failure "winget is not found on this system. Please install 'App Installer' from Microsoft Store."
    exit 1
}
Write-Success "winget found: $($wingetCmd.Source)"

# Track prerequisites installation state via .prerequisites.json marker
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$MarkerPath  = Join-Path $ProjectRoot ".prerequisites.json"
$installedByWcm = @()

if (Test-Path -LiteralPath $MarkerPath) {
    try {
        $existingMarker = Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($existingMarker -and $existingMarker.installed_by_wcm) {
            $installedByWcm = @($existingMarker.installed_by_wcm)
        }
    } catch { $null = $_ }
}

# 2. Check and Install WinFsp
Write-Step "Checking WinFsp (Windows File System Proxy)..."
$winfspPaths = @(
    "$env:ProgramFiles\WinFsp",
    "${env:ProgramFiles(x86)}\WinFsp"
)
$winfspInstalled = @($winfspPaths | Where-Object { Test-Path $_ })

if ($winfspInstalled -and (-not $Force)) {
    Write-Success "WinFsp is already installed at: $($winfspInstalled[0])"
} else {
    Write-Info "Installing WinFsp via winget..."
    try {
        winget install --id WinFsp.WinFsp --exact --silent --accept-package-agreements --accept-source-agreements
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $exitCode -ne $AlreadyInstalledExitCode) {
            Write-Failure ("WinFsp installation failed (winget exit code 0x{0:X8})." -f [uint32]$exitCode)
            exit 1
        }
        if (-not $winfspInstalled -and $exitCode -eq 0) {
            $installedByWcm += "winfsp"
        }
        Write-Success "WinFsp installation completed."
    } catch {
        Write-Failure "Failed to install WinFsp: $_"
        exit 1
    }
}

# 3. Check and Install Rclone
Write-Step "Checking Rclone..."
$rcloneCmd = Get-Command rclone -ErrorAction SilentlyContinue
if ($rcloneCmd -and (-not $Force)) {
    Write-Success "Rclone is already installed in PATH: $($rcloneCmd.Source)"
    & rclone version | Select-Object -First 1 | ForEach-Object { Write-Info $_ }
} else {
    Write-Info "Installing Rclone via winget..."
    try {
        winget install --id Rclone.Rclone --exact --silent --accept-package-agreements --accept-source-agreements
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and $exitCode -ne $AlreadyInstalledExitCode) {
            Write-Failure ("Rclone installation failed (winget exit code 0x{0:X8})." -f [uint32]$exitCode)
            exit 1
        }
        if (-not $rcloneCmd -and $exitCode -eq 0) {
            $installedByWcm += "rclone"
        }
        Write-Success "Rclone installation completed."
        
        # Refresh session PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    } catch {
        Write-Failure "Failed to install Rclone: $_"
        exit 1
    }
}

# Record installed tools to marker file
try {
    $markerData = [PSCustomObject]@{
        installed_by_wcm = @($installedByWcm | Select-Object -Unique)
        installed_at     = (Get-Date).ToString("o")
    }
    $markerJson = $markerData | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $MarkerPath -Value $markerJson -Encoding UTF8 -Force
} catch {
    Write-Info "Note: Could not write prerequisites marker to $MarkerPath : $_"
}

# 4. Final verification
Write-Step "Verifying installation integrity..."
# Refresh PATH so a freshly installed rclone is visible without a terminal restart.
$env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
$verifiedRclone = Get-Command rclone -ErrorAction SilentlyContinue
$verifiedWinFsp = @($winfspPaths | Where-Object { Test-Path $_ })

if ($verifiedRclone -and $verifiedWinFsp.Count -gt 0) {
    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host " [SUCCESS] All prerequisites are installed and verified!  " -ForegroundColor Green
    Write-Host " Next step: Configure your remotes via 'rclone config'   " -ForegroundColor White
    Write-Host " Then run: .\scripts\Mount-Manager.ps1 -Action start     " -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Green
} else {
    Write-Failure "Prerequisite verification failed after installation."
    if (-not $verifiedRclone) { Write-Failure "  rclone was not found in PATH." }
    if ($verifiedWinFsp.Count -eq 0) { Write-Failure "  WinFsp install directory was not found." }
    exit 1
}
