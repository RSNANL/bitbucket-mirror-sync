Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    $moduleDirectory = Split-Path -Parent $PSScriptRoot
    return (Split-Path -Parent $moduleDirectory)
}

function Test-ExternalCommand {
    param([Parameter(Mandatory)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-ExternalCommand {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -ErrorAction Stop
    return $command.Source
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [AllowNull()][string]$InputText = $null,
        [switch]$AllowFailure
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $InputText
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
        if (-not $InputText.EndsWith("`n")) {
            $process.StandardInput.WriteLine()
        }
        $process.StandardInput.Close()
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout.TrimEnd()
        StdErr = $stderr.TrimEnd()
    }
    if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
        $message = "Command failed with exit code $($process.ExitCode): $FilePath $($ArgumentList -join ' ')"
        if ($stderr) { $message += "`n$stderr" }
        throw $message
    }
    return $result
}

function ConvertFrom-SecureStringPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Read-SecretValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$EnvironmentVariable
    )
    if ($EnvironmentVariable) {
        $value = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if ($value) { return $value }
    }
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    return ConvertFrom-SecureStringPlainText -SecureString $secure
}

function Split-RepositoryName {
    param([Parameter(Mandatory)][string]$Repository)
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "Repository must use owner/repository notation: $Repository"
    }
    $parts = $Repository.Split('/', 2)
    return [pscustomobject]@{ Owner = $parts[0]; Name = $parts[1] }
}

function Assert-MirrorId {
    param([Parameter(Mandatory)][string]$MirrorId)
    if ($MirrorId.Length -gt 48 -or $MirrorId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw 'MirrorId must be lowercase kebab-case and at most 48 characters.'
    }
}

function Get-DerivedEnvironmentName {
    param([Parameter(Mandatory)][string]$MirrorId)
    return "mirror-$MirrorId"
}

function Get-DerivedWebhookSecretBinding {
    param([Parameter(Mandatory)][string]$MirrorId)
    return 'WEBHOOK_' + $MirrorId.Replace('-', '_').ToUpperInvariant()
}

function Resolve-WorkerBaseUrl {
    param([Parameter(Mandatory)][string]$WorkerBaseUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($WorkerBaseUrl, [UriKind]::Absolute, [ref]$uri)) {
        throw 'WorkerBaseUrl must be a valid absolute URI.'
    }
    if (
        $uri.Scheme -ne 'https' -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        $uri.AbsolutePath -ne '/' -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)
    ) {
        throw 'WorkerBaseUrl must be a clean HTTPS origin without credentials, path, query or fragment.'
    }
    return $WorkerBaseUrl.TrimEnd('/')
}

function New-RandomSecret {
    param([int]$ByteLength = 32)
    $bytes = [byte[]]::new($ByteLength)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-SecureTemporaryDirectory {
    param([Parameter(Mandatory)][string]$Prefix)
    $base = [IO.Path]::GetTempPath()
    $path = Join-Path $base ("$Prefix-" + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    if (-not $IsWindows) {
        [void](Invoke-ExternalCommand -FilePath (Resolve-ExternalCommand chmod) -ArgumentList @('700', $path))
    }
    return $path
}

function Remove-SecureDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-SshKeyPair {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Label
    )
    $privatePath = Join-Path $Directory $FileName
    $sshKeygen = Resolve-ExternalCommand ssh-keygen
    [void](Invoke-ExternalCommand -FilePath $sshKeygen -ArgumentList @(
        '-q', '-t', 'ed25519', '-N', '', '-C', $Label, '-f', $privatePath
    ))
    return [pscustomobject]@{
        PrivatePath = $privatePath
        PublicPath = "$privatePath.pub"
        PrivateKey = [IO.File]::ReadAllText($privatePath)
        PublicKey = [IO.File]::ReadAllText("$privatePath.pub").Trim()
    }
}

function Get-StatePath {
    param([Parameter(Mandatory)][string]$MirrorId)
    $directory = Join-Path ([IO.Path]::GetTempPath()) 'bitbucket-mirror-sync-state'
    [void][IO.Directory]::CreateDirectory($directory)
    return Join-Path $directory "$MirrorId.json"
}

function Write-ProvisioningState {
    param(
        [Parameter(Mandatory)][string]$MirrorId,
        [Parameter(Mandatory)][hashtable]$State
    )
    $State['mirror_id'] = $MirrorId
    $State['updated_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    $json = $State | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Get-StatePath -MirrorId $MirrorId), "$json`n")
}

function Read-ProvisioningState {
    param([Parameter(Mandatory)][string]$MirrorId)
    $path = Get-StatePath -MirrorId $MirrorId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
}

function Remove-ProvisioningState {
    param([Parameter(Mandatory)][string]$MirrorId)
    Remove-Item -LiteralPath (Get-StatePath -MirrorId $MirrorId) -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function *
