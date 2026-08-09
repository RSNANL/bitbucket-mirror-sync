[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$findings = @()
$files = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'tools') -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
    Sort-Object FullName)

foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        $relativePath = [IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName)
        $findings += "${relativePath}:$($parseError.Extent.StartLineNumber): $($parseError.Message)"
    }
}

if ($findings.Count -gt 0) {
    throw "PowerShell syntax validation failed:`n$($findings -join "`n")"
}

Write-Host "PowerShell syntax is valid: $($files.Count) files."
