[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 53681,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Manager.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Common.psm1')

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or newer is required; current version is $($PSVersionTable.PSVersion)."
}

$root = Get-RepositoryRoot
$webRoot = Join-Path $root 'manager/web'
if (-not (Test-Path -LiteralPath (Join-Path $webRoot 'index.html'))) {
    throw "Mirror Manager web assets were not found: $webRoot"
}

$baseUri = "http://127.0.0.1:$Port"
$csrfToken = New-RandomSecret -ByteLength 32
$runtimeId = [Guid]::NewGuid().ToString('N')
$operation = $null
$lastClientHeartbeat = $null

function Send-ManagerResponse {
    param(
        [Parameter(Mandatory)][Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][byte[]]$Body,
        [Parameter(Mandatory)][string]$ContentType
    )
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['Referrer-Policy'] = 'no-referrer'
    $response.Headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    $response.ContentLength64 = $Body.Length
    $response.OutputStream.Write($Body, 0, $Body.Length)
    $response.Close()
}

function Send-ManagerJson {
    param(
        [Parameter(Mandatory)][Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [AllowNull()][object]$Value
    )
    $json = if ($null -eq $Value) { 'null' } else { $Value | ConvertTo-Json -Depth 30 -Compress }
    Send-ManagerResponse -Context $Context -StatusCode $StatusCode -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8'
}

function Read-ManagerJsonBody {
    param([Parameter(Mandatory)][Net.HttpListenerRequest]$Request)
    if ($Request.ContentLength64 -gt 1048576) { throw 'Request body exceeds the 1 MiB limit.' }
    $reader = [IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding, $true, 1024, $true)
    try {
        $body = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($body)) { return @{} }
        return $body | ConvertFrom-Json -AsHashtable
    }
    finally { $reader.Dispose() }
}

function Assert-ManagerMutationRequest {
    param([Parameter(Mandatory)][Net.HttpListenerRequest]$Request)
    if ($Request.Headers['Origin'] -ne $baseUri) { throw 'The request origin is not the active Mirror Manager.' }
    if ($Request.Headers['X-Mirror-Manager-Token'] -ne $csrfToken) { throw 'The request token is invalid.' }
    if ($Request.ContentType -notlike 'application/json*') { throw 'Mutating requests require application/json.' }
}

function Test-ManagerLoopbackClient {
    param([Parameter(Mandatory)][Net.IPEndPoint]$RemoteEndPoint)

    $address = $RemoteEndPoint.Address
    if ($address.IsIPv4MappedToIPv6) {
        $address = $address.MapToIPv4()
    }
    return [Net.IPAddress]::IsLoopback($address)
}

function Clear-ManagerAuthorizationChannel {
    param([AllowNull()][object]$ManagerOperation)

    if ($null -ne $ManagerOperation -and -not [string]::IsNullOrWhiteSpace([string]$ManagerOperation.AuthorizationEventKey)) {
        [AppDomain]::CurrentDomain.SetData([string]$ManagerOperation.AuthorizationEventKey, $null)
    }
}

function Receive-ManagerOperationStreams {
    param([Parameter(Mandatory)][object]$ManagerOperation)

    if ($null -eq $ManagerOperation.PowerShell) { return }
    $information = @($ManagerOperation.PowerShell.Streams.Information.ReadAll() | ForEach-Object { [string]$_.MessageData })
    $warnings = @($ManagerOperation.PowerShell.Streams.Warning.ReadAll() | ForEach-Object { "WARNING: $_" })
    $errors = @($ManagerOperation.PowerShell.Streams.Error.ReadAll() | ForEach-Object { [string]$_ })
    if ($information.Count -gt 0 -or $warnings.Count -gt 0) {
        $ManagerOperation.Output = @($ManagerOperation.Output) + @($information) + @($warnings)
    }
    if ($errors.Count -gt 0) {
        $ManagerOperation.Errors = @($ManagerOperation.Errors) + @($errors)
    }
}

function Stop-ManagerOperation {
    param(
        [ValidateSet('cancelled', 'failed')][string]$Status = 'cancelled',
        [AllowNull()][string]$ErrorMessage
    )

    if ($null -eq $operation -or $operation.Status -ne 'running') { return }

    try { $operation.PowerShell.Stop() }
    catch { }

    Receive-ManagerOperationStreams -ManagerOperation $operation
    $operation.Status = $Status
    $operation.Error = $ErrorMessage
    $operation.Authorization = $null
    $operation.CompletedAt = [DateTimeOffset]::UtcNow.ToString('o')
    Clear-ManagerAuthorizationChannel -ManagerOperation $operation
    $operation.PowerShell.Dispose()
    $operation.PowerShell = $null
    $operation.Async = $null
}

