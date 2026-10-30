# Inspect the exact Release App output of one RID with the inventory-based Release boundary checker
# (build/ReleaseBoundary). Windows CI runs this immediately after "Build WinUI app (<rid>)". Keep this file ASCII.
param([Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string]$RuntimeIdentifier)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$windows = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent (Split-Path -Parent $windows)
$platform = if ($RuntimeIdentifier -eq 'win-x64') { 'x64' } else { 'ARM64' }
$project = Join-Path $windows 'src/VoxClip.App/VoxClip.App.csproj'
$resolved = & dotnet msbuild $project -nologo -getProperty:TargetPath '-p:Configuration=Release' "-p:RuntimeIdentifier=$RuntimeIdentifier" "-p:Platform=$platform"
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the Release App TargetPath.' }
$target = @($resolved | Where-Object { $_ -and $_.Trim() }) | Select-Object -Last 1
if (-not $target) { throw 'MSBuild returned no Release App TargetPath.' }
$target = [IO.Path]::GetFullPath($target.Trim())
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Missing built Release App: $target" }
Write-Host "Inspecting the exact $RuntimeIdentifier Release App TargetPath: $target"
& dotnet build (Join-Path $PSScriptRoot 'ReleaseBoundary/ReleaseBoundary.csproj') -c Release -nologo -m:1 -nodeReuse:false -p:UseSharedCompilation=false
if ($LASTEXITCODE -ne 0) { throw 'The Release boundary checker did not build.' }
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$evidence = Join-Path $temp 'voxclip-release-boundary'
& dotnet (Join-Path $PSScriptRoot 'ReleaseBoundary/bin/Release/net10.0/ReleaseBoundary.dll') check $RuntimeIdentifier $target --repo-root $root --evidence $evidence
if ($LASTEXITCODE -ne 0) { throw "Release boundary inspection failed for $RuntimeIdentifier (see the IDENTITY, FORBIDDEN and UNAPPROVED lines above)." }
Write-Host "Release boundary inspection passed for $RuntimeIdentifier; evidence in $evidence"
