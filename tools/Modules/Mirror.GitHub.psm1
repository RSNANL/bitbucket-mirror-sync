Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force

function Get-GitHubSessionToken {
    $token = [Environment]::GetEnvironmentVariable('MIRROR_SESSION_GITHUB_TOKEN', 'Process')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'GitHub is not authenticated for this management session. Run .\tools\Connect-MirrorSession.ps1.'
    }
    [Environment]::SetEnvironmentVariable('GH_TOKEN', $token, 'Process')
    return $token
}

function Test-GitHubAuthentication {
    [void](Get-GitHubSessionToken)
    $result = Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList @('api', 'user') -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw 'GitHub management session authentication is no longer valid.'
    }
    return $true
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        [AllowNull()][object]$Body = $null,
        [switch]$AllowFailure
    )

    [void](Get-GitHubSessionToken)
    $arguments = @('api', '--method', $Method, $Endpoint)
    $inputText = $null
    if ($null -ne $Body) {
        $arguments += @('--input', '-')
        $inputText = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    $result = Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList $arguments -InputText $inputText -AllowFailure:$AllowFailure
    if ($result.ExitCode -ne 0) { return $null }
    if (-not $result.StdOut) { return $null }
    return $result.StdOut | ConvertFrom-Json -AsHashtable
}

function Get-GitHubRepository {
    param([Parameter(Mandatory)][string]$Repository, [switch]$AllowMissing)
    $result = Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository" -AllowFailure:$AllowMissing
    if ($null -eq $result -and -not $AllowMissing) { throw "GitHub repository not found: $Repository" }
    return $result
}

function New-GitHubMirrorRepository {
    param([Parameter(Mandatory)][string]$Repository)
    [void](Get-GitHubSessionToken)
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList @(
        'repo', 'create', $Repository, '--private', '--disable-issues', '--disable-wiki'
    ))
    return Get-GitHubRepository -Repository $Repository
}

function Remove-GitHubRepository {
    param([Parameter(Mandatory)][string]$Repository)
    [void](Get-GitHubSessionToken)
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList @(
        'repo', 'delete', $Repository, '--yes'
    ))
}

function Get-GitHubDeployKeys {
    param([Parameter(Mandatory)][string]$Repository)
    $result = Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/keys?per_page=100"
    return @($result)
}

function New-GitHubDeployKey {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$PublicKey,
        [bool]$ReadOnly = $false
    )
    return Invoke-GitHubApi -Method POST -Endpoint "repos/$Repository/keys" -Body @{
        title = $Title
        key = $PublicKey
        read_only = $ReadOnly
    }
}

function Remove-GitHubDeployKey {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][long]$KeyId)
    [void](Invoke-GitHubApi -Method DELETE -Endpoint "repos/$Repository/keys/$KeyId")
}

function New-GitHubEnvironment {
    param(
        [Parameter(Mandatory)][string]$InfrastructureRepository,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    $encoded = [Uri]::EscapeDataString($EnvironmentName)
    return Invoke-GitHubApi -Method PUT -Endpoint "repos/$InfrastructureRepository/environments/$encoded" -Body @{}
}

function Remove-GitHubEnvironment {
    param(
        [Parameter(Mandatory)][string]$InfrastructureRepository,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    $encoded = [Uri]::EscapeDataString($EnvironmentName)
    [void](Invoke-GitHubApi -Method DELETE -Endpoint "repos/$InfrastructureRepository/environments/$encoded")
}

function Set-GitHubEnvironmentSecret {
    param(
        [Parameter(Mandatory)][string]$InfrastructureRepository,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue
    )
    [void](Get-GitHubSessionToken)
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList @(
        'secret', 'set', $SecretName,
        '--env', $EnvironmentName,
        '--repo', $InfrastructureRepository
    ) -InputText $SecretValue)
}

function Get-GitHubEnvironmentSecrets {
    param(
        [Parameter(Mandatory)][string]$InfrastructureRepository,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    [void](Get-GitHubSessionToken)
    $result = Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList @(
        'secret', 'list', '--env', $EnvironmentName, '--repo', $InfrastructureRepository, '--json', 'name,updatedAt'
    )
    if (-not $result.StdOut) { return @() }
    return @($result.StdOut | ConvertFrom-Json -AsHashtable)
}

function Start-GitHubMirrorWorkflow {
    param(
        [Parameter(Mandatory)][string]$InfrastructureRepository,
        [Parameter(Mandatory)][string]$WorkflowFile,
        [Parameter(Mandatory)][string]$MirrorId,
        [string]$Ref = 'main'
    )
    [void](Get-GitHubSessionToken)
    [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList @(
        'workflow', 'run', $WorkflowFile,
        '--repo', $InfrastructureRepository,
        '--ref', $Ref,
        '--field', "mirror_id=$MirrorId"
    ))
}

Export-ModuleMember -Function Test-GitHubAuthentication, Invoke-GitHubApi, Get-GitHubRepository, New-GitHubMirrorRepository, Remove-GitHubRepository, Get-GitHubDeployKeys, New-GitHubDeployKey, Remove-GitHubDeployKey, New-GitHubEnvironment, Remove-GitHubEnvironment, Set-GitHubEnvironmentSecret, Get-GitHubEnvironmentSecrets, Start-GitHubMirrorWorkflow
