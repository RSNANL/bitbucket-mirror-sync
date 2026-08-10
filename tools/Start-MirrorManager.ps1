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
$operation = $null

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
        }
    }

    $information = @($operation.PowerShell.Streams.Information | ForEach-Object { [string]$_.MessageData })
    $warnings = @($operation.PowerShell.Streams.Warning | ForEach-Object { [string]$_ })
    $errors = @($operation.PowerShell.Streams.Error | ForEach-Object { [string]$_ })

    if ($operation.Status -eq 'running' -and $operation.Async.IsCompleted) {
        try {
            $result = @($operation.PowerShell.EndInvoke($operation.Async) | ForEach-Object { [string]$_ })
            $operation.Output = @($information) + @($warnings | ForEach-Object { "WARNING: $_" }) + $result
            if ($operation.PowerShell.HadErrors -or $errors.Count -gt 0) {
                $operation.Status = 'failed'
                $operation.Error = $errors -join "`n"
            } else {
                $operation.Status = 'succeeded'
            }
        }
        catch {
            $operation.Status = 'failed'
            $operation.Error = $_.Exception.Message
            $operation.Output = @($information) + @($warnings | ForEach-Object { "WARNING: $_" })
        }
        finally {
            $operation.CompletedAt = [DateTimeOffset]::UtcNow.ToString('o')
            $operation.PowerShell.Dispose()
        }
    }

    $liveOutput = if ($operation.Status -eq 'running') { @($information) + @($warnings | ForEach-Object { "WARNING: $_" }) } else { @($operation.Output) }
    return [pscustomobject]@{
        id = $operation.Id
        action = $operation.Action
        status = $operation.Status
        started_at = $operation.StartedAt
        completed_at = $operation.CompletedAt
        output = $liveOutput
        error = $operation.Error
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
    [void]$powerShell.AddCommand($invocation.ScriptPath)
    foreach ($entry in $invocation.Parameters.GetEnumerator()) {
        [void]$powerShell.AddParameter([string]$entry.Key, $entry.Value)
    }
    if ($Action -in @('new-mirror', 'remove-mirror', 'repair-mirror', 'rotate-keys', 'deploy-worker', 'set-mirror')) {
        [void]$powerShell.AddParameter('Confirm', $false)
    }

    $async = $powerShell.BeginInvoke()
    $script:operation = [pscustomobject]@{
        Id = [Guid]::NewGuid().ToString('N')
        Action = $Action
        Status = 'running'
        StartedAt = [DateTimeOffset]::UtcNow.ToString('o')
        CompletedAt = $null
        PowerShell = $powerShell
        Async = $async
        Output = @()
        Error = $null
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
try {
    Write-Host "Mirror Manager is available at $baseUri"
    Write-Host 'Press Ctrl+C to stop it and clear the in-process management session.'
    if (-not $NoBrowser) { Start-Process $baseUri }

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $request = $context.Request
            if ($request.UserHostAddress -notin @('127.0.0.1', '::1')) { throw 'Mirror Manager only accepts loopback clients.' }
            $path = $request.Url.AbsolutePath
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/bootstrap') {
                Send-ManagerJson -Context $context -StatusCode 200 -Value @{ request_token = $csrfToken }
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
        $operation.PowerShell.Stop()
        $operation.PowerShell.Dispose()
    }
    Import-Module (Join-Path $PSScriptRoot 'Modules/Mirror.Session.psm1') -Force
    Disconnect-MirrorSession -SkipCloudflareRevoke
    $csrfToken = $null
}
