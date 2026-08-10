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

$bitbucketModulePath = Join-Path $RepositoryRoot 'tools/Modules/Mirror.Bitbucket.psm1'
$bitbucketTokens = $null
$bitbucketParseErrors = $null
$bitbucketAst = [Management.Automation.Language.Parser]::ParseFile(
    $bitbucketModulePath,
    [ref]$bitbucketTokens,
    [ref]$bitbucketParseErrors
)
if (@($bitbucketParseErrors).Count -gt 0) {
    throw 'Mirror.Bitbucket.psm1 could not be parsed for runtime tests.'
}
$latestCommitAst = $bitbucketAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-BitbucketLatestCommit'
}, $true)
if ($null -eq $latestCommitAst) {
    throw 'Get-BitbucketLatestCommit was not found in Mirror.Bitbucket.psm1.'
}
. ([scriptblock]::Create($latestCommitAst.Extent.Text))
$script:bitbucketRequestPath = $null
function Invoke-BitbucketApi {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Credentials
    )
    $script:bitbucketRequestPath = $Path
    return [pscustomobject]@{ values = @() }
}
[void](Get-BitbucketLatestCommit -Repository 'rsna_nl/example' -Revision 'main' -Credentials @{ Token = 'test' })
if ($bitbucketRequestPath -ne 'repositories/rsna_nl/example/commits/main?pagelen=1') {
    throw "Bitbucket latest-commit path is malformed: $bitbucketRequestPath"
}

Import-Module (Join-Path $RepositoryRoot 'tools/Modules/Mirror.Manager.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'tools/Modules/Mirror.Common.psm1')
foreach ($commandName in @('Get-RepositoryRoot', 'New-RandomSecret', 'Get-MirrorManagerSnapshot')) {
    if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Mirror Manager startup command is unavailable after module initialization: $commandName"
    }
}

