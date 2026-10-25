param(
    [Parameter(Mandatory = $true)][string] $Setup,
    [Parameter(Mandatory = $true)][string] $SignTool,
    [Parameter(Mandatory = $true)][string] $Version,
    [Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier,
    [Parameter(Mandatory = $true)][string] $ReportDirectory
)

. (Join-Path $PSScriptRoot 'Release-Common.ps1')
$ErrorActionPreference = 'Stop'
$installRoot = Join-Path ([IO.Path]::GetTempPath()) ('voxclip-install-' + [Guid]::NewGuid().ToString('N'))
$marker = Join-Path $ReportDirectory 'install-root.json'
$dataRoot = Join-Path $env:LOCALAPPDATA 'VoxConvo\VoxClip'
$dataBefore = @{}
$cliVersion = $null
$signingCredentialsAbsent = $true
$firstError = $null
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
    $process = Invoke-ReleaseProcess -Executable $Setup -Arguments ('--silent --installto "' + $installRoot + '"') -TimeoutSeconds 300
    $installed = Test-Path -LiteralPath $installRoot
    if ($process.ExitCode -ne 0 -or -not $installed) { throw "Silent install failed ($($process.ExitCode)); expected $installRoot." }
    $current = Join-Path $installRoot 'current'
    foreach ($relative in @('Update.exe', 'current\VoxClip.exe', 'current\voxclip-cli.exe', 'current\LICENSE', 'current\THIRD_PARTY_NOTICES.md', 'current\licenses\FFmpeg-LICENSE.txt', 'current\licenses\FFmpeg-BUILD.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot $relative))) { throw "Installed file missing: $relative" }
    }
    Assert-ReleaseSignatures -Paths $installRoot -SignTool $SignTool -ReportPath (Join-Path $ReportDirectory 'installed-signatures.json')
    $cliOutput = Join-Path $ReportDirectory 'cli-version.txt'
    $process = Invoke-ReleaseProcess -Executable (Join-Path $current 'voxclip-cli.exe') -Arguments 'version' -TimeoutSeconds 60 -StandardOutput $cliOutput
    if ($process.ExitCode -ne 0) { throw 'Installed CLI version command failed.' }
    $cliVersion = [IO.File]::ReadAllText($cliOutput).Trim()
    Assert-ReleaseCliVersion -Actual $cliVersion -Version $Version -RuntimeIdentifier $RuntimeIdentifier
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
