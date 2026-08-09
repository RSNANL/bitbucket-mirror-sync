[CmdletBinding()]
param([string]$AuthenticationConfigPath = 'config/authentication.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Session.psm1') -Force

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or newer is required; current version is $($PSVersionTable.PSVersion)."
}

foreach ($legacyVariable in @('GITHUB_TOKEN', 'CLOUDFLARE_API_TOKEN', 'BITBUCKET_API_TOKEN')) {
    if ([Environment]::GetEnvironmentVariable($legacyVariable, 'Process')) {
        throw "$legacyVariable is set in the current process. Remove it before starting the interactive mirror management session."
    }
}

$externalGhToken = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process')
$currentSessionGhToken = [Environment]::GetEnvironmentVariable('MIRROR_SESSION_GITHUB_TOKEN', 'Process')
if ($externalGhToken -and $externalGhToken -ne $currentSessionGhToken) {
    throw 'GH_TOKEN is set outside the mirror management session. Remove it before starting interactive authorization.'
}

Disconnect-MirrorSession -ConfigPath $AuthenticationConfigPath
[void](Test-MirrorAuthenticationConfiguration -ConfigPath $AuthenticationConfigPath -RequireConfigured)
$config = Get-MirrorAuthenticationConfiguration -ConfigPath $AuthenticationConfigPath

$cloudflareScopes = @(
    $config.cloudflare.scopes |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
$requiredCloudflareScope = 'workers-scripts.write'
if ($cloudflareScopes.Count -ne 1 -or $cloudflareScopes[0] -ne $requiredCloudflareScope) {
    throw "Cloudflare management OAuth must request exactly '$requiredCloudflareScope'. Configure only Workers Scripts -> Write on the Cloudflare OAuth client and set cloudflare.scopes to ['$requiredCloudflareScope']."
}

try {
    Write-Host 'Starting GitHub interactive authorization...'
    Connect-GitHubSession -Configuration $config

    Write-Host 'Starting Cloudflare interactive authorization...'
    Connect-CloudflareSession -Configuration $config

    Write-Host 'Starting Bitbucket interactive authorization...'
    Connect-BitbucketSession -Configuration $config

    [void](Test-MirrorSession -ThrowOnFailure)
    Write-Host 'Mirror management session is authenticated. Credentials exist only in this PowerShell process.'
}
catch {
    Disconnect-MirrorSession -ConfigPath $AuthenticationConfigPath
    throw
}
