[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MirrorId,
    [string]$ConfigPath = 'config/mirrors.json',
    [switch]$Dispatch
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
if ($Dispatch -and -not $mirror.enabled) { throw "Mirror is disabled and cannot be dispatched: $MirrorId" }
if (
    $null -eq $config.dispatch.github_app_id -or
    $null -eq $config.dispatch.github_app_installation_id
) {
    throw 'GitHub App dispatch identity is not configured.'
}
$environmentName = Get-DerivedEnvironmentName -MirrorId $MirrorId
$sourceLabelPrefix = "mirror:$MirrorId:source:"
$targetTitlePrefix = "mirror:$MirrorId:target:"
$webhookDescription = "mirror:$MirrorId"
$webhookUrl = "$(Resolve-WorkerBaseUrl -WorkerBaseUrl $config.worker.base_url)$($config.worker.path_prefix)/$MirrorId"

[void](Test-GitHubAuthentication)
[void](Assert-CloudflareWorkerReady -RequiredSecretNames @(
    'GITHUB_APP_PRIVATE_KEY',
    (Get-DerivedWebhookSecretBinding -MirrorId $MirrorId)
))
$bitbucketCredentials = Get-BitbucketCredentials
try {
    if ($null -eq (Get-BitbucketRepository -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials -AllowMissing)) {
        throw "Bitbucket source is inaccessible: $($mirror.bitbucket_repository)"
    }
    $targetRepository = Get-GitHubRepository -Repository $mirror.github_repository -AllowMissing
    if ($null -eq $targetRepository) {
        throw "GitHub target is missing: $($mirror.github_repository)"
    }
    if (-not [bool]$targetRepository.private) { throw 'GitHub target repository must be private.' }

    $sourceKeys = @(Get-BitbucketDeployKeys -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials | Where-Object { $_.label -like "$sourceLabelPrefix*" })
    if ($sourceKeys.Count -eq 0) { throw 'No managed Bitbucket deploy key was found.' }

    $targetKeys = @(Get-GitHubDeployKeys -Repository $mirror.github_repository | Where-Object { $_.title -like "$targetTitlePrefix*" -and $_.read_only -eq $false })
    if ($targetKeys.Count -eq 0) { throw 'No managed write-enabled GitHub deploy key was found.' }

    $webhooks = @(Get-BitbucketWebhooks -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials | Where-Object {
        $_.description -eq $webhookDescription -and
        $_.active -and
        $_.url -eq $webhookUrl -and
        'repo:push' -in @($_.events)
    })
    if ($webhooks.Count -eq 0) { throw 'No active managed Bitbucket push webhook with the expected URL was found.' }

    $environmentSecrets = @(Get-GitHubEnvironmentSecrets -InfrastructureRepository $config.dispatch.github_repository -EnvironmentName $environmentName)
    $secretNames = @($environmentSecrets | ForEach-Object { $_.name })
    foreach ($requiredSecret in @('BBT_MIRROR_SSH_KEY', 'GHB_MIRROR_SSH_KEY')) {
        if ($requiredSecret -notin $secretNames) { throw "Missing GitHub environment secret: $requiredSecret" }
    }

    Write-Host "Mirror resources are present for $MirrorId."
    Write-Host "  Bitbucket deploy keys: $($sourceKeys.Count)"
    Write-Host "  GitHub deploy keys:    $($targetKeys.Count)"
    Write-Host "  Valid push webhooks:   $($webhooks.Count)"
    Write-Host 'Cloudflare secret values are intentionally unreadable and are verified operationally by the webhook test.'

    if ($Dispatch) {
        Start-GitHubMirrorWorkflow -InfrastructureRepository $config.dispatch.github_repository -WorkflowFile $config.dispatch.workflow_file -MirrorId $MirrorId -Ref $config.dispatch.ref
        Write-Host 'Mirror workflow dispatch submitted. Verify the resulting GitHub Actions run before finalizing key rotation or cleanup.'
    }
}
finally {
    $bitbucketCredentials = $null
}
