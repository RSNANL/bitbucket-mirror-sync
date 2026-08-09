[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$MirrorId,
    [Parameter(Mandatory)][string]$BitbucketRepository,
    [Parameter(Mandatory)][string]$GitHubRepository,
    [string]$WorkerBaseUrl,
    [string]$ConfigPath = 'config/mirrors.json',
    [switch]$ScheduledRecovery,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.GitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Bitbucket.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Cloudflare.psm1') -Force

Assert-MirrorId -MirrorId $MirrorId
[void](Split-RepositoryName -Repository $BitbucketRepository)
[void](Split-RepositoryName -Repository $GitHubRepository)
Assert-MirrorConfiguration -ConfigPath $ConfigPath
$config = Get-MirrorConfiguration -ConfigPath $ConfigPath

if ($config.mirrors | Where-Object { $_.id -eq $MirrorId }) { throw "Mirror id already exists: $MirrorId" }
if ($config.mirrors | Where-Object { $_.bitbucket_repository -eq $BitbucketRepository }) { throw "Bitbucket source is already configured: $BitbucketRepository" }
if ($config.mirrors | Where-Object { $_.github_repository -eq $GitHubRepository }) { throw "GitHub target is already configured: $GitHubRepository" }

$effectiveWorkerBaseUrl = if ($WorkerBaseUrl) { $WorkerBaseUrl } else { $config.worker.base_url }
if (-not $effectiveWorkerBaseUrl) {
    throw 'WorkerBaseUrl is required until worker.base_url has been committed to config/mirrors.json.'
}
$effectiveWorkerBaseUrl = Resolve-WorkerBaseUrl -WorkerBaseUrl $effectiveWorkerBaseUrl

$environmentName = Get-DerivedEnvironmentName -MirrorId $MirrorId
$secretBinding = Get-DerivedWebhookSecretBinding -MirrorId $MirrorId
$sourceKeyLabel = "mirror:$MirrorId:source:$(Get-Date -Format yyyyMMddHHmmss)"
$targetKeyTitle = "mirror:$MirrorId:target:$(Get-Date -Format yyyyMMddHHmmss)"
$webhookDescription = "mirror:$MirrorId"
$webhookUrl = "$effectiveWorkerBaseUrl$($config.worker.path_prefix)/$MirrorId"
$infrastructureRepository = $config.dispatch.github_repository

Write-Host 'Provisioning plan:'
Write-Host "  Mirror id:             $MirrorId"
Write-Host "  Bitbucket source:      $BitbucketRepository"
Write-Host "  GitHub target:         $GitHubRepository"
Write-Host "  GitHub environment:    $environmentName"
Write-Host "  Worker secret binding: $secretBinding"
Write-Host "  Webhook URL:           $webhookUrl"

if (-not $Apply) {
    Write-Host 'Planning only. Re-run with -Apply after reviewing the plan.'
    return
}
if (-not $PSCmdlet.ShouldProcess($MirrorId, 'Provision Bitbucket-to-GitHub mirror infrastructure')) { return }
if (
    $null -eq $config.dispatch.github_app_id -or
    $null -eq $config.dispatch.github_app_installation_id
) {
    throw 'GitHub App dispatch identity is not configured. Run .\tools\Deploy-MirrorWorker.ps1 before provisioning a mirror.'
}

& (Join-Path $PSScriptRoot 'Test-Prerequisites.ps1') -ConfigPath $ConfigPath
[void](Assert-CloudflareWorkerReady)
$bitbucketCredentials = Get-BitbucketCredentials
$tempDirectory = New-SecureTemporaryDirectory -Prefix "mirror-$MirrorId"
$state = @{
    phase = 'starting'
    bitbucket_repository = $BitbucketRepository
    github_repository = $GitHubRepository
    infrastructure_repository = $infrastructureRepository
    environment_name = $environmentName
    webhook_secret_binding = $secretBinding
    webhook_url = $webhookUrl
}
Write-ProvisioningState -MirrorId $MirrorId -State $state

try {
    if ($null -eq (Get-BitbucketRepository -Repository $BitbucketRepository -Credentials $bitbucketCredentials -AllowMissing)) {
        throw "Bitbucket source repository does not exist or is inaccessible: $BitbucketRepository"
    }
    if ($null -ne (Get-GitHubRepository -Repository $GitHubRepository -AllowMissing)) {
        throw "GitHub target repository already exists: $GitHubRepository"
    }

    $sourceKey = New-SshKeyPair -Directory $tempDirectory -FileName 'bitbucket_source' -Label $sourceKeyLabel
    $targetKey = New-SshKeyPair -Directory $tempDirectory -FileName 'github_target' -Label $targetKeyTitle

    $targetRepository = New-GitHubMirrorRepository -Repository $GitHubRepository
    $state.github_repository_created = $true
    $state.github_repository_id = $targetRepository.id
    Write-ProvisioningState -MirrorId $MirrorId -State $state

    $bitbucketDeployKey = New-BitbucketDeployKey -Repository $BitbucketRepository -Label $sourceKeyLabel -PublicKey $sourceKey.PublicKey -Credentials $bitbucketCredentials
    $state.bitbucket_deploy_key_id = $bitbucketDeployKey.id
    $state.bitbucket_deploy_key_label = $sourceKeyLabel
    Write-ProvisioningState -MirrorId $MirrorId -State $state

    $githubDeployKey = New-GitHubDeployKey -Repository $GitHubRepository -Title $targetKeyTitle -PublicKey $targetKey.PublicKey -ReadOnly:$false
    $state.github_deploy_key_id = $githubDeployKey.id
    $state.github_deploy_key_title = $targetKeyTitle
    Write-ProvisioningState -MirrorId $MirrorId -State $state

    [void](New-GitHubEnvironment -InfrastructureRepository $infrastructureRepository -EnvironmentName $environmentName)
    $state.github_environment_created = $true
    Write-ProvisioningState -MirrorId $MirrorId -State $state

    Set-GitHubEnvironmentSecret -InfrastructureRepository $infrastructureRepository -EnvironmentName $environmentName -SecretName 'BBT_MIRROR_SSH_KEY' -SecretValue $sourceKey.PrivateKey
    Set-GitHubEnvironmentSecret -InfrastructureRepository $infrastructureRepository -EnvironmentName $environmentName -SecretName 'GHB_MIRROR_SSH_KEY' -SecretValue $targetKey.PrivateKey
    $state.github_environment_secrets_set = $true
    Write-ProvisioningState -MirrorId $MirrorId -State $state

    $webhookSecret = New-RandomSecret -ByteLength 32
    Set-CloudflareWorkerSecret -SecretName $secretBinding -SecretValue $webhookSecret
    $state.cloudflare_secret_set = $true
    Write-ProvisioningState -MirrorId $MirrorId -State $state

    $webhook = New-BitbucketWebhook -Repository $BitbucketRepository -Description $webhookDescription -Url $webhookUrl -Secret $webhookSecret -Credentials $bitbucketCredentials
    $state.bitbucket_webhook_id = $webhook.uuid
    $state.bitbucket_webhook_created = $true
    Write-ProvisioningState -MirrorId $MirrorId -State $state
    $webhookSecret = $null

    if ($WorkerBaseUrl -and $config.worker.base_url -ne $effectiveWorkerBaseUrl) {
        Set-WorkerBaseUrl -WorkerBaseUrl $effectiveWorkerBaseUrl -ConfigPath $ConfigPath
    }
    Add-MirrorConfigurationEntry -MirrorId $MirrorId -BitbucketRepository $BitbucketRepository -GitHubRepository $GitHubRepository -ScheduledRecovery:$ScheduledRecovery -ConfigPath $ConfigPath
    $state.configuration_prepared = $true
    $state.phase = 'prepared'
    Write-ProvisioningState -MirrorId $MirrorId -State $state

    Write-Host 'Mirror infrastructure has been provisioned and the local configuration has been prepared.'
    Write-Host 'No commit, push, Worker deployment or mirror workflow dispatch was performed.'
    Write-Host 'Review and commit the configuration, deploy Worker, then run Test-Mirror.ps1 -Dispatch.'
}
finally {
    $bitbucketCredentials = $null
    Remove-SecureDirectory -Path $tempDirectory
}
