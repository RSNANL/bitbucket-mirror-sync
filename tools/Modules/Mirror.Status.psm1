Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Mirror.Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Mirror.Bitbucket.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Mirror.Cloudflare.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Mirror.GitHub.psm1') -Force

function Get-MirrorStatusValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-MirrorStatusNestedValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Path
    )

    $value = $InputObject
    foreach ($name in $Path) {
        $value = Get-MirrorStatusValue -InputObject $value -Name $name
        if ($null -eq $value) { return $null }
    }
    return $value
}

function New-MirrorStatusCheck {
    param(
        [Parameter(Mandatory)][ValidateSet('healthy', 'unhealthy', 'unknown')][string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$CheckedAt,
        [Collections.IDictionary]$Details = @{}
    )

    $result = [ordered]@{
        state = $State
        checked_at = $CheckedAt
        reason = $Reason
    }
    foreach ($key in $Details.Keys) { $result[[string]$key] = $Details[$key] }
    return [pscustomobject]$result
}

function Resolve-MirrorOverallStatus {
    param(
        [Parameter(Mandatory)][object[]]$Checks,
        [Parameter(Mandatory)][string]$CheckedAt
    )

    $unhealthy = @($Checks | Where-Object { $_.Check.state -eq 'unhealthy' } | ForEach-Object { $_.Label })
    if ($unhealthy.Count -gt 0) {
        return New-MirrorStatusCheck -State 'unhealthy' -CheckedAt $CheckedAt -Reason ("Issues: " + ($unhealthy -join ', '))
    }
    $unknown = @($Checks | Where-Object { $_.Check.state -eq 'unknown' } | ForEach-Object { $_.Label })
    if ($unknown.Count -gt 0) {
        return New-MirrorStatusCheck -State 'unknown' -CheckedAt $CheckedAt -Reason ("Unknown: " + ($unknown -join ', '))
    }
    return New-MirrorStatusCheck -State 'healthy' -CheckedAt $CheckedAt -Reason 'All monitored mirror resources are healthy.'
}

function Get-MirrorStatusErrorReason {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($ErrorRecord.Exception.Message -match 'not authenticated|not connected|access token is required') {
        return "$Provider is not connected."
    }
    return "$Provider status could not be retrieved: $($ErrorRecord.Exception.Message)"
}

function Get-MirrorStatusSnapshot {
    param([string]$ConfigPath = 'config/mirrors.json')

    $config = Get-MirrorConfiguration -ConfigPath $ConfigPath
    $checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $workerBaseUrl = Resolve-WorkerBaseUrl -WorkerBaseUrl ([string]$config.worker.base_url)
    $requiredWorkerSecrets = @('GITHUB_APP_PRIVATE_KEY') + @(
        $config.mirrors | ForEach-Object { Get-DerivedWebhookSecretBinding -MirrorId ([string]$_.id) }
    )

    $cloudflareReadiness = $null
    $cloudflareError = $null
    try { $cloudflareReadiness = Get-CloudflareWorkerReadiness -RequiredSecretNames $requiredWorkerSecrets }
    catch { $cloudflareError = Get-MirrorStatusErrorReason -Provider 'Cloudflare' -ErrorRecord $_ }

    $workflowRuns = @()
    $githubRunsError = $null
    try {
        $workflowRuns = @(Get-GitHubMirrorWorkflowRuns `
            -InfrastructureRepository ([string]$config.dispatch.github_repository) `
            -WorkflowFile ([string]$config.dispatch.workflow_file))
    }
    catch { $githubRunsError = Get-MirrorStatusErrorReason -Provider 'GitHub Actions' -ErrorRecord $_ }

    $bitbucketCredentials = $null
    $bitbucketCredentialError = $null
    try { $bitbucketCredentials = Get-BitbucketCredentials }
    catch { $bitbucketCredentialError = Get-MirrorStatusErrorReason -Provider 'Bitbucket' -ErrorRecord $_ }

    $mirrors = foreach ($mirror in @($config.mirrors)) {
        $mirrorId = [string]$mirror.id
        $webhookUrl = "$workerBaseUrl$($config.worker.path_prefix)/$mirrorId"
        $sourceCheck = $null
        $webhookCheck = $null
        $targetCheck = $null

        if ($bitbucketCredentialError) {
            $sourceCheck = New-MirrorStatusCheck -State 'unknown' -Reason $bitbucketCredentialError -CheckedAt $checkedAt
            $webhookCheck = New-MirrorStatusCheck -State 'unknown' -Reason $bitbucketCredentialError -CheckedAt $checkedAt -Details @{ expected_url = $webhookUrl }
        } else {
            try {
                $sourceRepository = Get-BitbucketRepository -Repository ([string]$mirror.bitbucket_repository) -Credentials $bitbucketCredentials -AllowMissing
                if ($null -eq $sourceRepository) {
                    $sourceCheck = New-MirrorStatusCheck -State 'unhealthy' -Reason 'Bitbucket source repository is missing or inaccessible.' -CheckedAt $checkedAt
                    $webhookCheck = New-MirrorStatusCheck -State 'unknown' -Reason 'Webhook cannot be checked while the source repository is unavailable.' -CheckedAt $checkedAt -Details @{ expected_url = $webhookUrl }
                } else {
                    $mainBranch = [string](Get-MirrorStatusNestedValue -InputObject $sourceRepository -Path @('mainbranch', 'name'))
                    $latestCommit = if ([string]::IsNullOrWhiteSpace($mainBranch)) {
                        $null
                    } else {
                        Get-BitbucketLatestCommit -Repository ([string]$mirror.bitbucket_repository) -Revision $mainBranch -Credentials $bitbucketCredentials
                    }
                    $sourceCheck = New-MirrorStatusCheck -State 'healthy' -Reason 'Bitbucket source repository is accessible.' -CheckedAt $checkedAt -Details @{
                        url = Get-MirrorStatusNestedValue -InputObject $sourceRepository -Path @('links', 'html', 'href')
                        updated_at = if ($null -ne $latestCommit) { Get-MirrorStatusValue -InputObject $latestCommit -Name 'date' } else { Get-MirrorStatusValue -InputObject $sourceRepository -Name 'updated_on' }
                        revision = if ($null -ne $latestCommit) { Get-MirrorStatusValue -InputObject $latestCommit -Name 'hash' } else { $null }
                    }

                    $validWebhooks = @(Get-BitbucketMirrorWebhooks `
                        -Repository ([string]$mirror.bitbucket_repository) `
                        -MirrorId $mirrorId `
                        -ExpectedUrl $webhookUrl `
                        -Credentials $bitbucketCredentials)
                    $webhookCheck = if ($validWebhooks.Count -gt 0) {
                        New-MirrorStatusCheck -State 'healthy' -Reason 'Active managed push webhook matches the expected Worker route.' -CheckedAt $checkedAt -Details @{
                            expected_url = $webhookUrl
                            webhook_count = $validWebhooks.Count
                        }
                    } else {
                        New-MirrorStatusCheck -State 'unhealthy' -Reason 'No active managed push webhook matches the expected Worker route.' -CheckedAt $checkedAt -Details @{ expected_url = $webhookUrl; webhook_count = 0 }
                    }
                }
            }
            catch {
                $reason = Get-MirrorStatusErrorReason -Provider 'Bitbucket' -ErrorRecord $_
                if ($null -eq $sourceCheck) { $sourceCheck = New-MirrorStatusCheck -State 'unknown' -Reason $reason -CheckedAt $checkedAt }
                if ($null -eq $webhookCheck) { $webhookCheck = New-MirrorStatusCheck -State 'unknown' -Reason $reason -CheckedAt $checkedAt -Details @{ expected_url = $webhookUrl } }
            }
        }

        try {
            $targetRepository = Get-GitHubRepository -Repository ([string]$mirror.github_repository) -AllowMissing
            if ($null -eq $targetRepository) {
                $targetCheck = New-MirrorStatusCheck -State 'unhealthy' -Reason 'GitHub target repository is missing or inaccessible.' -CheckedAt $checkedAt
            } elseif (-not [bool](Get-MirrorStatusValue -InputObject $targetRepository -Name 'private')) {
                $targetCheck = New-MirrorStatusCheck -State 'unhealthy' -Reason 'GitHub target repository is not private.' -CheckedAt $checkedAt -Details @{
                    url = Get-MirrorStatusValue -InputObject $targetRepository -Name 'html_url'
                    updated_at = Get-MirrorStatusValue -InputObject $targetRepository -Name 'pushed_at'
                }
            } else {
                $targetCheck = New-MirrorStatusCheck -State 'healthy' -Reason 'Private GitHub target repository is accessible.' -CheckedAt $checkedAt -Details @{
                    url = Get-MirrorStatusValue -InputObject $targetRepository -Name 'html_url'
                    updated_at = Get-MirrorStatusValue -InputObject $targetRepository -Name 'pushed_at'
                }
            }
        }
        catch {
            $targetCheck = New-MirrorStatusCheck -State 'unknown' -Reason (Get-MirrorStatusErrorReason -Provider 'GitHub' -ErrorRecord $_) -CheckedAt $checkedAt
        }

        $workerSecretBinding = Get-DerivedWebhookSecretBinding -MirrorId $mirrorId
        if ($cloudflareError) {
            $workerCheck = New-MirrorStatusCheck -State 'unknown' -Reason $cloudflareError -CheckedAt $checkedAt -Details @{
                url = $webhookUrl
                secret_binding = $workerSecretBinding
            }
        } elseif (-not $cloudflareReadiness.deployed) {
            $workerCheck = New-MirrorStatusCheck -State 'unhealthy' -Reason 'Cloudflare Worker is not deployed.' -CheckedAt $checkedAt -Details @{
                url = $webhookUrl
                secret_binding = $workerSecretBinding
            }
        } else {
            $missingForMirror = @(@('GITHUB_APP_PRIVATE_KEY', $workerSecretBinding) | Where-Object { $_ -notin @($cloudflareReadiness.secret_names) })
            $workerCheck = if ($missingForMirror.Count -eq 0) {
                New-MirrorStatusCheck -State 'healthy' -Reason 'Worker is deployed with the required GitHub App and webhook secret bindings.' -CheckedAt $checkedAt -Details @{
                    url = $webhookUrl
                    secret_binding = $workerSecretBinding
                    worker_name = $cloudflareReadiness.worker_name
                }
            } else {
                New-MirrorStatusCheck -State 'unhealthy' -Reason ("Worker is missing required secret binding(s): " + ($missingForMirror -join ', ')) -CheckedAt $checkedAt -Details @{
                    url = $webhookUrl
                    secret_binding = $workerSecretBinding
                    worker_name = $cloudflareReadiness.worker_name
                }
            }
        }

        $mirrorRunName = "Mirror $mirrorId"
        $mirrorRuns = if ($githubRunsError) { @() } else {
            @($workflowRuns | Where-Object { [string](Get-MirrorStatusValue -InputObject $_ -Name 'display_title') -eq $mirrorRunName })
        }
        $latestRun = $mirrorRuns | Select-Object -First 1
        $latestSuccessfulRun = $mirrorRuns | Where-Object {
            [string](Get-MirrorStatusValue -InputObject $_ -Name 'status') -eq 'completed' -and
            [string](Get-MirrorStatusValue -InputObject $_ -Name 'conclusion') -eq 'success'
        } | Select-Object -First 1

        if ($githubRunsError) {
            $actionsCheck = New-MirrorStatusCheck -State 'unknown' -Reason $githubRunsError -CheckedAt $checkedAt
        } elseif ($null -eq $latestRun) {
            $actionsCheck = New-MirrorStatusCheck -State 'unknown' -Reason 'No identifiable GitHub Actions mirror run was found.' -CheckedAt $checkedAt
        } else {
            $runStatus = [string](Get-MirrorStatusValue -InputObject $latestRun -Name 'status')
            $runConclusion = [string](Get-MirrorStatusValue -InputObject $latestRun -Name 'conclusion')
            $runDetails = @{
                url = Get-MirrorStatusValue -InputObject $latestRun -Name 'html_url'
                status = $runStatus
                conclusion = if ([string]::IsNullOrWhiteSpace($runConclusion)) { $null } else { $runConclusion }
                started_at = Get-MirrorStatusValue -InputObject $latestRun -Name 'run_started_at'
                updated_at = Get-MirrorStatusValue -InputObject $latestRun -Name 'updated_at'
                run_number = Get-MirrorStatusValue -InputObject $latestRun -Name 'run_number'
            }
            if ($runStatus -ne 'completed') {
                $actionsCheck = New-MirrorStatusCheck -State 'unknown' -Reason "Latest mirror run is $runStatus." -CheckedAt $checkedAt -Details $runDetails
            } elseif ($runConclusion -eq 'success') {
                $actionsCheck = New-MirrorStatusCheck -State 'healthy' -Reason 'Latest GitHub Actions mirror run succeeded.' -CheckedAt $checkedAt -Details $runDetails
            } else {
                $actionsCheck = New-MirrorStatusCheck -State 'unhealthy' -Reason "Latest GitHub Actions mirror run concluded: $runConclusion." -CheckedAt $checkedAt -Details $runDetails
            }
        }

        $lastSuccessfulSync = if ($null -eq $latestSuccessfulRun) {
            [pscustomobject]@{ completed_at = $null; url = $null; run_number = $null }
        } else {
            [pscustomobject]@{
                completed_at = Get-MirrorStatusValue -InputObject $latestSuccessfulRun -Name 'updated_at'
                url = Get-MirrorStatusValue -InputObject $latestSuccessfulRun -Name 'html_url'
                run_number = Get-MirrorStatusValue -InputObject $latestSuccessfulRun -Name 'run_number'
            }
        }

        $overall = Resolve-MirrorOverallStatus -CheckedAt $checkedAt -Checks @(
            [pscustomobject]@{ Label = 'Bitbucket repository'; Check = $sourceCheck }
            [pscustomobject]@{ Label = 'Bitbucket webhook'; Check = $webhookCheck }
            [pscustomobject]@{ Label = 'Cloudflare Worker'; Check = $workerCheck }
            [pscustomobject]@{ Label = 'GitHub repository'; Check = $targetCheck }
            [pscustomobject]@{ Label = 'GitHub Actions'; Check = $actionsCheck }
        )

        [pscustomobject]@{
            id = $mirrorId
            overall = $overall
            bitbucket_repository = $sourceCheck
            bitbucket_webhook = $webhookCheck
            cloudflare_worker = $workerCheck
            github_repository = $targetCheck
            github_actions = $actionsCheck
            last_successful_sync = $lastSuccessfulSync
        }
    }

    $bitbucketCredentials = $null
    return [pscustomobject]@{
        checked_at = $checkedAt
        mirrors = @($mirrors)
    }
}

Export-ModuleMember -Function New-MirrorStatusCheck, Resolve-MirrorOverallStatus, Get-MirrorStatusSnapshot
