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

Write-Host 'PowerShell mirror reference wait modes are valid.'
