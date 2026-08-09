Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force

function Assert-MirrorConfiguration {
    param([string]$ConfigPath = 'config/mirrors.json')
    $root = Get-RepositoryRoot
    $node = Resolve-ExternalCommand node
    [void](Invoke-ExternalCommand -FilePath $node -ArgumentList @(
        (Join-Path $root 'scripts/validate-config.mjs'),
        (Join-Path $root $ConfigPath)
    ))
}

function Get-MirrorConfiguration {
    param([string]$ConfigPath = 'config/mirrors.json')
    $root = Get-RepositoryRoot
    $path = Join-Path $root $ConfigPath
    Assert-MirrorConfiguration -ConfigPath $ConfigPath
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
}

function Get-MirrorEntry {
    param(
        [Parameter(Mandatory)][string]$MirrorId,
        [string]$ConfigPath = 'config/mirrors.json'
    )
    $config = Get-MirrorConfiguration -ConfigPath $ConfigPath
    return $config.mirrors | Where-Object { $_.id -eq $MirrorId } | Select-Object -First 1
}

function Add-MirrorConfigurationEntry {
    param(
        [Parameter(Mandatory)][string]$MirrorId,
        [Parameter(Mandatory)][string]$BitbucketRepository,
        [Parameter(Mandatory)][string]$GitHubRepository,
        [bool]$ScheduledRecovery = $false,
        [string]$ConfigPath = 'config/mirrors.json'
    )
    $root = Get-RepositoryRoot
    $arguments = @(
        (Join-Path $root 'scripts/add-mirror-config.mjs'),
        '--config', (Join-Path $root $ConfigPath),
        '--id', $MirrorId,
        '--source', $BitbucketRepository,
        '--target', $GitHubRepository,
        '--enabled', 'true',
        '--scheduled-recovery', $ScheduledRecovery.ToString().ToLowerInvariant()
    )
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand node) -ArgumentList $arguments)
}

function Remove-MirrorConfigurationEntry {
    param(
        [Parameter(Mandatory)][string]$MirrorId,
        [string]$ConfigPath = 'config/mirrors.json'
    )
    $root = Get-RepositoryRoot
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand node) -ArgumentList @(
        (Join-Path $root 'scripts/remove-mirror-config.mjs'),
        '--config', (Join-Path $root $ConfigPath),
        '--id', $MirrorId
    ))
}

function Set-WorkerBaseUrl {
    param(
        [Parameter(Mandatory)][string]$WorkerBaseUrl,
        [string]$ConfigPath = 'config/mirrors.json'
    )
    $root = Get-RepositoryRoot
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand node) -ArgumentList @(
        (Join-Path $root 'scripts/set-worker-base-url.mjs'),
        '--config', (Join-Path $root $ConfigPath),
        '--url', $WorkerBaseUrl
    ))
}

function Set-GitHubDispatchIdentity {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][long]$InstallationId,
        [string]$ConfigPath = 'config/mirrors.json'
    )
    $root = Get-RepositoryRoot
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand node) -ArgumentList @(
        (Join-Path $root 'scripts/set-github-dispatch-identity.mjs'),
        '--config', (Join-Path $root $ConfigPath),
        '--client-id', $ClientId,
        '--installation-id', ([string]$InstallationId)
    ))
}

Export-ModuleMember -Function *
