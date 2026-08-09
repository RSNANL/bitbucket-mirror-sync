Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Mirror.Common.psm1') -Force

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

function Test-LoopbackRedirectUri {
    param([Parameter(Mandatory)][string]$RedirectUri)

    try { $uri = [Uri]$RedirectUri }
    catch { return $false }

    if ($uri.Scheme -ne 'http') { return $false }
    if ($uri.Host -ne '127.0.0.1') { return $false }
    if ($uri.IsDefaultPort -or $uri.Port -lt 1024 -or $uri.Port -gt 65535) { return $false }
    if ([string]::IsNullOrWhiteSpace($uri.AbsolutePath) -or $uri.AbsolutePath -eq '/') { return $false }
    return $true
}

function Test-MirrorAuthenticationConfiguration {
    param(
        [string]$ConfigPath = 'config/authentication.json',
        [switch]$RequireConfigured
    )

    $config = Get-MirrorAuthenticationConfiguration -ConfigPath $ConfigPath
    foreach ($provider in @('github', 'cloudflare', 'bitbucket')) {
        if (-not ($config.PSObject.Properties.Name -contains $provider)) {
            throw "Authentication configuration is missing provider: $provider"
        }
    }

    if (-not (Test-LoopbackRedirectUri -RedirectUri ([string]$config.cloudflare.redirect_uri))) {
        throw 'cloudflare.redirect_uri must be an HTTP loopback URI with an explicit high port and callback path.'
    }
    if (-not (Test-LoopbackRedirectUri -RedirectUri ([string]$config.bitbucket.redirect_uri))) {
        throw 'bitbucket.redirect_uri must be an HTTP loopback URI with an explicit high port and callback path.'
    }
    if ($null -eq $config.cloudflare.scopes -or $config.cloudflare.scopes -isnot [System.Array]) {
        throw 'cloudflare.scopes must be an array.'
    }
    if ($config.cloudflare.account_id -and ([string]$config.cloudflare.account_id -notmatch '^[A-Fa-f0-9]{32}$')) {
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
        if (@($config.cloudflare.scopes).Count -eq 0) {
            throw 'cloudflare.scopes is not configured.'
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

function Open-ProviderAuthorization {
    param([Parameter(Mandatory)][string]$Uri)
    Write-Host "Opening provider authorization in your browser..."
    Start-Process $Uri
}

function Receive-LoopbackOAuthCode {
    param(
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$ExpectedState,
        [Parameter(Mandatory)][string]$AuthorizationUri,
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
        Open-ProviderAuthorization -Uri $AuthorizationUri
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
            '<!doctype html><html><body><h2>Authorization failed</h2><p>You can return to PowerShell.</p></body></html>'
        } else {
            '<!doctype html><html><body><h2>Authorization complete</h2><p>You can return to PowerShell.</p></body></html>'
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
    param([Parameter(Mandatory)][object]$Configuration)

    if (Test-PersistentGitHubCredential) {
        throw 'Persistent GitHub CLI authentication is present. Run `gh auth logout --hostname github.com` once, then start the mirror management session again.'
    }
    if ([Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'Process')) {
        throw 'GITHUB_TOKEN is set in the current process. Remove it before starting an interactive mirror management session.'
    }

    $clientId = [string]$Configuration.github.client_id
    $device = Invoke-RestMethod -Method POST -Uri 'https://github.com/login/device/code' -Headers @{ Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{ client_id = $clientId }
    if (-not $device.device_code -or -not $device.user_code -or -not $device.verification_uri) {
        throw 'GitHub did not return a complete device authorization response.'
    }

    Write-Host "GitHub device code: $($device.user_code)"
    Write-Host "Authorize at: $($device.verification_uri)"
    Open-ProviderAuthorization -Uri ([string]$device.verification_uri)

    $interval = [Math]::Max([int]$device.interval, 5)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$device.expires_in)
    $tokenResponse = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        $response = Invoke-RestMethod -Method POST -Uri 'https://github.com/login/oauth/access_token' -Headers @{ Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id = $clientId
            device_code = [string]$device.device_code
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
        }

        if ($response.access_token) {
            $tokenResponse = $response
            break
        }
        switch ([string]$response.error) {
            'authorization_pending' { continue }
            'slow_down' { $interval += 5; continue }
            'access_denied' { throw 'GitHub authorization was denied.' }
            'expired_token' { throw 'GitHub device authorization expired.' }
            default { throw "GitHub device authorization failed: $($response.error) $($response.error_description)" }
        }
    }

    if (-not $tokenResponse -or -not $tokenResponse.access_token) {
        throw 'GitHub device authorization timed out.'
    }
    if (-not $tokenResponse.expires_in) {
        throw 'GitHub returned a non-expiring user access token. Enable expiring user access tokens on the management GitHub App before continuing.'
    }

    $token = [string]$tokenResponse.access_token
    $expiresAt = [DateTimeOffset]::UtcNow.AddSeconds([int]$tokenResponse.expires_in).ToString('o')
    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_GITHUB_TOKEN', $token, 'Process')
    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_GITHUB_EXPIRES_AT', $expiresAt, 'Process')
    [Environment]::SetEnvironmentVariable('GH_TOKEN', $token, 'Process')

    $tokenResponse = $null
    $headers = @{ Accept = 'application/vnd.github+json'; Authorization = "Bearer $token"; 'X-GitHub-Api-Version' = '2026-03-10' }
    $user = Invoke-RestMethod -Method GET -Uri 'https://api.github.com/user' -Headers $headers
    Write-Host "GitHub authenticated for this process as $($user.login)."
}

function Connect-CloudflareSession {
    param([Parameter(Mandatory)][object]$Configuration)

    if ([Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN', 'Process')) {
        throw 'CLOUDFLARE_API_TOKEN is set in the current process. Remove it before starting an interactive mirror management session.'
    }

    $clientId = [string]$Configuration.cloudflare.client_id
    $accountId = [string]$Configuration.cloudflare.account_id
    $redirectUri = [string]$Configuration.cloudflare.redirect_uri
    $state = New-RandomBase64Url
    $pkce = New-PkceValues

    $authorizationValues = [ordered]@{
        response_type = 'code'
        client_id = $clientId
        redirect_uri = $redirectUri
        state = $state
        code_challenge = $pkce.Challenge
        code_challenge_method = 'S256'
    }
    $scopes = @($Configuration.cloudflare.scopes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($scopes.Count -gt 0) { $authorizationValues['scope'] = $scopes -join ' ' }

    $authorizationUri = 'https://dash.cloudflare.com/oauth2/auth?' + (ConvertTo-QueryString -Values $authorizationValues)
    $code = Receive-LoopbackOAuthCode -RedirectUri $redirectUri -ExpectedState $state -AuthorizationUri $authorizationUri

    $tokenResponse = Invoke-RestMethod -Method POST -Uri 'https://dash.cloudflare.com/oauth2/token' -Headers @{ Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{
        grant_type = 'authorization_code'
        client_id = $clientId
        redirect_uri = $redirectUri
        code = $code
        code_verifier = $pkce.Verifier
    }
    if (-not $tokenResponse.access_token) { throw 'Cloudflare did not return an access token.' }

    $token = [string]$tokenResponse.access_token
    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_TOKEN', $token, 'Process')
    [Environment]::SetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_ACCOUNT_ID', $accountId, 'Process')
    if ($tokenResponse.expires_in) {
        [Environment]::SetEnvironmentVariable('MIRROR_SESSION_CLOUDFLARE_EXPIRES_AT', [DateTimeOffset]::UtcNow.AddSeconds([int]$tokenResponse.expires_in).ToString('o'), 'Process')
    }

    $tokenResponse = $null
    $response = Invoke-RestMethod -Method GET -Uri "https://api.cloudflare.com/client/v4/accounts/$accountId/workers/scripts" -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' }
    if ($response.PSObject.Properties.Name -contains 'success' -and -not $response.success) {
        throw 'Cloudflare session token does not have the required access to the configured account.'
    }
    Write-Host 'Cloudflare authenticated for this process.'
}

function Connect-BitbucketSession {
    param([Parameter(Mandatory)][object]$Configuration)

    if ([Environment]::GetEnvironmentVariable('BITBUCKET_API_TOKEN', 'Process')) {
        throw 'BITBUCKET_API_TOKEN is set in the current process. Remove it before starting an interactive mirror management session.'
    }

    $clientId = [string]$Configuration.bitbucket.client_id
    $redirectUri = [string]$Configuration.bitbucket.redirect_uri
    $secureSecret = Read-Host -Prompt 'Bitbucket OAuth consumer secret (used only in this process)' -AsSecureString
    $clientSecret = ConvertFrom-SecureStringPlainText -SecureString $secureSecret
    $secureSecret = $null
    if ([string]::IsNullOrWhiteSpace($clientSecret)) { throw 'Bitbucket OAuth consumer secret is required.' }

    try {
        $state = New-RandomBase64Url
        $authorizationUri = 'https://bitbucket.org/site/oauth2/authorize?' + (ConvertTo-QueryString -Values ([ordered]@{
            client_id = $clientId
            response_type = 'code'
            state = $state
        }))
        $code = Receive-LoopbackOAuthCode -RedirectUri $redirectUri -ExpectedState $state -AuthorizationUri $authorizationUri

        $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${clientId}:$clientSecret")
        $basic = [Convert]::ToBase64String($credentialBytes)
        $tokenResponse = Invoke-RestMethod -Method POST -Uri 'https://bitbucket.org/site/oauth2/access_token' -Headers @{ Authorization = "Basic $basic"; Accept = 'application/json' } -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type = 'authorization_code'
            code = $code
        }
        if (-not $tokenResponse.access_token) { throw 'Bitbucket did not return an access token.' }

        $token = [string]$tokenResponse.access_token
        [Environment]::SetEnvironmentVariable('MIRROR_SESSION_BITBUCKET_TOKEN', $token, 'Process')
        if ($tokenResponse.expires_in) {
            [Environment]::SetEnvironmentVariable('MIRROR_SESSION_BITBUCKET_EXPIRES_AT', [DateTimeOffset]::UtcNow.AddSeconds([int]$tokenResponse.expires_in).ToString('o'), 'Process')
        }

        $tokenResponse = $null
        [void](Invoke-RestMethod -Method GET -Uri 'https://api.bitbucket.org/2.0/repositories?pagelen=1' -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' })
        Write-Host 'Bitbucket authenticated for this process.'
    }
    finally {
        $clientSecret = $null
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