function Get-ManagerOperationState {
    if ($null -eq $operation) { return $null }
    if ($operation.Status -ne 'running') {
        return [pscustomobject]@{
            id = $operation.Id
            action = $operation.Action
            status = $operation.Status
            started_at = $operation.StartedAt
            completed_at = $operation.CompletedAt
            output = @($operation.Output)
            error = $operation.Error
            authorization = $operation.Authorization
        }
    }

    $authorizationEvent = $null
    while ($operation.AuthorizationEvents.TryDequeue([ref]$authorizationEvent)) {
        $operation.Authorization = $authorizationEvent
        $authorizationEvent = $null
    }

    Receive-ManagerOperationStreams -ManagerOperation $operation

    if (
        $operation.Action -eq 'connect-provider' -and
        $null -eq $operation.Authorization -and
        [DateTimeOffset]::UtcNow -ge $operation.AuthorizationDeadline
    ) {
        Stop-ManagerOperation -Status 'failed' -ErrorMessage 'Provider authorization did not become ready within 30 seconds.'
        return Get-ManagerOperationState
    }

    if ($operation.Status -eq 'running' -and $operation.Async.IsCompleted) {
        try {
            $result = @($operation.PowerShell.EndInvoke($operation.Async) | ForEach-Object { [string]$_ })
            Receive-ManagerOperationStreams -ManagerOperation $operation
            $operation.Output = @($operation.Output) + $result
            if ($operation.PowerShell.HadErrors -or $operation.Errors.Count -gt 0) {
                $operation.Status = 'failed'
                $operation.Error = $operation.Errors -join "`n"
            } else {
                $operation.Status = 'succeeded'
            }
        }
        catch {
            $operation.Status = 'failed'
            $operation.Error = $_.Exception.Message
            Receive-ManagerOperationStreams -ManagerOperation $operation
        }
        finally {
            $operation.CompletedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Clear-ManagerAuthorizationChannel -ManagerOperation $operation
            $operation.PowerShell.Dispose()
            $operation.PowerShell = $null
            $operation.Async = $null
        }
    }

    return [pscustomobject]@{
        id = $operation.Id
        action = $operation.Action
        status = $operation.Status
        started_at = $operation.StartedAt
        completed_at = $operation.CompletedAt
        output = @($operation.Output)
        error = $operation.Error
        authorization = $operation.Authorization
    }
}

function Start-ManagerOperation {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments
    )
    $current = Get-ManagerOperationState
    if ($null -ne $current -and $current.status -eq 'running') { throw 'Another Mirror Manager operation is already running.' }

    $invocation = Get-MirrorManagerInvocation -Action $Action -Arguments $Arguments
    $powerShell = [PowerShell]::Create()
    $operationId = [Guid]::NewGuid().ToString('N')
    $authorizationEvents = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    $authorizationEventKey = "MirrorManager.Authorization.$operationId"
    [AppDomain]::CurrentDomain.SetData($authorizationEventKey, $authorizationEvents)
    [void]$powerShell.AddCommand($invocation.ScriptPath)
    foreach ($entry in $invocation.Parameters.GetEnumerator()) {
        [void]$powerShell.AddParameter([string]$entry.Key, $entry.Value)
    }
    if ($Action -eq 'connect-provider') {
        [void]$powerShell.AddParameter('NoBrowser', $true)
        [void]$powerShell.AddParameter('AuthorizationEventKey', $authorizationEventKey)
    }
    if ($Action -in @('new-mirror', 'remove-mirror', 'repair-mirror', 'rotate-keys', 'deploy-worker', 'set-mirror')) {
        [void]$powerShell.AddParameter('Confirm', $false)
    }

    try { $async = $powerShell.BeginInvoke() }
    catch {
        [AppDomain]::CurrentDomain.SetData($authorizationEventKey, $null)
        $powerShell.Dispose()
        throw
    }
    $script:operation = [pscustomobject]@{
        Id = $operationId
        Action = $Action
        Status = 'running'
        StartedAt = [DateTimeOffset]::UtcNow.ToString('o')
        CompletedAt = $null
        PowerShell = $powerShell
        Async = $async
        Output = @()
        Errors = @()
        Error = $null
        Authorization = $null
        AuthorizationEvents = $authorizationEvents
        AuthorizationEventKey = $authorizationEventKey
        AuthorizationDeadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    }
    return Get-ManagerOperationState
}

