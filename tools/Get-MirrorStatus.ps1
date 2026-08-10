[CmdletBinding()]
param([string]$ConfigPath = 'config/mirrors.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Status.psm1') -Force

Get-MirrorStatusSnapshot -ConfigPath $ConfigPath
