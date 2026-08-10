Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force

function Get-BitbucketCredentials {
    $token = [Environment]::GetEnvironmentVariable('MIRROR_SESSION_BITBUCKET_TOKEN', 'Process')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Bitbucket is not authenticated for this management session. Run .\tools\Connect-MirrorSession.ps1.'
    }
    return [pscustomobject]@{ Token = $token }
}

function Get-BitbucketAuthorizationHeaders {
    param([Parameter(Mandatory)][object]$Credentials)

    if ([string]::IsNullOrWhiteSpace([string]$Credentials.Token)) {
        throw 'A Bitbucket management-session access token is required.'
    }
    return @{
        Authorization = "Bearer $($Credentials.Token)"
        Accept = 'application/json'
    }
}

function Invoke-BitbucketApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Credentials,
        [AllowNull()][object]$Body = $null,
        [switch]$AllowMissing
    )

    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://api.bitbucket.org/2.0/$Path" }
    $headers = Get-BitbucketAuthorizationHeaders -Credentials $Credentials
    try {
        $parameters = @{
            Method = $Method
            Uri = $uri
            Headers = $headers
        }
        if ($null -ne $Body) {
            $parameters['ContentType'] = 'application/json'
            $parameters['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
        }
        return Invoke-RestMethod @parameters
    }
    catch {
        $statusCode = $null
        if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($AllowMissing -and $statusCode -eq 404) { return $null }
        throw
    }
}

function Get-BitbucketPagedValues {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Credentials
    )

    $values = @()
    $next = if ($Path.Contains('?')) { "${Path}&pagelen=100" } else { "${Path}?pagelen=100" }
    while ($next) {
        $response = Invoke-BitbucketApi -Method GET -Path $next -Credentials $Credentials
        $values += @($response.values)
        $next = if ($response.PSObject.Properties.Name -contains 'next') { $response.next } else { $null }
    }
    return $values
}

function Get-BitbucketRepository {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][object]$Credentials,
        [switch]$AllowMissing
    )
    return Invoke-BitbucketApi -Method GET -Path "repositories/$Repository" -Credentials $Credentials -AllowMissing:$AllowMissing
}

function Get-BitbucketLatestCommit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Revision,
        [Parameter(Mandatory)][object]$Credentials
    )

    $encodedRevision = [Uri]::EscapeDataString($Revision)
    $response = Invoke-BitbucketApi `
        -Method GET `
        -Path "repositories/$Repository/commits/${encodedRevision}?pagelen=1" `
        -Credentials $Credentials
    return @($response.values) | Select-Object -First 1
}

function Get-BitbucketDeployKeys {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][object]$Credentials
    )
    return Get-BitbucketPagedValues -Path "repositories/$Repository/deploy-keys" -Credentials $Credentials
}

function New-BitbucketDeployKey {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$PublicKey,
        [Parameter(Mandatory)][object]$Credentials
    )
    return Invoke-BitbucketApi -Method POST -Path "repositories/$Repository/deploy-keys" -Credentials $Credentials -Body @{
        label = $Label
        key = $PublicKey
    }
}

function Remove-BitbucketDeployKey {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$KeyId,
        [Parameter(Mandatory)][object]$Credentials
    )
    [void](Invoke-BitbucketApi -Method DELETE -Path "repositories/$Repository/deploy-keys/$KeyId" -Credentials $Credentials)
}

function Get-BitbucketWebhooks {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][object]$Credentials
    )
    return Get-BitbucketPagedValues -Path "repositories/$Repository/hooks" -Credentials $Credentials
}

function Get-BitbucketMirrorWebhooks {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$MirrorId,
        [Parameter(Mandatory)][string]$ExpectedUrl,
        [Parameter(Mandatory)][object]$Credentials
    )

    $description = "mirror:$MirrorId"
    return @(Get-BitbucketWebhooks -Repository $Repository -Credentials $Credentials | Where-Object {
        $_.description -eq $description -and
        $_.active -and
        $_.url -eq $ExpectedUrl -and
        'repo:push' -in @($_.events)
    })
}

function New-BitbucketWebhook {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][object]$Credentials
    )
    return Invoke-BitbucketApi -Method POST -Path "repositories/$Repository/hooks" -Credentials $Credentials -Body @{
        description = $Description
        url = $Url
        active = $true
        secret = $Secret
        events = @('repo:push')
    }
}

function Remove-BitbucketWebhook {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$WebhookId,
        [Parameter(Mandatory)][object]$Credentials
    )
    $encoded = [Uri]::EscapeDataString($WebhookId)
    [void](Invoke-BitbucketApi -Method DELETE -Path "repositories/$Repository/hooks/$encoded" -Credentials $Credentials)
}

Export-ModuleMember -Function Get-BitbucketCredentials, Invoke-BitbucketApi, Get-BitbucketRepository, Get-BitbucketLatestCommit, Get-BitbucketDeployKeys, New-BitbucketDeployKey, Remove-BitbucketDeployKey, Get-BitbucketWebhooks, Get-BitbucketMirrorWebhooks, New-BitbucketWebhook, Remove-BitbucketWebhook
