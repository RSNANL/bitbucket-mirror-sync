Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force

$script:CloudflareRedirectUri = 'http://127.0.0.1:53682/callback'
$script:CloudflareOAuthScopes = @('workers-scripts.read', 'workers-scripts.write')
$script:BitbucketRedirectUri = 'http://127.0.0.1:53683/callback'

$script:SessionVariables = @(
    'MIRROR_SESSION_GITHUB_TOKEN',
    'MIRROR_SESSION_GITHUB_EXPIRES_AT',
    'MIRROR_SESSION_CLOUDFLARE_TOKEN',
    'MIRROR_SESSION_CLOUDFLARE_ACCOUNT_ID',
    'MIRROR_SESSION_CLOUDFLARE_EXPIRES_AT',
    'MIRROR_SESSION_BITBUCKET_TOKEN',
    'MIRROR_SESSION_BITBUCKET_EXPIRES_AT',
    'GH_TOKEN'
)

function Get-MirrorAuthenticationConfiguration {
    param([string]$ConfigPath = 'config/authentication.json')

    $root = Get-RepositoryRoot
    $absolutePath = if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $root $ConfigPath }
    if (-not (Test-Path -LiteralPath $absolutePath)) {
        throw "Authentication configuration was not found: $absolutePath"
    }

    try {
        $config = Get-Content -LiteralPath $absolutePath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Authentication configuration is not valid JSON: $absolutePath`n$($_.Exception.Message)"
    }

    return $config
}

function Assert-ExactConfigurationProperties {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$ExpectedProperties,
        [Parameter(Mandatory)][string]$Label
    )

    $actualProperties = @($Object.PSObject.Properties.Name)
    $missing = @($ExpectedProperties | Where-Object { $_ -notin $actualProperties })
    $unexpected = @($actualProperties | Where-Object { $_ -notin $ExpectedProperties })
    if ($missing.Count -gt 0) {
        throw "$Label is missing field(s): $($missing -join ', ')."
    }
    if ($unexpected.Count -gt 0) {
        throw "$Label contains unsupported field(s): $($unexpected -join ', ')."
    }
}

function Test-MirrorAuthenticationConfiguration {
    param(
        [string]$ConfigPath = 'config/authentication.json',
        [switch]$RequireConfigured
    )

    $config = Get-MirrorAuthenticationConfiguration -ConfigPath $ConfigPath
    Assert-ExactConfigurationProperties -Object $config -ExpectedProperties @('github', 'cloudflare', 'bitbucket') -Label 'Authentication configuration'
    foreach ($provider in @('github', 'cloudflare', 'bitbucket')) {
        if ($null -eq $config.$provider -or $config.$provider -is [Array]) {
            throw "Authentication configuration provider must be an object: $provider"
        }
    }
    Assert-ExactConfigurationProperties -Object $config.github -ExpectedProperties @('client_id') -Label 'github'
    Assert-ExactConfigurationProperties -Object $config.cloudflare -ExpectedProperties @('client_id', 'account_id') -Label 'cloudflare'
    Assert-ExactConfigurationProperties -Object $config.bitbucket -ExpectedProperties @('client_id') -Label 'bitbucket'

    foreach ($clientId in @($config.github.client_id, $config.cloudflare.client_id, $config.bitbucket.client_id)) {
        if ($null -ne $clientId -and ($clientId -isnot [string] -or [string]::IsNullOrWhiteSpace($clientId))) {
            throw 'Authentication client IDs must be null or non-empty strings.'
        }
    }

    if (
        $null -ne $config.cloudflare.account_id -and
        (
            $config.cloudflare.account_id -isnot [string] -or
            ([string]$config.cloudflare.account_id) -notmatch '^[A-Fa-f0-9]{32}$'
        )
    ) {
        throw 'cloudflare.account_id must be a 32-character hexadecimal identifier.'
    }

    if ($RequireConfigured) {
        if ([string]::IsNullOrWhiteSpace([string]$config.github.client_id)) {
            throw 'github.client_id is not configured.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$config.cloudflare.client_id)) {
            throw 'cloudflare.client_id is not configured.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$config.cloudflare.account_id)) {
            throw 'cloudflare.account_id is not configured.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$config.bitbucket.client_id)) {
            throw 'bitbucket.client_id is not configured.'
        }
    }

    return $true
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-RandomBase64Url {
    param([int]$ByteLength = 32)
    $bytes = [byte[]]::new($ByteLength)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ConvertTo-Base64Url -Bytes $bytes
}

function New-PkceValues {
    $verifier = New-RandomBase64Url -ByteLength 48
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier))
    return [pscustomobject]@{
        Verifier = $verifier
        Challenge = ConvertTo-Base64Url -Bytes $hash
    }
}

function ConvertTo-QueryString {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)

    $pairs = foreach ($entry in $Values.GetEnumerator()) {
        if ($null -eq $entry.Value -or [string]::IsNullOrWhiteSpace([string]$entry.Value)) { continue }
        '{0}={1}' -f [Uri]::EscapeDataString([string]$entry.Key), [Uri]::EscapeDataString([string]$entry.Value)
    }
    return $pairs -join '&'
}

function ConvertFrom-QueryString {
    param([string]$Query)

    $result = @{}
    $trimmed = if ($Query) { $Query.TrimStart('?') } else { '' }
    if (-not $trimmed) { return $result }

    foreach ($part in $trimmed.Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $pieces = $part.Split('=', 2)
        $key = [Uri]::UnescapeDataString($pieces[0].Replace('+', ' '))
        $value = if ($pieces.Count -gt 1) { [Uri]::UnescapeDataString($pieces[1].Replace('+', ' ')) } else { '' }
        $result[$key] = $value
    }
    return $result
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-HttpFailureDetail {
    param([Parameter(Mandatory)][object]$ErrorRecord)

    $statusCode = $null
    $body = $null
    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response) {
        if ($null -ne $response.StatusCode) { $statusCode = [int]$response.StatusCode }
        try {
            if ($null -ne $response.Content) {
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        }
        catch { }
    }

    $parts = @()
    if ($null -ne $statusCode) { $parts += "HTTP $statusCode" }
    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json
            $oauthError = [string](Get-OptionalPropertyValue -Object $parsed -Name 'error')
            $oauthDescription = [string](Get-OptionalPropertyValue -Object $parsed -Name 'error_description')
            if ($oauthDescription) { $parts += $oauthDescription }
            elseif ($oauthError) { $parts += $oauthError }
        }
        catch { }
    }
    if ($parts.Count -eq 0) { $parts += $ErrorRecord.Exception.Message }
    return $parts -join ': '
}

function Write-ManagerAuthorization {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$AuthorizationUri,
        [AllowNull()][string]$UserCode
    )

    $payload = [ordered]@{
        provider = $Provider.ToLowerInvariant()
        authorization_uri = $AuthorizationUri
        user_code = if ([string]::IsNullOrWhiteSpace($UserCode)) { $null } else { $UserCode }
    } | ConvertTo-Json -Compress
    Write-Host "MIRROR_MANAGER_AUTHORIZATION:$payload"
}

function Open-ProviderAuthorization {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$NoBrowser
    )
    if ($NoBrowser) { return }
    Write-Host 'Opening provider authorization in your browser...'
    Start-Process $Uri
}

function Receive-LoopbackOAuthCode {
    param(
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$ExpectedState,
        [Parameter(Mandatory)][string]$AuthorizationUri,
        [switch]$NoBrowser,
        [int]$TimeoutSeconds = 300
    )

    $redirect = [Uri]$RedirectUri
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $redirect.Port)
    $client = $null
    $reader = $null
    $stream = $null
    $errorMessage = $null
    $code = $null

    $listener.Start()
    try {
        Open-ProviderAuthorization -Uri $AuthorizationUri -NoBrowser:$NoBrowser
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $listener.Pending()) {
            if ([DateTimeOffset]::UtcNow -ge $deadline) {
                throw "OAuth callback timed out after $TimeoutSeconds seconds."
            }
            Start-Sleep -Milliseconds 200
        }

        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
        $requestLine = $reader.ReadLine()
        while ($reader.ReadLine()) { }

        if ($requestLine -notmatch '^GET\s+(\S+)\s+HTTP/') {
            $errorMessage = 'Unexpected OAuth callback request.'
        }
        else {
            $target = $Matches[1]
            $callbackUri = [Uri]("http://127.0.0.1:$($redirect.Port)$target")
            if ($callbackUri.AbsolutePath -ne $redirect.AbsolutePath) {
                $errorMessage = 'OAuth callback path did not match the configured redirect URI.'
            }
            else {
                $parameters = ConvertFrom-QueryString -Query $callbackUri.Query
                if ($parameters.ContainsKey('error')) {
                    $detail = if ($parameters.ContainsKey('error_description')) { $parameters['error_description'] } else { $parameters['error'] }
                    $errorMessage = "Provider authorization failed: $detail"
                }
                elseif (-not $parameters.ContainsKey('state') -or $parameters['state'] -ne $ExpectedState) {
                    $errorMessage = 'OAuth callback state validation failed.'
                }
                elseif (-not $parameters.ContainsKey('code') -or [string]::IsNullOrWhiteSpace($parameters['code'])) {
                    $errorMessage = 'OAuth callback did not contain an authorization code.'
                }
                else {
                    $code = $parameters['code']
                }
            }
        }

        $html = if ($errorMessage) {
            '<!doctype html><html><body><h2>Authorization failed</h2><p>This window can be closed.</p></body></html>'
        } else {
            '<!doctype html><html><body><h2>Authorization complete</h2><p>This window closes automatically.</p><script>window.close()</script></body></html>'
        }
        $body = [Text.Encoding]::UTF8.GetBytes($html)
        $headers = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($headers)
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($body, 0, $body.Length)
        $stream.Flush()
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }
        $listener.Stop()
    }

    if ($errorMessage) { throw $errorMessage }
    return $code
}

function Test-PersistentGitHubCredential {
    if (-not (Test-ExternalCommand 'gh')) { return $false }

    $originalGhToken = [Environment]::GetEnvironmentVariable('GH_TOKEN', 'Process')
    $originalGitHubToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('GH_TOKEN', $null, 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $null, 'Process')
        $result = Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand gh) -ArgumentList @('auth', 'status', '--hostname', 'github.com') -AllowFailure
        return $result.ExitCode -eq 0
    }
    finally {
        [Environment]::SetEnvironmentVariable('GH_TOKEN', $originalGhToken, 'Process')
        [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $originalGitHubToken, 'Process')
    }
}

function Test-MirrorSession {
    [CmdletBinding()]
    param([switch]$ThrowOnFailure)

    $required = @(
        'MIRROR_SESSION_GITHUB_TOKEN',
        'MIRROR_SESSION_CLOUDFLARE_TOKEN',
        'MIRROR_SESSION_CLOUDFLARE_ACCOUNT_ID',
        'MIRROR_SESSION_BITBUCKET_TOKEN'
    )
    $missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_, 'Process')) })

    foreach ($expiryVariable in @(
        'MIRROR_SESSION_GITHUB_EXPIRES_AT',
        'MIRROR_SESSION_CLOUDFLARE_EXPIRES_AT',
        'MIRROR_SESSION_BITBUCKET_EXPIRES_AT'
    )) {
        $value = [Environment]::GetEnvironmentVariable($expiryVariable, 'Process')
        if ($value) {
            try { $expiry = [DateTimeOffset]::Parse($value) }
            catch { $missing += "$expiryVariable (invalid)"; continue }
            if ($expiry -le [DateTimeOffset]::UtcNow) { $missing += "$expiryVariable (expired)" }
        }
    }

    if ($missing.Count -gt 0) {
        if ($ThrowOnFailure) {
            throw "No valid mirror management session is active. Run .\tools\Connect-MirrorSession.ps1. Missing or expired: $($missing -join ', ')."
        }
        return $false
    }
    return $true
}

function Connect-GitHubSession {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [switch]$NoBrowser
    )

    if (Test-PersistentGitHubCredential) {
        throw 'Persistent GitHub CLI authentication is present. Run `gh auth logout --hostname github.com` once, then start the mirror management session again.'
    }
    if ([Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'Process')) {
        throw 'GITHUB_TOKEN is set in the current process. Remove it before starting an interactive mirror management session.'
    }

    $clientId = [string]$Configuration.github.client_id
    $device = Invoke-RestMethod -Method POST -Uri 'https://github.com/login/device/code' -Headers @{ Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{ client_id = $clientId }
    $deviceCode = [string](Get-OptionalPropertyValue -Object $device -Name 'device_code')
    $userCode = [string](Get-OptionalPropertyValue -Object $device -Name 'user_code')
    $verificationUri = [string](Get-OptionalPropertyValue -Object $device -Name 'verification_uri')
    $expiresIn = Get-OptionalPropertyValue -Object $device -Name 'expires_in'
    $pollInterval = Get-OptionalPropertyValue -Object $device -Name 'interval'

    if (-not $deviceCode -or -not $userCode -or -not $verificationUri -or $null -eq $expiresIn) {
        throw 'GitHub did not return a complete device authorization response.'
    }

    Write-Host "GitHub device code: $userCode"
    Write-Host "Authorize at: $verificationUri"
    if ($NoBrowser) {
        Write-ManagerAuthorization -Provider 'GitHub' -AuthorizationUri $verificationUri -UserCode $userCode
    }
    Open-ProviderAuthorization -Uri $verificationUri -NoBrowser:$NoBrowser

    $interval = if ($null -eq $pollInterval) { 5 } else { [Math]::Max([int]$pollInterval, 5) }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$expiresIn)
    $tokenResponse = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $response = Invoke-RestMethod -Method POST -Uri 'https://github.com/login/oauth/access_token' -Headers @{ Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id = $clientId
            device_code = $deviceCode
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
        }

        $accessToken = [string](Get-OptionalPropertyValue -Object $response -Name 'access_token')
        if ($accessToken) {
            $tokenResponse = $response
            break
        }

        $errorCode = [string](Get-OptionalPropertyValue -Object $response -Name 'error')
        $errorDescription = [string](Get-OptionalPropertyValue -Object $response -Name 'error_description')
        switch ($errorCode) {
            'authorization_pending' { continue }
            'slow_down' { $interval += 5; continue }
            'access_denied' { throw 'GitHub authorization was denied.' }
            'expired_token' { throw 'GitHub device authorization expired.' }
            default {
                $detail = if ($errorDescription) { "$errorCode - $errorDescription" } elseif ($errorCode) { $errorCode } else { 'unexpected response' }
                throw "GitHub device authorization failed: $detail"
            }
        }
    }

    $token = [string](Get-OptionalPropertyValue -Object $tokenResponse -Name 'access_token')
    if (-not $token) { throw 'GitHub device authorization timed out.' }
    $tokenExpiresIn = Get-OptionalPropertyValue -Object $tokenResponse -Name 'expires_in'
    if ($null -eq $tokenExpiresIn) {
        throw 'GitHub returned a non-expiring user access token. Enable expiring user access tokens on the management GitHub App before continuing.'
    }

    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_GITHUB_TOKEN', $token, 'Process')
    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_GITHUB_EXPIRES_AT', [DateTimeOffset]::UtcNow.AddSeconds([int]$tokenExpiresIn).ToString('o'), 'Process')
    [Environment]::SetEnvironmentVariable('GH_TOKEN', $token, 'Process')

    $tokenResponse = $null
    $headers = @{ Accept = 'application/vnd.github+json'; Authorization = "Bearer $token"; 'X-GitHub-Api-Version' = '2026-03-10' }
    $user = Invoke-RestMethod -Method GET -Uri 'https://api.github.com/user' -Headers $headers
    Write-Host "GitHub authenticated for this process as $($user.login)."
}

function Connect-CloudflareSession {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [switch]$NoBrowser
    )

    if ([Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')) {
        throw 'CLOUDFLARE_API_TOKEN is set in the current process. Remove it before starting an interactive mirror management session.'
    }

    $clientId = [string]$Configuration.cloudflare.client_id
    $accountId = [string]$Configuration.cloudflare.account_id
    $state = New-RandomBase64Url
    $pkce = New-PkceValues
    $authorizationUri = 'https://dash.cloudflare.com/oauth2/auth?' + (ConvertTo-QueryString -Values ([ordered]@{
        response_type = 'code'
        client_id = $clientId
        redirect_uri = $script:CloudflareRedirectUri
        state = $state
        code_challenge = $pkce.Challenge
        code_challenge_method = 'S256'
        scope = $script:CloudflareOAuthScopes -join ' '
    }))

    if ($NoBrowser) {
        Write-ManagerAuthorization -Provider 'Cloudflare' -AuthorizationUri $authorizationUri -UserCode $null
    }
    $code = Receive-LoopbackOAuthCode -RedirectUri $script:CloudflareRedirectUri -ExpectedState $state -AuthorizationUri $authorizationUri -NoBrowser:$NoBrowser
    $tokenResponse = Invoke-RestMethod -Method POST -Uri 'https://dash.cloudflare.com/oauth2/token' -Headers @{ Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{
        grant_type = 'authorization_code'
        client_id = $clientId
        redirect_uri = $script:CloudflareRedirectUri
        code = $code
        code_verifier = $pkce.Verifier
    }
    $token = [string](Get-OptionalPropertyValue -Object $tokenResponse -Name 'access_token')
    if (-not $token) { throw 'Cloudflare did not return an access token.' }

    try {
        [void](Invoke-RestMethod -Method GET -Uri 'https://dash.cloudflare.com/oauth2/userinfo' -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' })
    }
    catch {
        $detail = Get-HttpFailureDetail -ErrorRecord $_
        throw "Cloudflare OAuth token validation failed: $detail"
    }

    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_TOKEN', $token, 'Process')
    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_ACCOUNT_ID', $accountId, 'Process')
    $tokenExpiresIn = Get-OptionalPropertyValue -Object $tokenResponse -Name 'expires_in'
    if ($null -ne $tokenExpiresIn) {
        [Environment]::SetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_EXPIRES_AT', [DateTimeOffset]::UtcNow.AddSeconds([int]$tokenExpiresIn).ToString('o'), 'Process')
    }
    $tokenResponse = $null
    Write-Host 'Cloudflare OAuth authenticated for this process.'
}

function Connect-BitbucketSession {
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [AllowNull()][string]$ClientSecret,
        [switch]$NoBrowser
    )

    if ([Environment]::GetEnvironmentVariable('BITBUCKET_API_TOKEN', 'Process')) {
        throw 'BITBUCKET_API_TOKEN is set in the current process. Remove it before starting an interactive mirror management session.'
    }

    $clientId = [string]$Configuration.bitbucket.client_id
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
        $secureSecret = Read-Host -Prompt 'Bitbucket OAuth consumer secret (used only in this process)' -AsSecureString
        $ClientSecret = ConvertFrom-SecureStringPlainText -SecureString $secureSecret
        $secureSecret = $null
    }
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) { throw 'Bitbucket OAuth consumer secret is required.' }

    try {
        $state = New-RandomBase64Url
        $authorizationUri = 'https://bitbucket.org/site/oauth2/authorize?' + (ConvertTo-QueryString -Values ([ordered]@{
            client_id = $clientId
            response_type = 'code'
            state = $state
        }))
        if ($NoBrowser) {
            Write-ManagerAuthorization -Provider 'Bitbucket' -AuthorizationUri $authorizationUri -UserCode $null
        }
        $code = Receive-LoopbackOAuthCode -RedirectUri $script:BitbucketRedirectUri -ExpectedState $state -AuthorizationUri $authorizationUri -NoBrowser:$NoBrowser

        $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${clientId}:$ClientSecret")
        $basic = [Convert]::ToBase64String($credentialBytes)
        $tokenResponse = Invoke-RestMethod -Method POST -Uri 'https://bitbucket.org/site/oauth2/access_token' -Headers @{ Authorization = "Basic $basic"; Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type = 'authorization_code'
            code = $code
        }
        $token = [string](Get-OptionalPropertyValue -Object $tokenResponse -Name 'access_token')
        if (-not $token) { throw 'Bitbucket did not return an access token.' }

        [Environment]::SetEnvironmentVariable('MIRROR_SESSION_BITBUCKET_TOKEN', $token, 'Process')
        $tokenExpiresIn = Get-OptionalPropertyValue -Object $tokenResponse -Name 'expires_in'
        if ($null -ne $tokenExpiresIn) {
            [Environment]::SetEnvironmentVariable('MIRROR_SESSION_BITBUCKET_EXPIRES_AT', [DateTimeOffset]::UtcNow.AddSeconds([int]$tokenExpiresIn).ToString('o'), 'Process')
        }

        $tokenResponse = $null
        Write-Host 'Bitbucket authenticated for this process.'
    }
    finally {
        $ClientSecret = $null
    }
}

function Disconnect-MirrorSession {
    param(
        [string]$ConfigPath = 'config/authentication.json',
        [switch]$SkipCloudflareRevoke
    )

    $cloudflareToken = [Environment]::GetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_TOKEN', 'Process')
    if ($cloudflareToken -and -not $SkipCloudflareRevoke) {
        try {
            $config = Get-MirrorAuthenticationConfiguration -ConfigPath $ConfigPath
            if ($config.cloudflare.client_id) {
                [void](Invoke-RestMethod -Method POST -Uri 'https://dash.cloudflare.com/oauth2/revoke' -ContentType 'application/x-www-form-urlencoded' -Body @{
                    token = $cloudflareToken
                    client_id = [string]$config.cloudflare.client_id
                })
            }
        }
        catch {
            Write-Warning "Cloudflare token revocation could not be confirmed: $($_.Exception.Message)"
        }
    }

    foreach ($variable in $script:SessionVariables) {
        [Environment]::SetEnvironmentVariable($variable, $null, 'Process')
    }
    Write-Host 'Mirror management session credentials were cleared from this process.'
}

Export-ModuleMember -Function Get-MirrorAuthenticationConfiguration, Test-MirrorAuthenticationConfiguration, Test-PersistentGitHubCredential, Test-MirrorSession, Connect-GitHubSession, Connect-CloudflareSession, Connect-BitbucketSession, Disconnect-MirrorSession
