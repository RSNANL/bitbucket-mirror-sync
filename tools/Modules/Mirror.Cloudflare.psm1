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

function Get-CloudflareErrorMessage {
    param([AllowNull()][string]$ResponseBody)

    if ([string]::IsNullOrWhiteSpace($ResponseBody)) { return $null }
    try {
        $parsed = $ResponseBody | ConvertFrom-Json
        $errors = @($parsed.errors)
        if ($errors.Count -gt 0) {
            return ($errors | ForEach-Object {
                $code = if ($null -ne $_.code) { "[$($_.code)] " } else { '' }
                "$code$($_.message)"
            }) -join '; '
        }
    }
    catch { }
    return $null
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
    }
    catch {
        $statusCode = $null
        $responseBody = $null
        if ($null -ne $_.Exception.Response) {
            if ($null -ne $_.Exception.Response.StatusCode) { $statusCode = [int]$_.Exception.Response.StatusCode }
            try {
                if ($null -ne $_.Exception.Response.Content) {
                    $responseBody = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
            }
            catch { }
        }

        if ($AllowMissing -and $statusCode -eq 404) { return $null }
        $providerMessage = Get-CloudflareErrorMessage -ResponseBody $responseBody
        $statusText = if ($null -ne $statusCode) { "HTTP $statusCode" } else { 'transport failure' }
        $detail = if ($providerMessage) { $providerMessage } else { $_.Exception.Message }
        throw "Cloudflare API request failed ($statusText, $Method $Path): $detail"
    }

    if ($response.PSObject.Properties.Name -contains 'success' -and -not $response.success) {
        $messages = @($response.errors | ForEach-Object {
            $code = if ($null -ne $_.code) { "[$($_.code)] " } else { '' }
            "$code$($_.message)"
        }) -join '; '
        throw "Cloudflare API request failed ($Method $Path): $messages"
    }
    return $response
}

function Invoke-CloudflareMultipartApi {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Metadata,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Modules
    )

    $credentials = Get-CloudflareCredentials
    $uri = "https://api.cloudflare.com/client/v4/$Path"
    $client = [Net.Http.HttpClient]::new()
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, $uri)
    $multipart = [Net.Http.MultipartFormDataContent]::new()
    try {
        $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $credentials.Token)
        $client.DefaultRequestHeaders.Accept.Add([Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))

        $metadataContent = [Net.Http.StringContent]::new(
            ($Metadata | ConvertTo-Json -Depth 30 -Compress),
            [Text.Encoding]::UTF8,
            'application/json'
        )
        $multipart.Add($metadataContent, 'metadata')
        foreach ($moduleName in @($Modules.Keys | Sort-Object)) {
            $moduleContent = [Net.Http.StringContent]::new(
                [string]$Modules[$moduleName],
                [Text.Encoding]::UTF8,
                'application/javascript+module'
            )
            $multipart.Add($moduleContent, [string]$moduleName, [string]$moduleName)
        }
        $request.Content = $multipart
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $providerMessage = Get-CloudflareErrorMessage -ResponseBody $responseBody
            $detail = if ($providerMessage) { $providerMessage } else { $response.ReasonPhrase }
            throw "Cloudflare API request failed (HTTP $([int]$response.StatusCode), PUT $Path): $detail"
        }
        $parsed = $responseBody | ConvertFrom-Json
        if ($parsed.PSObject.Properties.Name -contains 'success' -and -not $parsed.success) {
            $messages = @($parsed.errors | ForEach-Object {
                $code = if ($null -ne $_.code) { "[$($_.code)] " } else { '' }
                "$code$($_.message)"
            }) -join '; '
            throw "Cloudflare API request failed (PUT $Path): $messages"
        }
        return $parsed
    }
    finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Test-CloudflareAuthentication {
    $credentials = Get-CloudflareCredentials
    [void](Invoke-CloudflareApi -Method GET -Path "accounts/$($credentials.AccountId)/workers/scripts")
    return $true
}

function Get-CloudflareWorkerSecrets {
    param(
        [string]$WorkerConfig = 'worker/wrangler.jsonc',
        [switch]$AllowMissing
    )

    $credentials = Get-CloudflareCredentials
    $workerName = Get-CloudflareWorkerName -WorkerConfig $WorkerConfig
    $response = Invoke-CloudflareApi -Method GET -Path "accounts/$($credentials.AccountId)/workers/scripts/$workerName/secrets" -AllowMissing:$AllowMissing
    if ($null -eq $response) { return @() }
    return @($response.result)
}

