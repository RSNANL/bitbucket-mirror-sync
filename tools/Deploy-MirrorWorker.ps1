[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$GitHubAppClientId,
    [long]$GitHubAppInstallationId,
    [string]$GitHubAppPrivateKeyPath,
    [string]$ConfigPath = 'config/mirrors.json',
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Cloudflare.psm1') -Force

Assert-MirrorConfiguration -ConfigPath $ConfigPath
$config = Get-MirrorConfiguration -ConfigPath $ConfigPath
$configuredClientId = [string]$config.dispatch.github_app_client_id
$configuredInstallationId = $config.dispatch.github_app_installation_id
$installationIdProvided = $PSBoundParameters.ContainsKey('GitHubAppInstallationId')
if ([bool]$GitHubAppClientId -ne $installationIdProvided) {
    throw 'GitHubAppClientId and GitHubAppInstallationId must be supplied together.'
}
$effectiveClientId = if ($GitHubAppClientId) { $GitHubAppClientId } else { $configuredClientId }
$effectiveInstallationId = if ($installationIdProvided) { $GitHubAppInstallationId } else { $configuredInstallationId }
if ([string]::IsNullOrWhiteSpace($effectiveClientId) -or $null -eq $effectiveInstallationId) {
    throw 'GitHub App client and installation IDs are required for the first Worker deployment.'
}
if ($effectiveClientId -notmatch '^[A-Za-z0-9_-]+$') { throw 'GitHubAppClientId is not valid.' }
if ([long]$effectiveInstallationId -lt 1) { throw 'GitHubAppInstallationId must be a positive integer.' }

$privateKey = $null
if ($GitHubAppPrivateKeyPath) {
    $resolvedPrivateKeyPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($GitHubAppPrivateKeyPath)
    if (-not (Test-Path -LiteralPath $resolvedPrivateKeyPath -PathType Leaf)) {
        throw "GitHub App private key file was not found: $resolvedPrivateKeyPath"
    }
    $privateKey = Get-Content -LiteralPath $resolvedPrivateKeyPath -Raw
    if ($privateKey -notmatch '^-----BEGIN (RSA )?PRIVATE KEY-----') {
        throw 'GitHub App private key file is not a supported PEM private key.'
    }
}

$workerName = Get-CloudflareWorkerName
Write-Host 'Worker deployment plan:'
Write-Host "  Worker:                     $workerName"
Write-Host "  GitHub dispatch repository: $($config.dispatch.github_repository)"
Write-Host "  GitHub App client id:       $effectiveClientId"
Write-Host "  GitHub App installation id: $effectiveInstallationId"
Write-Host "  GitHub App private key:     $(if ($privateKey) { 'upload or rotate' } else { 'preserve existing binding' })"

if (-not $Apply) {
    Write-Host 'Planning only. Re-run with -Apply after reviewing the plan.'
    return
}
if (-not $PSCmdlet.ShouldProcess($workerName, 'Deploy Cloudflare Worker from the current working tree')) { return }

& (Join-Path $PSScriptRoot 'Test-Prerequisites.ps1') -ConfigPath $ConfigPath
$workerExists = Test-CloudflareWorkerDeployment
if (-not $workerExists -and -not $privateKey) {
    throw 'GitHubAppPrivateKeyPath is required when bootstrapping the Worker.'
}

if (
    $configuredClientId -ne $effectiveClientId -or
    $configuredInstallationId -ne [long]$effectiveInstallationId
) {
    Set-GitHubDispatchIdentity -ClientId $effectiveClientId -InstallationId ([long]$effectiveInstallationId) -ConfigPath $ConfigPath
    $config = Get-MirrorConfiguration -ConfigPath $ConfigPath
}

$root = Get-RepositoryRoot
$workerTests = @(Get-ChildItem -LiteralPath (Join-Path $root 'worker/test') -Filter '*.test.js' | Sort-Object Name | ForEach-Object { $_.FullName })
try {
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand node) -ArgumentList (@('--test') + $workerTests))
    Publish-CloudflareWorker -ConfigPath $ConfigPath
    if ($privateKey) {
        Set-CloudflareWorkerSecret -SecretName 'GITHUB_APP_PRIVATE_KEY' -SecretValue $privateKey
    }
    $secretNames = @(Get-CloudflareWorkerSecrets | ForEach-Object { [string]$_.name })
    if ('GITHUB_DISPATCH_TOKEN' -in $secretNames) {
        Remove-CloudflareWorkerSecret -SecretName 'GITHUB_DISPATCH_TOKEN'
        Write-Host 'Removed legacy personal dispatch token binding.'
    }
    [void](Assert-CloudflareWorkerReady)
}
finally {
    $privateKey = $null
}

Write-Host 'Cloudflare Worker is deployed and its GitHub App machine identity is ready.'
Write-Host 'No commit, push, mirror provisioning or workflow dispatch was performed.'
