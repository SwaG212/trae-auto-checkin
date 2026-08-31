#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'TRAE Auto Checkin'
$installDirectory = Join-Path $env:LOCALAPPDATA 'TraeAutoCheckin'

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $installDirectory) {
    Remove-Item -LiteralPath $installDirectory -Recurse -Force
}
Write-Host 'TRAE 自动签到已卸载。'
