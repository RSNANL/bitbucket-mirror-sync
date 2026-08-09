[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$MirrorId,
    [Parameter(Mandatory)][ValidateSet('Prepare','Finalize')][string]$Phase,
    [string]$ConfigPath = 'config/mirrors.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.GitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Bitbucket.psm1') -Force

$config = Get-MirrorConfiguration -ConfigPath $ConfigPath
$mirror = $config.mirrors | Where-Object { $_.id -eq $MirrorId } | Select-Object -First 1
if (-not $mirror) { throw "Mirror is not configured: $MirrorId" }
$environmentName = Get-DerivedEnvironmentName -MirrorId $MirrorId
$sourcePrefix = "mirror:$MirrorId:source:"
$targetPrefix = "mirror:$MirrorId:target:"
$bitbucketCredentials = Get-BitbucketCredentials

try {
    if ($Phase -eq 'Prepare') {
        if (-not $PSCmdlet.ShouldProcess($MirrorId, 'Create replacement SSH keys and replace environment secrets')) { return }
        $oldSourceKeys = @(Get-BitbucketDeployKeys -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials | Where-Object { $_.label -like "$sourcePrefix*" })
        $oldTargetKeys = @(Get-GitHubDeployKeys -Repository $mirror.github_repository | Where-Object { $_.title -like "$targetPrefix*" })
        $timestamp = Get-Date -Format yyyyMMddHHmmss
        $sourceLabel = "$sourcePrefix$timestamp"
        $targetTitle = "$targetPrefix$timestamp"
        $tempDirectory = New-SecureTemporaryDirectory -Prefix "mirror-rotation-$MirrorId"
        try {
            $sourceKey = New-SshKeyPair -Directory $tempDirectory -FileName 'bitbucket_source' -Label $sourceLabel
            $targetKey = New-SshKeyPair -Directory $tempDirectory -FileName 'github_target' -Label $targetTitle
            $newSource = New-BitbucketDeployKey -Repository $mirror.bitbucket_repository -Label $sourceLabel -PublicKey $sourceKey.PublicKey -Credentials $bitbucketCredentials
            $newTarget = New-GitHubDeployKey -Repository $mirror.github_repository -Title $targetTitle -PublicKey $targetKey.PublicKey -ReadOnly:$false
            Set-GitHubEnvironmentSecret -InfrastructureRepository $config.dispatch.github_repository -EnvironmentName $environmentName -SecretName 'BBT_MIRROR_SSH_KEY' -SecretValue $sourceKey.PrivateKey
            Set-GitHubEnvironmentSecret -InfrastructureRepository $config.dispatch.github_repository -EnvironmentName $environmentName -SecretName 'GHB_MIRROR_SSH_KEY' -SecretValue $targetKey.PrivateKey
            Write-ProvisioningState -MirrorId $MirrorId -State @{
                phase = 'rotation-prepared'
                bitbucket_repository = $mirror.bitbucket_repository
                github_repository = $mirror.github_repository
                old_bitbucket_key_ids = @($oldSourceKeys | ForEach-Object { $_.id })
                old_github_key_ids = @($oldTargetKeys | ForEach-Object { $_.id })
                new_bitbucket_key_id = $newSource.id
                new_github_key_id = $newTarget.id
            }
            Start-GitHubMirrorWorkflow -InfrastructureRepository $config.dispatch.github_repository -WorkflowFile $config.dispatch.workflow_file -MirrorId $MirrorId -Ref $config.dispatch.ref
            Write-Host 'Replacement keys are active and a test dispatch was submitted.'
            Write-Host 'Verify the workflow succeeds, then run this script with -Phase Finalize.'
        }
        finally {
            Remove-SecureDirectory -Path $tempDirectory
        }
    }
    else {
        $state = Read-ProvisioningState -MirrorId $MirrorId
        if (-not $state -or $state.phase -ne 'rotation-prepared') { throw 'No prepared rotation state was found.' }
        if (-not $PSCmdlet.ShouldProcess($MirrorId, 'Remove superseded SSH deploy keys')) { return }
        foreach ($keyId in @($state.old_bitbucket_key_ids)) {
            if ([string]$keyId -ne [string]$state.new_bitbucket_key_id) {
                Remove-BitbucketDeployKey -Repository $mirror.bitbucket_repository -KeyId ([string]$keyId) -Credentials $bitbucketCredentials
            }
        }
        foreach ($keyId in @($state.old_github_key_ids)) {
            if ([long]$keyId -ne [long]$state.new_github_key_id) {
                Remove-GitHubDeployKey -Repository $mirror.github_repository -KeyId ([long]$keyId)
            }
        }
        Remove-ProvisioningState -MirrorId $MirrorId
        Write-Host 'Superseded deploy keys were removed.'
    }
}
finally {
    $bitbucketCredentials = $null
}
