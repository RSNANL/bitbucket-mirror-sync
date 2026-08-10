[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('GitHub', 'Cloudflare', 'Bitbucket')][string]$Provider,
    [AllowNull()][string]$BitbucketClientSecret,
    [switch]$NoBrowser,
    [string]$AuthenticationConfigPath = 'config/authentication.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Session.psm1') -Force

[void](Test-MirrorAuthenticationConfiguration -ConfigPath $AuthenticationConfigPath -RequireConfigured)
$configuration = Get-MirrorAuthenticationConfiguration -ConfigPath $AuthenticationConfigPath

switch ($Provider) {
    'GitHub' { Connect-GitHubSession -Configuration $configuration -NoBrowser:$NoBrowser }
    'Cloudflare' { Connect-CloudflareSession -Configuration $configuration -NoBrowser:$NoBrowser }
    'Bitbucket' { Connect-BitbucketSession -Configuration $configuration -ClientSecret $BitbucketClientSecret -NoBrowser:$NoBrowser }
}

$BitbucketClientSecret = $null
