[CmdletBinding()]
param([string]$AuthenticationConfigPath = 'config/authentication.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Session.psm1') -Force

Disconnect-MirrorSession -ConfigPath $AuthenticationConfigPath
