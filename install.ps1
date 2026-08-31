#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int]$DelayMinutes = 3
)

$ErrorActionPreference = 'Stop'
$taskName = 'TRAE Auto Checkin'
$installDirectory = Join-Path $env:LOCALAPPDATA 'TraeAutoCheckin'
$installedScript = Join-Path $installDirectory 'TRAE-AutoCheckin.ps1'
$sourceScript = Join-Path $PSScriptRoot 'TRAE-AutoCheckin.ps1'

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "缺少脚本：$sourceScript"
}

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $installedScript -Force

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $installedScript + '"'
$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $installDirectory
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$trigger.Delay = 'PT' + $DelayMinutes + 'M'
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "TRAE 登录 Windows 后延迟 $DelayMinutes 分钟自动签到"

Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
Write-Host "安装完成：$taskName（登录后延迟 $DelayMinutes 分钟运行）"
Write-Host "脚本位置：$installedScript"
