Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force

function Get-CloudflareCredentials {
    $token = [Environment]::GetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_TOKEN', 'Process')
    $accountId = [Environment]::GetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_ACCOUNT_ID', 'Process')
    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($accountId)) {
        throw 'Cloudflare is not authenticated for this management session. Run .\tools\Connect-MirrorSession.ps1.'
    }
    return [pscustomobject]@{
        AccountId = $accountId
        Token = $token
    }
}

function Get-CloudflareWorkerName {
    param([string]$WorkerConfig = 'worker/wrangler.jsonc')

    $root = Get-RepositoryRoot
    $configPath = Join-Path $root $WorkerConfig
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Cloudflare Worker configuration was not found: $configPath"
    }

    try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
    catch { throw "Cloudflare Worker configuration is not valid JSON: $configPath`n$($_.Exception.Message)" }

    $workerName = [string]$config.name
    if ([string]::IsNullOrWhiteSpace($workerName)) {
        throw "Cloudflare Worker configuration does not define a worker name: $configPath"
    }
    return $workerName
}

function Invoke-CloudflareApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Body = $null,
        [switch]$AllowMissing
    )

    $credentials = Get-CloudflareCredentials
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://api.cloudflare.com/client/v4/$Path" }
    $headers = @{
        Authorization = "Bearer $($credentials.Token)"
        Accept = 'application/json'
    }

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

        $response = Invoke-RestMethod @parameters
        if ($response.PSObject.Properties.Name -contains 'success' -and -not $response.success) {
            $messages = @($response.errors | ForEach-Object { $_.message }) -join '; '
            throw "Cloudflare API request failed: $messages"
        }
        return $response
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

function Test-CloudflareAuthentication {
    $credentials = Get-CloudflareCredentials
    [void](Invoke-CloudflareApi -Method GET -Path "accounts/$($credentials.AccountId)/workers/scripts")
    return $true
}

function Set-CloudflareWorkerSecret {
    param(
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue,
        [string]$WorkerConfig = 'worker/wrangler.jsonc'
    )

    $credentials = Get-CloudflareCredentials
    $workerName = Get-CloudflareWorkerName -WorkerConfig $WorkerConfig
    [void](Invoke-CloudflareApi -Method PUT -Path "accounts/$($credentials.AccountId)/workers/scripts/$workerName/secrets" -Body @{
        name = $SecretName
        text = $SecretValue
        type = 'secret_text'
    })
}

function Remove-CloudflareWorkerSecret {
    param(
        [Parameter(Mandatory)][string]$SecretName,
        [string]$WorkerConfig = 'worker/wrangler.jsonc'
    )

    $credentials = Get-CloudflareCredentials
    $workerName = Get-CloudflareWorkerName -WorkerConfig $WorkerConfig
    $encodedSecretName = [Uri]::EscapeDataString($SecretName)
    [void](Invoke-CloudflareApi -Method DELETE -Path "accounts/$($credentials.AccountId)/workers/scripts/$workerName/secrets/$encodedSecretName")
}

Export-ModuleMember -Function Get-CloudflareCredentials, Invoke-CloudflareApi, Test-CloudflareAuthentication, Set-CloudflareWorkerSecret, Remove-CloudflareWorkerSecret
