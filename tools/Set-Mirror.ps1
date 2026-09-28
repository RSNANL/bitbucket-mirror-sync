[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$MirrorId,
    [Parameter(Mandatory)][ValidateSet('Enabled', 'ScheduledRecovery')][string]$Setting,
    [Parameter(Mandatory)][bool]$Value,
    [string]$ConfigPath = 'config/mirrors.json',
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Config.psm1') -Force

$config = Get-MirrorConfiguration -ConfigPath $ConfigPath
$mirror = $config.mirrors | Where-Object { $_.id -eq $MirrorId } | Select-Object -First 1
if (-not $mirror) { throw "Mirror is not configured: $MirrorId" }

$propertyName = if ($Setting -eq 'Enabled') { 'enabled' } else { 'scheduled_recovery' }
$currentValue = [bool]$mirror.$propertyName

Write-Host 'Configuration plan:'
Write-Host "  Mirror id: $MirrorId"
Write-Host "  Setting:   $propertyName"
Write-Host "  Current:   $currentValue"
Write-Host "  Requested: $Value"

if ($currentValue -eq $Value) {
    Write-Host 'No configuration change is required.'
    return
}
if (-not $Apply) {
    Write-Host 'Planning only. Re-run with -Apply after reviewing the plan.'
    return
}
if (-not $PSCmdlet.ShouldProcess($MirrorId, "Set $propertyName to $Value")) { return }

$mirror.$propertyName = $Value
$root = Split-Path -Parent $PSScriptRoot
$absolutePath = if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $root $ConfigPath }
$json = $config | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($absolutePath, "$json`n", [Text.UTF8Encoding]::new($false))
Assert-MirrorConfiguration -ConfigPath $ConfigPath
Write-Host "Mirror configuration was updated. Review and publish the config/mirrors.json change."
