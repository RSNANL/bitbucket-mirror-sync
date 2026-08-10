[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testMirrorPath = Join-Path $RepositoryRoot 'tools/Test-Mirror.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [Management.Automation.Language.Parser]::ParseFile(
    $testMirrorPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw 'Test-Mirror.ps1 could not be parsed for runtime tests.'
}

$waitFunctionAst = $scriptAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Wait-GitHubReferences'
}, $true)
if ($null -eq $waitFunctionAst) {
    throw 'Wait-GitHubReferences was not found in Test-Mirror.ps1.'
}

. ([scriptblock]::Create($waitFunctionAst.Extent.Text))

$script:mockReferenceSha = $null
function Get-GitHubReferenceSha {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Reference
    )

    return $script:mockReferenceSha
}

$expectedSha = '0123456789abcdef0123456789abcdef01234567'
$script:mockReferenceSha = $expectedSha
Wait-GitHubReferences `
    -Repository 'RSNANL/example-mirror' `
    -BranchName 'mirror-validation/test' `
    -TagName 'mirror-validation-test' `
    -ExpectedSha $expectedSha `
    -TimeoutSeconds 1

$script:mockReferenceSha = $null
Wait-GitHubReferences `
    -Repository 'RSNANL/example-mirror' `
    -BranchName 'mirror-validation/test' `
    -TagName 'mirror-validation-test' `
    -ExpectMissing `
    -TimeoutSeconds 1

Import-Module (Join-Path $RepositoryRoot 'tools/Modules/Mirror.Manager.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'tools/Modules/Mirror.Common.psm1')
foreach ($commandName in @('Get-RepositoryRoot', 'New-RandomSecret', 'Get-MirrorManagerSnapshot')) {
    if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Mirror Manager startup command is unavailable after module initialization: $commandName"
    }
}

$authorizationEvents = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$authorizationPowerShell = [PowerShell]::Create()
try {
    [void]$authorizationPowerShell.AddScript(@'
param(
    [string]$SessionModulePath,
    [Collections.Concurrent.ConcurrentQueue[object]]$Events
)
Import-Module $SessionModulePath -Force
$sessionModule = Get-Module 'Mirror.Session'
& $sessionModule {
    param([Collections.Concurrent.ConcurrentQueue[object]]$Queue)
    Write-ManagerAuthorization `
        -Provider 'GitHub' `
        -AuthorizationUri 'https://github.com/login/device' `
        -UserCode 'TEST-CODE' `
        -AuthorizationEvents $Queue
} $Events
'@)
    [void]$authorizationPowerShell.AddArgument((Join-Path $RepositoryRoot 'tools/Modules/Mirror.Session.psm1'))
    [void]$authorizationPowerShell.AddArgument($authorizationEvents)
    $authorizationAsync = $authorizationPowerShell.BeginInvoke()
    if (-not $authorizationAsync.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(5))) {
        throw 'The authorization event producer did not complete.'
    }
    [void]$authorizationPowerShell.EndInvoke($authorizationAsync)
}
finally {
    $authorizationPowerShell.Dispose()
}

$authorizationEvent = $null
if (-not $authorizationEvents.TryDequeue([ref]$authorizationEvent)) {
    throw 'An authorization event could not cross the Mirror Manager runspace boundary.'
}
if (
    $authorizationEvent.provider -ne 'github' -or
    $authorizationEvent.authorization_uri -ne 'https://github.com/login/device' -or
    $authorizationEvent.user_code -ne 'TEST-CODE'
) {
    throw 'The authorization event changed while crossing the Mirror Manager runspace boundary.'
}

$managerServerPath = Join-Path $RepositoryRoot 'tools/Start-MirrorManager.ps1'
$managerServerTokens = $null
$managerServerParseErrors = $null
$managerServerAst = [Management.Automation.Language.Parser]::ParseFile(
    $managerServerPath,
    [ref]$managerServerTokens,
    [ref]$managerServerParseErrors
)
if (@($managerServerParseErrors).Count -gt 0) {
    throw 'Start-MirrorManager.ps1 could not be parsed for runtime tests.'
}

$loopbackFunctionAst = $managerServerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Test-ManagerLoopbackClient'
}, $true)
if ($null -eq $loopbackFunctionAst) {
    throw 'Test-ManagerLoopbackClient was not found in Start-MirrorManager.ps1.'
}

. ([scriptblock]::Create($loopbackFunctionAst.Extent.Text))

foreach ($addressText in @('127.0.0.1', '::1', '::ffff:127.0.0.1')) {
    $endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($addressText), 49152)
    if (-not (Test-ManagerLoopbackClient -RemoteEndPoint $endpoint)) {
        throw "Loopback address was rejected: $addressText"
    }
}

$remoteEndpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse('192.0.2.1'), 49152)
if (Test-ManagerLoopbackClient -RemoteEndPoint $remoteEndpoint) {
    throw 'A non-loopback address was accepted.'
}

Write-Host 'PowerShell mirror reference wait modes are valid.'