function Send-ManagerAsset {
    param(
        [Parameter(Mandatory)][Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$RequestPath
    )
    $assets = @{
        '/' = @{ File = 'index.html'; Type = 'text/html; charset=utf-8' }
        '/app.js' = @{ File = 'app.js'; Type = 'text/javascript; charset=utf-8' }
        '/styles.css' = @{ File = 'styles.css'; Type = 'text/css; charset=utf-8' }
    }
    if (-not $assets.ContainsKey($RequestPath)) {
        Send-ManagerJson -Context $Context -StatusCode 404 -Value @{ error = 'Not found.' }
        return
    }
    $asset = $assets[$RequestPath]
    $bytes = [IO.File]::ReadAllBytes((Join-Path $webRoot $asset.File))
    Send-ManagerResponse -Context $Context -StatusCode 200 -Body $bytes -ContentType $asset.Type
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$baseUri/")
$listener.Start()
$browserHandled = [bool]$NoBrowser
$browserOpenAt = [DateTimeOffset]::UtcNow.AddSeconds(3)
$pendingContext = $listener.GetContextAsync()
try {
    Write-Host "Mirror Manager is available at $baseUri"
    Write-Host 'Press Ctrl+C to stop it and clear the in-process management session.'

    while ($listener.IsListening) {
        if (-not $browserHandled -and [DateTimeOffset]::UtcNow -ge $browserOpenAt) {
            if ($null -eq $lastClientHeartbeat) { Start-Process $baseUri }
            $browserHandled = $true
        }

        if (-not $pendingContext.Wait(200)) { continue }
        $context = $pendingContext.GetAwaiter().GetResult()
        $pendingContext = $listener.GetContextAsync()
        try {
            $request = $context.Request
            if (-not (Test-ManagerLoopbackClient -RemoteEndPoint $request.RemoteEndPoint)) {
                throw 'Mirror Manager only accepts loopback clients.'
            }
            $path = $request.Url.AbsolutePath
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/health') {
                $script:lastClientHeartbeat = [DateTimeOffset]::UtcNow
                Send-ManagerJson -Context $context -StatusCode 200 -Value @{ runtime_id = $runtimeId }
            }
            elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/api/bootstrap') {
                Send-ManagerJson -Context $context -StatusCode 200 -Value @{ request_token = $csrfToken; runtime_id = $runtimeId }
            }
            elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/api/snapshot') {
                Send-ManagerJson -Context $context -StatusCode 200 -Value (Get-MirrorManagerSnapshot)
            }
            elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/api/operation') {
                Send-ManagerJson -Context $context -StatusCode 200 -Value (Get-ManagerOperationState)
            }
            elseif ($request.HttpMethod -eq 'POST' -and $path -eq '/api/operation') {
                Assert-ManagerMutationRequest -Request $request
                $body = Read-ManagerJsonBody -Request $request
                $arguments = if ($body.ContainsKey('arguments') -and $null -ne $body.arguments) { [Collections.IDictionary]$body.arguments } else { @{} }
                $started = Start-ManagerOperation -Action ([string]$body.action) -Arguments $arguments
                Send-ManagerJson -Context $context -StatusCode 202 -Value $started
            }
            elseif ($request.HttpMethod -eq 'POST' -and $path -eq '/api/operation/cancel') {
                Assert-ManagerMutationRequest -Request $request
                [void](Read-ManagerJsonBody -Request $request)
                Stop-ManagerOperation
                Send-ManagerJson -Context $context -StatusCode 200 -Value (Get-ManagerOperationState)
            }
            else { Send-ManagerAsset -Context $context -RequestPath $path }
        }
        catch {
            if ($context.Response.OutputStream.CanWrite) {
                Send-ManagerJson -Context $context -StatusCode 400 -Value @{ error = $_.Exception.Message }
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    if ($null -ne $operation -and $operation.Status -eq 'running') {
        Stop-ManagerOperation
    }
    Clear-ManagerAuthorizationChannel -ManagerOperation $operation
    Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Session.psm1') -Force
    Disconnect-MirrorSession -SkipCloudflareRevoke
    $csrfToken = $null
    Write-Host 'Mirror Manager stopped and the in-process management session was cleared.'
}
