# Inspect the exact Release App output of one RID and that RID's Release CLI with the inventory-based Release boundary
# checker (build/ReleaseBoundary). Windows CI runs this immediately after "Build WinUI app (<rid>)". Keep this file ASCII.
param([Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string]$RuntimeIdentifier)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent (Split-Path -Parent $windows)
$platform = if ($RuntimeIdentifier -eq 'win-x64') { 'x64' } else { 'ARM64' }

function Get-TargetPath([string]$Project, [string[]]$Properties) {
    $resolved = & dotnet msbuild $Project -nologo -getProperty:TargetPath @Properties
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve the Release TargetPath of $Project." }
    $path = @($resolved | Where-Object { $_ -and $_.Trim() }) | Select-Object -Last 1
    if (-not $path) { throw "MSBuild returned no Release TargetPath for $Project." }
    $path = [IO.Path]::GetFullPath($path.Trim())
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing built Release output: $path" }
    return $path
}

$project = Join-Path $windows 'src/VoxClip.App/VoxClip.App.csproj'
$target = Get-TargetPath $project @('-p:Configuration=Release', "-p:RuntimeIdentifier=$RuntimeIdentifier", "-p:Platform=$platform")
Write-Host "Inspecting the exact $RuntimeIdentifier Release App TargetPath: $target"

# voxclip-cli.dll ships in the same installer payload as the App, so the RID's Release CLI is inspected too.
$cliProject = Join-Path $windows 'src/VoxClip.Cli/VoxClip.Cli.csproj'
& dotnet build $cliProject -c Release -r $RuntimeIdentifier -nologo -m:1 -nodeReuse:false -p:UseSharedCompilation=false
if ($LASTEXITCODE -ne 0) { throw "The $RuntimeIdentifier Release CLI did not build." }
$cli = Get-TargetPath $cliProject @('-p:Configuration=Release', "-p:RuntimeIdentifier=$RuntimeIdentifier")
Write-Host "Inspecting the exact $RuntimeIdentifier Release CLI TargetPath: $cli"

& dotnet build (Join-Path $PSScriptRoot 'ReleaseBoundary/ReleaseBoundary.csproj') -c Release -nologo -m:1 -nodeReuse:false -p:UseSharedCompilation=false
if ($LASTEXITCODE -ne 0) { throw 'The Release boundary checker did not build.' }
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$evidence = Join-Path $temp 'voxclip-release-boundary'
& dotnet (Join-Path $PSScriptRoot 'ReleaseBoundary/bin/Release/net10.0/ReleaseBoundary.dll') check $RuntimeIdentifier $target $cli --repo-root $root --evidence $evidence
if ($LASTEXITCODE -ne 0) { throw "Release boundary inspection failed for $RuntimeIdentifier (see the IDENTITY, FORBIDDEN, UNAPPROVED, STALE and UNLISTED lines above)." }
Write-Host "Release boundary inspection passed for $RuntimeIdentifier; evidence in $evidence"
