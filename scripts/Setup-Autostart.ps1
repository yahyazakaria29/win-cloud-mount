<#
.SYNOPSIS
    Configures Windows Task Scheduler for WinCloudMount silent background autostart.

.DESCRIPTION
    Creates or removes a scheduled task that executes 'SilentRunner.vbs' upon user logon.
    Ensures cloud drives are mounted automatically in the background without any CMD/PowerShell windows.

.PARAMETER Action
    'enable', 'disable', or 'status'.

.EXAMPLE
    .\Setup-Autostart.ps1 -Action enable
    .\Setup-Autostart.ps1 -Action status
    .\Setup-Autostart.ps1 -Action disable
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateSet("enable", "disable", "status")]
    [string]$Action = "status"
)

$TaskName = "WinCloudMount-Autostart"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$VbsPath = Join-Path $ProjectRoot "launcher\SilentRunner.vbs"

if (-not (Test-Path $VbsPath)) {
    Write-Error "Launcher script not found: $VbsPath"
    exit 1
}

function Enable-Autostart {
    Write-Host "Registering scheduled task '$TaskName'..." -ForegroundColor Cyan

    $taskAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`"" -WorkingDirectory (Split-Path -Parent $VbsPath)
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 365) -Priority 5

    try {
        # Unregister existing if present
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

        Register-ScheduledTask -TaskName $TaskName `
            -Action $taskAction `
            -Trigger $taskTrigger `
            -Settings $taskSettings `
            -Description "Auto-mounts WinCloudMount virtual cloud drives silently upon user logon." | Out-Null

        Write-Host "[SUCCESS] Task '$TaskName' registered successfully!" -ForegroundColor Green
        Write-Host "WinCloudMount will now launch silently in the background on every Windows logon." -ForegroundColor White
    } catch {
        Write-Error "Failed to register scheduled task: $_"
    }
}

function Disable-Autostart {
    Write-Host "Unregistering scheduled task '$TaskName'..." -ForegroundColor Yellow
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "[SUCCESS] Scheduled task '$TaskName' removed." -ForegroundColor Green
    } catch {
        Write-Warning "Task '$TaskName' was not found or could not be removed: $_"
    }
}

function Get-AutostartStatus {
    Write-Host "`nChecking scheduled task status: '$TaskName'..." -ForegroundColor Cyan
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host "Status      : [ACTIVE] Registered in Task Scheduler" -ForegroundColor Green
        Write-Host "State       : $($task.State)"
        Write-Host "Task Path   : $($task.TaskPath)"
        Write-Host "Target VBS  : $VbsPath"
        
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($taskInfo) {
            Write-Host "Last Run    : $($taskInfo.LastRunTime)"
            Write-Host "Last Result : $($taskInfo.LastTaskResult)"
        }
    } else {
        Write-Host "Status      : [NOT REGISTERED]" -ForegroundColor Yellow
        Write-Host "Run '.\Setup-Autostart.ps1 -Action enable' to activate auto-mount on logon." -ForegroundColor Gray
    }
}

switch ($Action) {
    "enable"  { Enable-Autostart }
    "disable" { Disable-Autostart }
    "status"  { Get-AutostartStatus }
}