$githubTokenVariable = 'MIRROR_SESSION_GITHUB_TOKEN'
$githubExpiryVariable = 'MIRROR_SESSION_GITHUB_EXPIRES_AT'
$originalGitHubToken = [Environment]::GetEnvironmentVariable($githubTokenVariable, 'Process')
$originalGitHubExpiry = [Environment]::GetEnvironmentVariable($githubExpiryVariable, 'Process')
try {
    [Environment]::SetEnvironmentVariable($githubTokenVariable, 'test-token', 'Process')
    [Environment]::SetEnvironmentVariable($githubExpiryVariable, [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'), 'Process')
    $expiredSessionSnapshot = Get-MirrorManagerSnapshot
    $expiredGitHub = @($expiredSessionSnapshot.providers | Where-Object { $_.id -eq 'github' })[0]
    if ($expiredGitHub.authenticated -or -not $expiredGitHub.expired) {
        throw 'Mirror Manager did not expose an expired provider session as reconnectable.'
    }

    [Environment]::SetEnvironmentVariable($githubExpiryVariable, [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o'), 'Process')
    $activeSessionSnapshot = Get-MirrorManagerSnapshot
    $activeGitHub = @($activeSessionSnapshot.providers | Where-Object { $_.id -eq 'github' })[0]
    if (-not $activeGitHub.authenticated -or $activeGitHub.expired) {
        throw 'Mirror Manager did not expose a valid provider session as authenticated.'
    }

    [Environment]::SetEnvironmentVariable($githubExpiryVariable, 'invalid-expiry', 'Process')
    $invalidSessionSnapshot = Get-MirrorManagerSnapshot
    $invalidGitHub = @($invalidSessionSnapshot.providers | Where-Object { $_.id -eq 'github' })[0]
    if ($invalidGitHub.authenticated -or -not $invalidGitHub.expired) {
        throw 'Mirror Manager did not reject an invalid provider expiry value.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable($githubTokenVariable, $originalGitHubToken, 'Process')
    [Environment]::SetEnvironmentVariable($githubExpiryVariable, $originalGitHubExpiry, 'Process')
}

Import-Module (Join-Path $RepositoryRoot 'tools/Modules/Mirror.Status.psm1') -Force
$checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
$healthyCheck = New-MirrorStatusCheck -State 'healthy' -Reason 'Ready.' -CheckedAt $checkedAt
$unknownCheck = New-MirrorStatusCheck -State 'unknown' -Reason 'Not connected.' -CheckedAt $checkedAt
$unhealthyCheck = New-MirrorStatusCheck -State 'unhealthy' -Reason 'Missing.' -CheckedAt $checkedAt
$unknownOverall = Resolve-MirrorOverallStatus -CheckedAt $checkedAt -Checks @(
    [pscustomobject]@{ Label = 'source'; Check = $healthyCheck }
    [pscustomobject]@{ Label = 'actions'; Check = $unknownCheck }
)
if ($unknownOverall.state -ne 'unknown' -or $unknownOverall.reason -notmatch 'actions') {
    throw 'Mirror status did not preserve an unknown dependency in its overall state.'
}
$unhealthyOverall = Resolve-MirrorOverallStatus -CheckedAt $checkedAt -Checks @(
    [pscustomobject]@{ Label = 'source'; Check = $unknownCheck }
    [pscustomobject]@{ Label = 'webhook'; Check = $unhealthyCheck }
)
if ($unhealthyOverall.state -ne 'unhealthy' -or $unhealthyOverall.reason -notmatch 'webhook') {
    throw 'Mirror status did not prioritize an unhealthy dependency in its overall state.'
}

$validationTime = [DateTimeOffset]::UtcNow.ToString('o')
$validationSnapshot = [pscustomobject]@{
    checked_at = $checkedAt
    mirrors = @([pscustomobject]@{
        id = 'test-mirror'
        overall = $unknownOverall
        bitbucket_repository = $healthyCheck
        bitbucket_webhook = $healthyCheck
        cloudflare_worker = $healthyCheck
        github_repository = $healthyCheck
        github_actions = New-MirrorStatusCheck -State 'unknown' -Reason 'No identifiable GitHub Actions mirror run was found.' -CheckedAt $checkedAt
        last_successful_sync = [pscustomobject]@{ completed_at = $null; url = $null; run_number = $null }
    })
}
$validationSnapshot = Merge-MirrorSyncValidationEvidence `
    -Snapshot $validationSnapshot `
    -Evidence @{ 'test-mirror' = [pscustomobject]@{ completed_at = $validationTime } }
$validatedMirror = @($validationSnapshot.mirrors)[0]
if (
    $validatedMirror.last_successful_sync.completed_at -ne $validationTime -or
    $validatedMirror.last_successful_sync.evidence -ne 'full_sync_validation' -or
    $validatedMirror.github_actions.state -ne 'healthy' -or
    $validatedMirror.overall.state -ne 'healthy'
) {
    throw 'Full synchronization validation evidence was not merged into mirror status.'
}

$authorizationEvents = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$authorizationEventKey = "MirrorManager.Authorization.Test.$([Guid]::NewGuid().ToString('N'))"
[AppDomain]::CurrentDomain.SetData($authorizationEventKey, $authorizationEvents)
$authorizationPowerShell = [PowerShell]::Create()
try {
    [void]$authorizationPowerShell.AddScript(@'
param(
    [string]$SessionModulePath,
    [string]$EventKey
)
Import-Module $SessionModulePath -Force
$sessionModule = Get-Module 'Mirror.Session'
& $sessionModule {
    param([string]$AuthorizationEventKey)
    Write-ManagerAuthorization `
        -Provider 'GitHub' `
        -AuthorizationUri 'https://github.com/login/device' `
        -UserCode 'TEST-CODE' `
        -AuthorizationEventKey $AuthorizationEventKey
} $EventKey
'@)
    [void]$authorizationPowerShell.AddArgument((Join-Path $RepositoryRoot 'tools/Modules/Mirror.Session.psm1'))
    [void]$authorizationPowerShell.AddArgument($authorizationEventKey)
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
[AppDomain]::CurrentDomain.SetData($authorizationEventKey, $null)

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

foreach ($functionName in @(
    'Clear-ManagerAuthorizationChannel',
    'Receive-ManagerOperationStreams',
    'Stop-ManagerOperation',
    'Get-ManagerOperationState',
    'Start-ManagerOperation'
)) {
    $functionAst = $managerServerAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true)
    if ($null -eq $functionAst) {
        throw "$functionName was not found in Start-MirrorManager.ps1."
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$script:operation = $null
$script:statusSnapshot = $null
$script:statusIsStale = $true
$script:syncValidationEvidence = @{}
Write-Host 'Testing the real Mirror Manager provider-operation boundary.'
try {
    [void](Start-ManagerOperation -Action 'connect-provider' -Arguments @{ Provider = 'Cloudflare' })
    $authorizationDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $operationState = Get-ManagerOperationState
    } while ($null -eq $operationState.authorization -and $operationState.status -eq 'running' -and [DateTimeOffset]::UtcNow -lt $authorizationDeadline)

    if ($operationState.status -ne 'running') {
        throw "The real provider operation stopped before authorization became ready: $($operationState.error)"
    }
    if (
        $operationState.authorization.provider -ne 'cloudflare' -or
        $operationState.authorization.authorization_uri -notlike 'https://dash.cloudflare.com/oauth2/auth?*'
    ) {
        throw 'The real provider operation did not deliver its authorization event to Mirror Manager.'
    }
    $cancellationEventKey = $operation.AuthorizationEventKey
}
finally {
    if ($null -ne $operation -and $operation.Status -eq 'running') { Stop-ManagerOperation }
}
if ($operation.Status -ne 'cancelled' -or $null -eq $operation.CompletedAt -or $null -ne $operation.Authorization) {
    throw 'Mirror Manager did not transition the active operation to a clean cancelled state.'
}
if ($null -ne [AppDomain]::CurrentDomain.GetData($cancellationEventKey)) {
    throw 'Mirror Manager retained an authorization event channel after cancellation.'
}

Write-Host 'Testing the real Mirror Manager status-operation boundary.'
[void](Start-ManagerOperation -Action 'refresh-status' -Arguments @{})
$statusDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
do {
    Start-Sleep -Milliseconds 100
    $statusOperation = Get-ManagerOperationState
} while ($statusOperation.status -eq 'running' -and [DateTimeOffset]::UtcNow -lt $statusDeadline)
if ($statusOperation.status -ne 'succeeded') {
    throw "The real status operation did not succeed: $($statusOperation.error)"
}
if ($null -eq $statusSnapshot -or @($statusSnapshot.mirrors).Count -eq 0 -or $statusIsStale) {
    throw 'The live status snapshot did not cross the Mirror Manager runspace boundary.'
}
$managerSnapshot = Get-MirrorManagerSnapshot -StatusSnapshot $statusSnapshot -StatusIsStale $statusIsStale
if ($managerSnapshot.status.is_stale -or $managerSnapshot.status.checked_at -ne $statusSnapshot.checked_at) {
    throw 'Mirror Manager did not expose the completed live status snapshot.'
}

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
