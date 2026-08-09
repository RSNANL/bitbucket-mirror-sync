[CmdletBinding()]
param(
    [switch]$SkipSessionAuthentication,
    [string]$BitbucketRepository,
    [string]$ConfigPath = 'config/mirrors.json',
    [string]$AuthenticationConfigPath = 'config/authentication.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Session.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.GitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Bitbucket.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Cloudflare.psm1') -Force

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or newer is required; current version is $($PSVersionTable.PSVersion)."
}

$requiredCommands = @('git', 'ssh-keygen', 'node', 'npm', 'npx', 'gh')
$missing = @($requiredCommands | Where-Object { -not (Test-ExternalCommand $_) })
if ($missing.Count -gt 0) {
    throw "Missing required command(s): $($missing -join ', ')."
}

$nodeVersionResult = Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand node) -ArgumentList @('--version')
if ($nodeVersionResult.StdOut -notmatch '^v(?<major>[0-9]+)\.') {
    throw "Unable to determine Node.js version: $($nodeVersionResult.StdOut)"
}
if ([int]$Matches.major -lt 22) {
    throw "Node.js 22 or newer is required; current version is $($nodeVersionResult.StdOut)."
}

Assert-MirrorConfiguration -ConfigPath $ConfigPath
[void](Test-MirrorAuthenticationConfiguration -ConfigPath $AuthenticationConfigPath)

if (Test-PersistentGitHubCredential) {
    throw 'Persistent GitHub CLI authentication is present. Remove it once with `gh auth logout --hostname github.com`; mirror management uses only per-session interactive authorization.'
}

if (-not $SkipSessionAuthentication) {
    [void](Test-MirrorSession -ThrowOnFailure)
    [void](Test-GitHubAuthentication)
    [void](Test-CloudflareAuthentication)

    if ($BitbucketRepository) {
        [void](Split-RepositoryName -Repository $BitbucketRepository)
        $bitbucketCredentials = Get-BitbucketCredentials
        try {
            if ($null -eq (Get-BitbucketRepository -Repository $BitbucketRepository -Credentials $bitbucketCredentials -AllowMissing)) {
                throw "Bitbucket repository is inaccessible with the current management session: $BitbucketRepository"
            }
        }
        finally {
            $bitbucketCredentials = $null
        }
    }
}

$root = Get-RepositoryRoot
$status = Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand git) -ArgumentList @('-C', $root, 'status', '--porcelain')
if ($status.StdOut) {
    Write-Warning 'The infrastructure working tree contains uncommitted changes. Understand and review them before provisioning.'
}

Write-Host 'All requested prerequisites are available.'
