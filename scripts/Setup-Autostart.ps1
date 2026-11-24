<#
.SYNOPSIS
    Configures Windows Task Scheduler for WinCloudMount silent background autostart.

.DESCRIPTION
    Creates or removes a scheduled task that mounts configured drives silently at logon
    and automatically retries when a network connection becomes available. Uses native
    headless conhost on Windows 10 1903+ / Windows 11, falling back to SilentRunner.vbs
    on older builds.

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
$MountManagerPath = Join-Path $ScriptDir "Mount-Manager.ps1"
$VbsPath = Join-Path $ProjectRoot "launcher\SilentRunner.vbs"

if (-not (Test-Path $MountManagerPath)) {
    Write-Error "Mount orchestrator script not found: $MountManagerPath"
    exit 1
}

function New-NetworkConnectEventTrigger {
    $eventCimClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace "Root/Microsoft/Windows/TaskScheduler" -ErrorAction Stop
    $subscription = "<QueryList><Query Id=`"0`" Path=`"Microsoft-Windows-NetworkProfile/Operational`"><Select Path=`"Microsoft-Windows-NetworkProfile/Operational`">*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]</Select></Query></QueryList>"
    return (New-CimInstance -CimClass $eventCimClass -ClientOnly -Property @{
        Enabled      = $true
        Subscription = $subscription
        Delay        = "PT5S"
    })
}

function Enable-Autostart {
    Write-Host "Registering scheduled task '$TaskName'..." -ForegroundColor Cyan

    $osBuild = [Environment]::OSVersion.Version.Build
    $conhostCmd = Get-Command "conhost.exe" -ErrorAction SilentlyContinue

    # Prefer native headless conhost on Windows 10 1903+ / Windows 11 to avoid VBScript FoD deprecation.
    if ($osBuild -ge 18362 -and $conhostCmd) {
        $psArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$MountManagerPath`" -Action start"
        $taskAction = New-ScheduledTaskAction -Execute "conhost.exe" -Argument $psArgs -WorkingDirectory $ProjectRoot
        $launcherMode = "conhost.exe --headless"
    } else {
        if (-not (Test-Path $VbsPath)) {
            Write-Error "Legacy launcher script not found: $VbsPath"
            exit 1
        }
        $taskAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`"" -WorkingDirectory (Split-Path -Parent $VbsPath)
        $launcherMode = "SilentRunner.vbs (legacy fallback)"
    }

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $logonTrigger.Delay = "PT10S"

    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -Priority 5

    $triggers = @($logonTrigger)
    $netTriggerAdded = $false
    try {
        $netTrigger = New-NetworkConnectEventTrigger
        if ($netTrigger) {
            $triggers += $netTrigger
            $netTriggerAdded = $true
        }
    } catch {
        $null = $_
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

        $registeredWithNetTrigger = $false
        if ($netTriggerAdded) {
            try {
                Register-ScheduledTask -TaskName $TaskName `
                    -Action $taskAction `
                    -Trigger $triggers `
                    -Settings $taskSettings `
                    -Description "Auto-mounts WinCloudMount virtual cloud drives silently upon user logon and network recovery." | Out-Null
                $registeredWithNetTrigger = $true
            } catch {
                $null = $_
                Write-Warning "Could not attach network-connect event trigger; falling back to logon trigger only."
            }
        }

        if (-not $registeredWithNetTrigger) {
            Register-ScheduledTask -TaskName $TaskName `
                -Action $taskAction `
                -Trigger $logonTrigger `
                -Settings $taskSettings `
                -Description "Auto-mounts WinCloudMount virtual cloud drives silently upon user logon." | Out-Null
        }

        Write-Host "[SUCCESS] Task '$TaskName' registered successfully!" -ForegroundColor Green
        Write-Host "Launcher    : $launcherMode" -ForegroundColor White
        if ($registeredWithNetTrigger) {
            Write-Host "Triggers    : AtLogOn (+10s) + Network Connected Event 10000 (+5s)" -ForegroundColor White
        } else {
            Write-Host "Triggers    : AtLogOn (+10s)" -ForegroundColor White
        }
    } catch {
        Write-Error "Failed to register scheduled task: $_"
        exit 1
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
        foreach ($act in @($task.Actions)) {
            Write-Host "Action      : $($act.Execute) $($act.Arguments)"
        }
        foreach ($trig in @($task.Triggers)) {
            $trigName = $trig.CimClass.CimClassName
            $delayVal = if ($trig.PSObject.Properties['Delay']) { $trig.Delay } else { "" }
            Write-Host "Trigger     : $trigName (Enabled=$($trig.Enabled), Delay=$delayVal)"
        }

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
