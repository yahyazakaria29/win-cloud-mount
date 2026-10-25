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

# 2. Check and Install WinFsp
Write-Step "Checking WinFsp (Windows File System Proxy)..."
$winfspPaths = @(
    "$env:ProgramFiles\WinFsp",
    "${env:ProgramFiles(x86)}\WinFsp"
)
$winfspInstalled = $winfspPaths | Where-Object { Test-Path $_ }

if ($winfspInstalled -and (-not $Force)) {
    Write-Success "WinFsp is already installed at: $($winfspInstalled[0])"
} else {
    Write-Info "Installing WinFsp via winget..."
    try {
        winget install --id WinFsp.WinFsp --exact --silent --accept-package-agreements --accept-source-agreements
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
        Write-Success "Rclone installation completed."
        
        # Refresh session PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    } catch {
        Write-Failure "Failed to install Rclone: $_"
        exit 1
    }
}

# 4. Final verification
Write-Step "Verifying installation integrity..."
$verifiedRclone = Get-Command rclone -ErrorAction SilentlyContinue
$verifiedWinFsp = $winfspPaths | Where-Object { Test-Path $_ }

if ($verifiedRclone -and $verifiedWinFsp) {
    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host " [SUCCESS] All prerequisites are installed and verified!  " -ForegroundColor Green
    Write-Host " Next step: Configure your remotes via 'rclone config'   " -ForegroundColor White
    Write-Host " Then run: .\scripts\Mount-Manager.ps1 -Action start     " -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Green
} else {
    Write-Warning "Prerequisites installed, but terminal restart may be required to refresh PATH environment."
}
