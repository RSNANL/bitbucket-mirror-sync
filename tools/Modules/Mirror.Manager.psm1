Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Mirror.Config.psm1') -Force

function Get-MirrorManagerOperationDefinition {
    param([Parameter(Mandatory)][string]$Action)

    $definitions = @{
        'connect-provider' = @{ Script = 'Connect-MirrorProvider.ps1'; Required = @('Provider'); Switches = @(); Optional = @('BitbucketClientSecret') }
        'disconnect-session' = @{ Script = 'Disconnect-MirrorSession.ps1'; Required = @(); Switches = @(); Optional = @() }
        'refresh-status' = @{ Script = 'Get-MirrorStatus.ps1'; Required = @(); Switches = @(); Optional = @() }
        'validate' = @{ Script = 'Test-Mirror.ps1'; Required = @('MirrorId'); Switches = @(); Optional = @() }
        'dispatch' = @{ Script = 'Test-Mirror.ps1'; Required = @('MirrorId'); Switches = @('Dispatch'); Optional = @() }
        'validate-sync' = @{ Script = 'Test-Mirror.ps1'; Required = @('MirrorId', 'SourceRepositoryPath'); Switches = @('ValidateSync'); Optional = @('SyncTimeoutSeconds') }
        'new-mirror' = @{ Script = 'New-Mirror.ps1'; Required = @('MirrorId', 'BitbucketRepository', 'GitHubRepository'); Switches = @('UseExistingTarget', 'ScheduledRecovery', 'Apply'); Optional = @('WorkerBaseUrl') }
        'remove-mirror' = @{ Script = 'Remove-Mirror.ps1'; Required = @('MirrorId'); Switches = @('DeleteTargetRepository', 'Apply'); Optional = @() }
        'repair-mirror' = @{ Script = 'Repair-Mirror.ps1'; Required = @('MirrorId'); Switches = @('RepairWebhook'); Optional = @() }
        'rotate-keys' = @{ Script = 'Rotate-MirrorKeys.ps1'; Required = @('MirrorId', 'Phase'); Switches = @(); Optional = @() }
        'deploy-worker' = @{ Script = 'Deploy-MirrorWorker.ps1'; Required = @(); Switches = @('Apply'); Optional = @('GitHubAppId', 'GitHubAppInstallationId', 'GitHubAppPrivateKeyPath') }
        'set-mirror' = @{ Script = 'Set-Mirror.ps1'; Required = @('MirrorId', 'Setting', 'Value'); Switches = @('Apply'); Optional = @() }
    }
    if (-not $definitions.ContainsKey($Action)) { throw "Unsupported Mirror Manager action: $Action" }
    return $definitions[$Action]
}

function Test-MirrorManagerMutatingAction {
    param([Parameter(Mandatory)][string]$Action)
    return $Action -in @(
        'connect-provider', 'disconnect-session', 'new-mirror', 'remove-mirror',
        'repair-mirror', 'rotate-keys', 'deploy-worker', 'set-mirror'
    )
}

function ConvertTo-MirrorManagerParameters {
    param(
        [Parameter(Mandatory)][string]$Action,
        [AllowNull()][Collections.IDictionary]$Arguments
    )

    $definition = Get-MirrorManagerOperationDefinition -Action $Action
    $inputArguments = if ($null -eq $Arguments) { @{} } else { $Arguments }
    $allowed = @($definition.Required) + @($definition.Optional) + @($definition.Switches)
    $unexpected = @($inputArguments.Keys | Where-Object { [string]$_ -notin $allowed })
    if ($unexpected.Count -gt 0) { throw "Unsupported argument(s) for ${Action}: $($unexpected -join ', ')" }

    $parameters = @{}
    foreach ($name in @($definition.Required)) {
        if (-not $inputArguments.Contains($name) -or $null -eq $inputArguments[$name] -or [string]::IsNullOrWhiteSpace([string]$inputArguments[$name])) {
            throw "Action '$Action' requires argument '$name'."
        }
        $parameters[$name] = $inputArguments[$name]
    }
    foreach ($name in @($definition.Optional)) {
        if ($inputArguments.Contains($name) -and $null -ne $inputArguments[$name] -and -not [string]::IsNullOrWhiteSpace([string]$inputArguments[$name])) {
            $parameters[$name] = $inputArguments[$name]
        }
    }
    foreach ($name in @($definition.Switches)) {
        if ($inputArguments.Contains($name) -and [bool]$inputArguments[$name]) { $parameters[$name] = $true }
    }

    return $parameters
}

function Get-MirrorManagerInvocation {
    param(
        [Parameter(Mandatory)][string]$Action,
        [AllowNull()][Collections.IDictionary]$Arguments
    )

    $definition = Get-MirrorManagerOperationDefinition -Action $Action
    $root = Get-RepositoryRoot
    return [pscustomobject]@{
        Action = $Action
        ScriptPath = Join-Path (Join-Path $root 'tools') $definition.Script
        Parameters = ConvertTo-MirrorManagerParameters -Action $Action -Arguments $Arguments
    }
}

function Get-MirrorManagerSnapshot {
    param(
        [string]$ConfigPath = 'config/mirrors.json',
        [AllowNull()][object]$StatusSnapshot = $null,
        [bool]$StatusIsStale = $true
    )

    $config = Get-MirrorConfiguration -ConfigPath $ConfigPath
    $providers = foreach ($provider in @('GitHub', 'Cloudflare', 'Bitbucket')) {
        $tokenName = "MIRROR_SESSION_$($provider.ToUpperInvariant())_TOKEN"
        $expiryName = "MIRROR_SESSION_$($provider.ToUpperInvariant())_EXPIRES_AT"
        $expiryValue = [Environment]::GetEnvironmentVariable($expiryName, 'Process')
        [pscustomobject]@{
            id = $provider.ToLowerInvariant()
            authenticated = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($tokenName, 'Process'))
            expires_at = if ($expiryValue) { $expiryValue } else { $null }
        }
    }

    return [pscustomobject]@{
        worker = $config.worker
        dispatch = $config.dispatch
        mirrors = @($config.mirrors)
        providers = @($providers)
        status = [pscustomobject]@{
            checked_at = if ($null -eq $StatusSnapshot) { $null } else { $StatusSnapshot.checked_at }
            is_stale = $StatusIsStale
            mirrors = if ($null -eq $StatusSnapshot) { @() } else { @($StatusSnapshot.mirrors) }
        }
    }
}

Export-ModuleMember -Function Get-MirrorManagerOperationDefinition, Test-MirrorManagerMutatingAction, ConvertTo-MirrorManagerParameters, Get-MirrorManagerInvocation, Get-MirrorManagerSnapshot
