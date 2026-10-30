param(
    [Parameter(Mandatory = $true)][string] $Setup,
    [Parameter(Mandatory = $true)][string] $SignTool,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier,
    [Parameter(Mandatory = $true)][string] $ReportDirectory,
    [Parameter(Mandatory = $true)][string] $ExpectedNotices,
    [string] $PackagedUpdaterHash,
    [string] $PackagedStubHash
)

. (Join-Path $PSScriptRoot 'Release-Common.ps1')
$ErrorActionPreference = 'Stop'

function Invoke-ReleaseCliGateCommand {
    param([string] $Cli, [string] $Arguments, [string] $ReportDirectory,
          [int] $ExpectedExitCode, [bool] $ExpectedSuccess, [string] $ExpectedCommand, [string] $ExpectedErrorCode)
    $output = Join-Path $ReportDirectory 'runtime-gate-output.json'
    try {
        $process = Invoke-ReleaseProcess -Executable $Cli -Arguments $Arguments -TimeoutSeconds 60 -StandardOutput $output
        if ($process.ExitCode -ne $ExpectedExitCode -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
            throw "Packaged CLI runtime gate returned an unexpected status for $ExpectedCommand."
        }
        $result = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
        if ($null -eq $result -or $result.ok -cne $ExpectedSuccess -or $result.command -cne $ExpectedCommand -or
            ($ExpectedErrorCode -and $result.error.code -cne $ExpectedErrorCode)) {
            throw "Packaged CLI runtime gate returned an unexpected result for $ExpectedCommand."
        }
        return $result
    } finally {
        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ReleasePackagedCliRuntimeGate {
    param([string] $Cli, [string] $InstallRoot, [string] $ReportDirectory)
    $dataDirectory = Join-Path $InstallRoot 'runtime-terms-smoke'
    if (Test-Path -LiteralPath $dataDirectory) { throw 'Runtime terms smoke data root is not fresh.' }
    New-Item -ItemType Directory -Path $dataDirectory | Out-Null
    $previousDataDirectory = $env:VOXCLIP_DATA_DIR
    try {
        $env:VOXCLIP_DATA_DIR = $dataDirectory
        $probe = 'probe "' + (Join-Path $dataDirectory 'missing-media.mp4') + '" --json'
        $terms = Invoke-ReleaseCliGateCommand -Cli $Cli -Arguments '--runtime-terms --json' -ReportDirectory $ReportDirectory -ExpectedExitCode 0 -ExpectedSuccess $true -ExpectedCommand 'runtime-terms'
        $hash = ([string] $terms.output -split "`n", 2)[0].TrimEnd("`r")
        if ($hash -cnotmatch '\A[0-9a-f]{64}\z') { throw 'Packaged CLI runtime terms output lacks a SHA-256 first line.' }
        $null = Invoke-ReleaseCliGateCommand -Cli $Cli -Arguments $probe -ReportDirectory $ReportDirectory -ExpectedExitCode 7 -ExpectedSuccess $false -ExpectedCommand 'probe' -ExpectedErrorCode 'runtimeTermsRequired'
        $accept = Invoke-ReleaseCliGateCommand -Cli $Cli -Arguments "--accept-runtime-terms $hash --json" -ReportDirectory $ReportDirectory -ExpectedExitCode 0 -ExpectedSuccess $true -ExpectedCommand 'accept-runtime-terms'
        if ($accept.output -cne $hash) { throw 'Packaged CLI accepted a different runtime terms SHA-256.' }
        $receipt = Join-Path $dataDirectory 'windows-runtime-agreement.txt'
        if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) { throw 'Packaged CLI did not create its isolated runtime terms receipt.' }
        $null = Invoke-ReleaseCliGateCommand -Cli $Cli -Arguments $probe -ReportDirectory $ReportDirectory -ExpectedExitCode 3 -ExpectedSuccess $false -ExpectedCommand 'probe' -ExpectedErrorCode 'mediaMissing'
        Remove-Item -LiteralPath $receipt -Force
        $null = Invoke-ReleaseCliGateCommand -Cli $Cli -Arguments $probe -ReportDirectory $ReportDirectory -ExpectedExitCode 7 -ExpectedSuccess $false -ExpectedCommand 'probe' -ExpectedErrorCode 'runtimeTermsRequired'
        $acceptAgain = Invoke-ReleaseCliGateCommand -Cli $Cli -Arguments "--accept-runtime-terms $hash --json" -ReportDirectory $ReportDirectory -ExpectedExitCode 0 -ExpectedSuccess $true -ExpectedCommand 'accept-runtime-terms'
        if ($acceptAgain.output -cne $hash -or -not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
            throw 'Packaged CLI did not renew its isolated runtime terms receipt.'
        }
        [IO.File]::WriteAllText($receipt, 'corrupt fixture receipt', [Text.Encoding]::ASCII)
        $null = Invoke-ReleaseCliGateCommand -Cli $Cli -Arguments $probe -ReportDirectory $ReportDirectory -ExpectedExitCode 7 -ExpectedSuccess $false -ExpectedCommand 'probe' -ExpectedErrorCode 'runtimeTermsRequired'
    } finally {
        $env:VOXCLIP_DATA_DIR = $previousDataDirectory
    }
}

$installRoot = Join-Path ([IO.Path]::GetTempPath()) ('voxclip-install-' + [Guid]::NewGuid().ToString('N'))
$marker = Join-Path $ReportDirectory 'install-root.json'
$dataRoot = Join-Path $env:LOCALAPPDATA 'VoxConvo\VoxClip'
$dataBefore = @{}
$cliVersion = $null
$signingCredentialsAbsent = $true
$firstError = $null
$runtimeBefore = $null
$runtimeAfter = $null
$setupExitCode = $null
$cleanupErrors = New-Object 'Collections.Generic.List[Exception]'
try {
    foreach ($name in @('AZURE_TENANT_ID', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET')) {
        if ([Environment]::GetEnvironmentVariable($name, 'Process')) {
            $signingCredentialsAbsent = $false
            throw 'Installer verification must run without signing credentials.'
        }
    }
    if (Test-Path $dataRoot) {
        foreach ($file in Get-ChildItem $dataRoot -Recurse -File) { $dataBefore[$file.FullName] = (Get-FileHash $file.FullName).Hash }
    }
    New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
    [IO.File]::WriteAllText($marker, (@{ installRoot = $installRoot } | ConvertTo-Json), [Text.Encoding]::UTF8)
    $runtimeBefore = Get-ReleaseVcRuntime -RuntimeIdentifier $RuntimeIdentifier
    $process = Invoke-ReleaseProcess -Executable $Setup -Arguments ('--silent --installto "' + $installRoot + '"') -TimeoutSeconds 300
    $setupExitCode = $process.ExitCode
    $runtimeAfter = Get-ReleaseVcRuntime -RuntimeIdentifier $RuntimeIdentifier
    $installed = Test-Path -LiteralPath $installRoot
    if ($process.ExitCode -ne 0 -or -not $installed) { throw "Silent install failed ($($process.ExitCode)); expected $installRoot." }
    Assert-ReleaseVcRuntime -Runtime $runtimeAfter
    $current = Join-Path $installRoot 'current'
    foreach ($relative in @('Update.exe', 'VoxClip.exe', 'current\VoxClip.exe', 'current\voxclip-cli.exe', 'current\LICENSE', 'current\THIRD_PARTY_NOTICES.md', 'current\licenses\FFmpeg-LICENSE.txt', 'current\licenses\FFmpeg-BUILD.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot $relative))) { throw "Installed file missing: $relative" }
    }
    Assert-ReleaseFileMatches -Expected $ExpectedNotices -Actual (Join-Path $current 'THIRD_PARTY_NOTICES.md')
    if ($PackagedUpdaterHash -and (Get-FileHash -LiteralPath (Join-Path $installRoot 'Update.exe') -Algorithm SHA256).Hash -ine $PackagedUpdaterHash) {
        throw 'Installed Update.exe differs from packaged Squirrel.exe.'
    }
    if ($PackagedStubHash -and (Get-FileHash -LiteralPath (Join-Path $installRoot 'VoxClip.exe') -Algorithm SHA256).Hash -ine $PackagedStubHash) {
        throw 'Installed execution stub differs from the full package.'
    }
    Assert-ReleaseSignatures -Paths $installRoot -SignTool $SignTool -ReportPath (Join-Path $ReportDirectory 'installed-signatures.json')
    $cliOutput = Join-Path $ReportDirectory 'cli-version.txt'
    $process = Invoke-ReleaseProcess -Executable (Join-Path $current 'voxclip-cli.exe') -Arguments 'version' -TimeoutSeconds 60 -StandardOutput $cliOutput
    if ($process.ExitCode -ne 0) { throw 'Installed CLI version command failed.' }
    $cliVersion = [IO.File]::ReadAllText($cliOutput).Trim()
    Assert-ReleaseCliVersion -Actual $cliVersion -Version $Version -RuntimeIdentifier $RuntimeIdentifier
    Assert-ReleasePackagedCliRuntimeGate -Cli (Join-Path $current 'voxclip-cli.exe') -InstallRoot $installRoot -ReportDirectory $ReportDirectory
} catch {
    $firstError = $_
} finally {
    $result = Invoke-ReleaseInstallCleanup -InstallRoot $installRoot
    $cleanup = $result.cleanup
    foreach ($error in $result.errors) { $cleanupErrors.Add($error) }
    foreach ($path in $dataBefore.Keys) {
        try {
            if (-not (Test-Path $path) -or (Get-FileHash $path).Hash -ne $dataBefore[$path]) { throw "Smoke test changed existing user data: $path" }
        } catch {
            $cleanup.userDataPreserved = $false
            $cleanupErrors.Add($_.Exception)
        }
    }
    try {
        if ($cleanupErrors.Count -eq 0 -and (Test-Path -LiteralPath $marker)) { Remove-Item -LiteralPath $marker -Force -ErrorAction Stop }
    } catch { $cleanupErrors.Add($_.Exception) }
    $cleanup.errors = @($cleanupErrors | ForEach-Object { $_.Message })
    try {
        New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
        [IO.File]::WriteAllText((Join-Path $ReportDirectory 'install-test.json'), (@{
            installRoot = $installRoot; dataRoot = $dataRoot; cliVersion = $cliVersion; runtimeIdentifier = $RuntimeIdentifier; setup = $Setup
            vcRuntimeBefore = $runtimeBefore; vcRuntimeAfter = $runtimeAfter; setupExitCode = $setupExitCode
            uninstalled = $cleanup.uninstalled; temporaryDirectoryRemoved = $cleanup.directoryRemoved; signingCredentialsAbsent = $signingCredentialsAbsent
            error = if ($firstError) { $firstError.Exception.Message } else { $null }; cleanup = $cleanup
            success = -not $firstError -and $cleanupErrors.Count -eq 0
        } | ConvertTo-Json -Depth 6), [Text.Encoding]::ASCII)
    } catch { $cleanupErrors.Add($_.Exception) }
}
if ($cleanupErrors.Count -gt 0) {
    $errors = $cleanupErrors.ToArray()
    if ($firstError) { $errors = @($firstError.Exception) + $errors }
    throw (New-ReleaseAggregateException -Message "Installer verification or cleanup failed for $RuntimeIdentifier (install root $installRoot)" -Errors $errors)
}
if ($firstError) { throw $firstError }
Write-Host "Installed into $installRoot, verified, then uninstalled. User data remains separate."
