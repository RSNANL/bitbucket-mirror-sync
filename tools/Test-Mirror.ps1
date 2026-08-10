[CmdletBinding(DefaultParameterSetName = 'Resources')]
param(
    [Parameter(Mandatory)][string]$MirrorId,
    [string]$ConfigPath = 'config/mirrors.json',
    [switch]$Dispatch,
    [Parameter(Mandatory, ParameterSetName = 'RefSynchronization')][switch]$ValidateRefSynchronization,
    [Parameter(Mandatory, ParameterSetName = 'RefSynchronization')][string]$SourceRepositoryPath,
    [Parameter(ParameterSetName = 'RefSynchronization')][ValidateRange(30, 1800)][int]$RefSynchronizationTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.GitHub.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Bitbucket.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Cloudflare.psm1') -Force

function Resolve-BitbucketRepositoryFromRemote {
    param([Parameter(Mandatory)][string]$RemoteUrl)

    $match = [regex]::Match(
        $RemoteUrl.Trim(),
        '^(?:(?:https://|ssh://git@)bitbucket\.org/|git@bitbucket\.org:)(?<repository>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) { return $null }
    return $match.Groups['repository'].Value
}

function Get-GitHubReferenceSha {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Reference
    )

    $referenceState = Invoke-GitHubApi `
        -Method GET `
        -Endpoint "repos/$Repository/git/ref/$Reference" `
        -AllowMissing
    if ($null -eq $referenceState) { return $null }
    return [string]$referenceState.object.sha
}

function Wait-GitHubReferences {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$BranchName,
        [Parameter(Mandatory)][string]$TagName,
        [AllowNull()][string]$ExpectedSha,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $branchReference = "heads/$BranchName"
    $tagReference = "tags/$TagName"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $branchSha = Get-GitHubReferenceSha -Repository $Repository -Reference $branchReference
        $tagSha = Get-GitHubReferenceSha -Repository $Repository -Reference $tagReference
        if ($null -eq $ExpectedSha) {
            if ($null -eq $branchSha -and $null -eq $tagSha) { return }
        }
        elseif ($branchSha -eq $ExpectedSha -and $tagSha -eq $ExpectedSha) {
            return
        }
        Start-Sleep -Seconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    if ($null -eq $ExpectedSha) {
        throw "GitHub did not prune both validation refs within $TimeoutSeconds seconds. Branch SHA: '$branchSha'; tag SHA: '$tagSha'."
    }
    throw "GitHub did not mirror both validation refs at SHA $ExpectedSha within $TimeoutSeconds seconds. Branch SHA: '$branchSha'; tag SHA: '$tagSha'."
}

function Invoke-MirrorRefSynchronizationValidation {
    param(
        [Parameter(Mandatory)][object]$Mirror,
        [Parameter(Mandatory)][object]$BitbucketRepository,
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $resolvedRepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath -ErrorAction Stop).Path
    $git = Resolve-ExternalCommand git
    $workTreeResult = Invoke-ExternalCommand -FilePath $git -ArgumentList @(
        '-C', $resolvedRepositoryPath, 'rev-parse', '--is-inside-work-tree'
    )
    if ($workTreeResult.StdOut -ne 'true') {
        throw "SourceRepositoryPath is not a Git worktree: $resolvedRepositoryPath"
    }

    $remoteResult = Invoke-ExternalCommand -FilePath $git -ArgumentList @(
        '-C', $resolvedRepositoryPath, 'remote', 'get-url', '--push', 'origin'
    )
    $sourceRemoteUrl = $remoteResult.StdOut.Trim()
    $remoteRepository = Resolve-BitbucketRepositoryFromRemote -RemoteUrl $sourceRemoteUrl
    if ($null -eq $remoteRepository) {
        throw "The source origin is not a supported Bitbucket remote: $sourceRemoteUrl"
    }
    if ($remoteRepository -ine [string]$Mirror.bitbucket_repository) {
        throw "The source origin resolves to '$remoteRepository' instead of configured repository '$($Mirror.bitbucket_repository)'."
    }

    $defaultBranch = [string]$BitbucketRepository.mainbranch.name
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        throw "Bitbucket source has no default branch: $($Mirror.bitbucket_repository)"
    }

    $userNameResult = Invoke-ExternalCommand -FilePath $git -ArgumentList @(
        '-C', $resolvedRepositoryPath, 'config', '--get', 'user.name'
    ) -AllowFailure
    $userEmailResult = Invoke-ExternalCommand -FilePath $git -ArgumentList @(
        '-C', $resolvedRepositoryPath, 'config', '--get', 'user.email'
    ) -AllowFailure
    if ($userNameResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($userNameResult.StdOut)) {
        throw 'Git user.name is not configured for the source repository.'
    }
    if ($userEmailResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($userEmailResult.StdOut)) {
        throw 'Git user.email is not configured for the source repository.'
    }

    $testIdentifier = ([DateTimeOffset]::UtcNow).ToString('yyyyMMdd-HHmmss') + '-' + ([Guid]::NewGuid()).ToString('N').Substring(0, 8)
    $testBranch = "mirror-validation/$testIdentifier"
    $testTag = "mirror-validation-$testIdentifier"
    $temporaryRoot = $null
    $temporaryRepository = $null
    $branchCleanupRequired = $false
    $tagCleanupRequired = $false
    $testFailure = $null
    $cleanupFailures = [Collections.Generic.List[string]]::new()

    try {
        $temporaryRoot = New-SecureTemporaryDirectory -Prefix "mirror-validation-$($Mirror.id)"
        $temporaryRepository = Join-Path $temporaryRoot 'source'
        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            'clone', '--branch', $defaultBranch, '--single-branch', '--no-tags',
            $sourceRemoteUrl, $temporaryRepository
        ))
        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'config', 'user.name', $userNameResult.StdOut.Trim()
        ))
        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'config', 'user.email', $userEmailResult.StdOut.Trim()
        ))
        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'switch', '-c', $testBranch
        ))
        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'commit', '--allow-empty', '-m', 'Validate mirror ref synchronization'
        ))
        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'tag', $testTag
        ))
        $expectedSha = (Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'rev-parse', 'HEAD'
        )).StdOut.Trim()

        $branchCleanupRequired = $true
        $tagCleanupRequired = $true
        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'push', 'origin',
            "HEAD:refs/heads/$testBranch", "refs/tags/$testTag"
        ))
        Write-Host "Temporary Bitbucket branch and tag created at $expectedSha."

        Wait-GitHubReferences `
            -Repository $Mirror.github_repository `
            -BranchName $testBranch `
            -TagName $testTag `
            -ExpectedSha $expectedSha `
            -TimeoutSeconds $TimeoutSeconds
        Write-Host 'GitHub mirrored the temporary branch and tag at the expected SHA.'

        [void](Invoke-ExternalCommand -FilePath $git -ArgumentList @(
            '-C', $temporaryRepository, 'push', 'origin',
            ":refs/heads/$testBranch", ":refs/tags/$testTag"
        ))
        $branchCleanupRequired = $false
        $tagCleanupRequired = $false

        Wait-GitHubReferences `
            -Repository $Mirror.github_repository `
            -BranchName $testBranch `
            -TagName $testTag `
            -ExpectedSha $null `
            -TimeoutSeconds $TimeoutSeconds
        Write-Host 'GitHub pruned the temporary branch and tag.'
    }
    catch {
        $testFailure = $_
    }
    finally {
        if ($null -ne $temporaryRepository -and $branchCleanupRequired) {
            $cleanupResult = Invoke-ExternalCommand -FilePath $git -ArgumentList @(
                '-C', $temporaryRepository, 'push', 'origin', ":refs/heads/$testBranch"
            ) -AllowFailure
            if ($cleanupResult.ExitCode -ne 0) {
                $cleanupFailures.Add("Could not remove Bitbucket branch '$testBranch': $($cleanupResult.StdErr)")
            }
        }
        if ($null -ne $temporaryRepository -and $tagCleanupRequired) {
            $cleanupResult = Invoke-ExternalCommand -FilePath $git -ArgumentList @(
                '-C', $temporaryRepository, 'push', 'origin', ":refs/tags/$testTag"
            ) -AllowFailure
            if ($cleanupResult.ExitCode -ne 0) {
                $cleanupFailures.Add("Could not remove Bitbucket tag '$testTag': $($cleanupResult.StdErr)")
            }
        }
        if ($null -ne $temporaryRoot) {
            Remove-SecureDirectory -Path $temporaryRoot
            if (Test-Path -LiteralPath $temporaryRoot) {
                $cleanupFailures.Add("Could not remove temporary directory '$temporaryRoot'.")
            }
        }
    }

    if ($null -ne $testFailure) {
        if ($cleanupFailures.Count -gt 0) {
            throw "$($testFailure.Exception.Message)`nCleanup also failed:`n$($cleanupFailures -join "`n")"
        }
        throw $testFailure.Exception
    }
    if ($cleanupFailures.Count -gt 0) {
        throw "Mirror ref synchronization validation cleanup failed:`n$($cleanupFailures -join "`n")"
    }
    Write-Host 'MIRROR REF SYNCHRONIZATION VALIDATION PASSED'
}

$config = Get-MirrorConfiguration -ConfigPath $ConfigPath
$mirror = $config.mirrors | Where-Object { $_.id -eq $MirrorId } | Select-Object -First 1
if (-not $mirror) { throw "Mirror is not configured: $MirrorId" }
if (($Dispatch -or $ValidateRefSynchronization) -and -not $mirror.enabled) {
    throw "Mirror is disabled and cannot be exercised: $MirrorId"
}
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
    $sourceRepository = Get-BitbucketRepository -Repository $mirror.bitbucket_repository -Credentials $bitbucketCredentials -AllowMissing
    if ($null -eq $sourceRepository) {
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

    if ($ValidateRefSynchronization) {
        Invoke-MirrorRefSynchronizationValidation `
            -Mirror $mirror `
            -BitbucketRepository $sourceRepository `
            -RepositoryPath $SourceRepositoryPath `
            -TimeoutSeconds $RefSynchronizationTimeoutSeconds
    }
}
finally {
    $bitbucketCredentials = $null
}
