[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('GitHub', 'Cloudflare', 'Bitbucket')][string]$Provider,
    [AllowNull()][string]$BitbucketClientSecret,
    [switch]$NoBrowser,
    [AllowNull()][Collections.Concurrent.ConcurrentQueue[object]]$AuthorizationEvents,
    [string]$AuthenticationConfigPath = 'config/authentication.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Session.psm1') -Force

[void](Test-MirrorAuthenticationConfiguration -ConfigPath $AuthenticationConfigPath -RequireConfigured)
$configuration = Get-MirrorAuthenticationConfiguration -ConfigPath $AuthenticationConfigPath

switch ($Provider) {
    'GitHub' { Connect-GitHubSession -Configuration $configuration -NoBrowser:$NoBrowser -AuthorizationEvents $AuthorizationEvents }
    'Cloudflare' { Connect-CloudflareSession -Configuration $configuration -NoBrowser:$NoBrowser -AuthorizationEvents $AuthorizationEvents }
    'Bitbucket' { Connect-BitbucketSession -Configuration $configuration -ClientSecret $BitbucketClientSecret -NoBrowser:$NoBrowser -AuthorizationEvents $AuthorizationEvents }
}

$BitbucketClientSecret = $null
