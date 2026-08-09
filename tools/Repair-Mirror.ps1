[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$MirrorId,
    [string]$ConfigPath = 'config/mirrors.json',
    [switch]$RepairWebhook
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
if (-not $config.worker.base_url) { throw 'worker.base_url is not configured.' }
$environmentName = Get-DerivedEnvironmentName -MirrorId $MirrorId
$secretBinding = Get-DerivedWebhookSecretBinding -MirrorId $MirrorId
$bitbucketCredentials = Get-BitbucketCredentials

try {
    if ($null -eq (Get-GitHubRepository -Repository $mirror.github_repository -AllowMissing)) {
        if ($PSCmdlet.ShouldProcess($mirror.github_repository, 'Recreate private GitHub mirror repository')) {
            [void](New-GitHubMirrorRepository -Repository $mirror.github_repository)
        }
    }
    if ($PSCmdlet.ShouldProcess($environmentName, 'Ensure GitHub environment exists')) {
        [void](New-GitHubEnvironment -InfrastructureRepository $config.dispatch.github_repository -EnvironmentName $environmentName)
    }

    & (Join-Path $PSScriptRoot 'Rotate-MirrorKeys.ps1') -MirrorId $MirrorId -Phase Prepare -ConfigPath $ConfigPath -Confirm:$false

    if ($RepairWebhook) {
        $webhookDescription = "mirror:$MirrorId"
        $webhooks = @(Get-BitbucketWebhooks -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials | Where-Object { $_.description -eq $webhookDescription })
        foreach ($webhook in $webhooks) {
            Remove-BitbucketWebhook -Repository $mirror.bitbucket_repository -WebhookId $webhook.uuid -Credentials $bitbucketCredentials
        }
        $secret = New-RandomSecret -ByteLength 32
        Set-CloudflareWorkerSecret -SecretName $secretBinding -SecretValue $secret
        $url = "$($config.worker.base_url.TrimEnd('/'))$($config.worker.path_prefix)/$MirrorId"
        [void](New-BitbucketWebhook -Repository $mirror.bitbucket_repository -Description $webhookDescription -Url $url -Secret $secret -Credentials $bitbucketCredentials)
        $secret = $null
        Write-Host 'Webhook and HMAC secret were replaced.'
    }

    Write-Host 'Repair preparation is complete. Verify the dispatched mirror workflow, then finalize key rotation.'
}
finally {
    $bitbucketCredentials = $null
}
