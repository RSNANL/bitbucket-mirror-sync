[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$MirrorId,
    [string]$ConfigPath = 'config/mirrors.json',
    [switch]$DeleteTargetRepository,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.GitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Bitbucket.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Cloudflare.psm1') -Force

$config = Get-MirrorConfiguration -ConfigPath $ConfigPath
$mirror = $config.mirrors | Where-Object { $_.id -eq $MirrorId } | Select-Object -First 1
if (-not $mirror) { throw "Mirror is not configured: $MirrorId" }
$environmentName = Get-DerivedEnvironmentName -MirrorId $MirrorId
$secretBinding = Get-DerivedWebhookSecretBinding -MirrorId $MirrorId
$sourcePrefix = "mirror:$MirrorId:source:"
$targetPrefix = "mirror:$MirrorId:target:"
$webhookDescription = "mirror:$MirrorId"

Write-Host 'Removal plan:'
Write-Host "  Remove managed Bitbucket webhook and deploy keys from $($mirror.bitbucket_repository)."
Write-Host "  Remove managed GitHub deploy keys and environment $environmentName."
Write-Host "  Delete Worker secret binding $secretBinding."
Write-Host "  Remove the local configuration entry."
Write-Host "  Delete target repository: $DeleteTargetRepository"
Write-Host '  The Bitbucket source repository itself is never deleted.'
if (-not $Apply) {
    Write-Host 'Planning only. Re-run with -Apply after reviewing the plan.'
    return
}
if (-not $PSCmdlet.ShouldProcess($MirrorId, 'Remove isolated mirror infrastructure')) { return }

$bitbucketCredentials = Get-BitbucketCredentials
try {
    foreach ($webhook in @(Get-BitbucketWebhooks -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials | Where-Object { $_.description -eq $webhookDescription })) {
        Remove-BitbucketWebhook -Repository $mirror.bitbucket_repository -WebhookId $webhook.uuid -Credentials $bitbucketCredentials
    }
    foreach ($key in @(Get-BitbucketDeployKeys -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials | Where-Object { $_.label -like "$sourcePrefix*" })) {
        Remove-BitbucketDeployKey -Repository $mirror.bitbucket_repository -KeyId ([string]$key.id) -Credentials $bitbucketCredentials
    }
    foreach ($key in @(Get-GitHubDeployKeys -Repository $mirror.github_repository | Where-Object { $_.title -like "$targetPrefix*" })) {
        Remove-GitHubDeployKey -Repository $mirror.github_repository -KeyId ([long]$key.id)
    }
    Remove-GitHubEnvironment -InfrastructureRepository $config.dispatch.github_repository -EnvironmentName $environmentName
    Remove-CloudflareWorkerSecret -SecretName $secretBinding
    Remove-MirrorConfigurationEntry -MirrorId $MirrorId -ConfigPath $ConfigPath
    if ($DeleteTargetRepository) {
        Remove-GitHubRepository -Repository $mirror.github_repository
    }
    Remove-ProvisioningState -MirrorId $MirrorId
    Write-Host 'Mirror resources were removed. Review, commit and deploy the configuration change.'
}
finally {
    $bitbucketCredentials = $null
}