function Test-CloudflareWorkerDeployment {
    param([string]$WorkerConfig = 'worker/wrangler.jsonc')

    $credentials = Get-CloudflareCredentials
    $workerName = Get-CloudflareWorkerName -WorkerConfig $WorkerConfig
    $response = Invoke-CloudflareApi -Method GET -Path "accounts/$($credentials.AccountId)/workers/scripts/$workerName/settings" -AllowMissing
    return $null -ne $response
}

function Assert-CloudflareWorkerReady {
    param(
        [string[]]$RequiredSecretNames = @('GITHUB_APP_PRIVATE_KEY'),
        [string]$WorkerConfig = 'worker/wrangler.jsonc'
    )

    $workerName = Get-CloudflareWorkerName -WorkerConfig $WorkerConfig
    if (-not (Test-CloudflareWorkerDeployment -WorkerConfig $WorkerConfig)) {
        throw "Cloudflare Worker is not deployed: $workerName. Run .\tools\Deploy-MirrorWorker.ps1 before provisioning a mirror."
    }
    $secretNames = @(Get-CloudflareWorkerSecrets -WorkerConfig $WorkerConfig | ForEach-Object { [string]$_.name })
    foreach ($secretName in $RequiredSecretNames) {
        if ($secretName -notin $secretNames) {
            throw "Cloudflare Worker is missing required secret binding: $secretName"
        }
    }
    return $true
}

function Publish-CloudflareWorker {
    param(
        [string]$ConfigPath = 'config/mirrors.json',
        [string]$WorkerConfig = 'worker/wrangler.jsonc'
    )

    $root = Get-RepositoryRoot
    $workerConfigPath = if ([IO.Path]::IsPathRooted($WorkerConfig)) { $WorkerConfig } else { Join-Path $root $WorkerConfig }
    $mirrorConfigPath = if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $root $ConfigPath }
    $wrangler = Get-Content -LiteralPath $workerConfigPath -Raw | ConvertFrom-Json
    $mirrorConfig = Get-Content -LiteralPath $mirrorConfigPath -Raw
    $workerName = Get-CloudflareWorkerName -WorkerConfig $WorkerConfig
    $credentials = Get-CloudflareCredentials
    $sourceDirectory = Join-Path $root 'worker/src'
    $indexSource = Get-Content -LiteralPath (Join-Path $sourceDirectory 'index.js') -Raw
    $indexSource = $indexSource.Replace(
        'import mirrorConfig from "../../config/mirrors.json" with { type: "json" };',
        'import mirrorConfig from "./mirror-config.js";'
    )
    $modules = [ordered]@{
        'index.js' = $indexSource
        'handler.js' = Get-Content -LiteralPath (Join-Path $sourceDirectory 'handler.js') -Raw
        'crypto.js' = Get-Content -LiteralPath (Join-Path $sourceDirectory 'crypto.js') -Raw
        'github-app.js' = Get-Content -LiteralPath (Join-Path $sourceDirectory 'github-app.js') -Raw
        'mirror-config.js' = "export default $($mirrorConfig.Trim());`n"
    }
    $existingSecrets = @(Get-CloudflareWorkerSecrets -WorkerConfig $WorkerConfig -AllowMissing)
    $bindings = @($existingSecrets | ForEach-Object { @{ name = [string]$_.name; type = 'inherit' } })
    $metadata = @{
        main_module = 'index.js'
        compatibility_date = [string]$wrangler.compatibility_date
        observability = $wrangler.observability
        bindings = $bindings
    }
    $path = "accounts/$($credentials.AccountId)/workers/scripts/$workerName"
    if ($bindings.Count -gt 0) { $path += '?bindings_inherit=strict' }
    [void](Invoke-CloudflareMultipartApi -Path $path -Metadata $metadata -Modules $modules)

    if ($wrangler.workers_dev) {
        [void](Invoke-CloudflareApi -Method POST -Path "accounts/$($credentials.AccountId)/workers/scripts/$workerName/subdomain" -Body @{
            enabled = $true
            previews_enabled = $false
        })
    }
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
    [void](Invoke-CloudflareApi -Method DELETE -Path "accounts/$($credentials.AccountId)/workers/scripts/$workerName/secrets/$encodedSecretName" -AllowMissing)
}

Export-ModuleMember -Function Get-CloudflareCredentials, Get-CloudflareWorkerName, Invoke-CloudflareApi, Test-CloudflareAuthentication, Get-CloudflareWorkerSecrets, Test-CloudflareWorkerDeployment, Assert-CloudflareWorkerReady, Publish-CloudflareWorker, Set-CloudflareWorkerSecret, Remove-CloudflareWorkerSecret
