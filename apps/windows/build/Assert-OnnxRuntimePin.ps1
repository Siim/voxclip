<#
.SYNOPSIS
Fails unless a built or published VoxClip.App folder carries exactly the pinned ONNX Runtime.

.DESCRIPTION
The speaker check loads onnxruntime.dll from the App folder. That file and onnxruntime_providers_shared.dll must be
byte-identical to runtimes/<rid>/native in the Microsoft.ML.OnnxRuntime package pinned in Directory.Packages.props, and
the managed Microsoft.ML.OnnxRuntime.dll binding must have the same version. The package files must also match the
reviewed nuget.org hashes below, so a modified local NuGet cache cannot pass. No other onnxruntime*.dll may ship anywhere
in the folder, and neither may Windows ML, DirectML or the excluded Windows App SDK AI, Search and Widgets components.
CI runs it on both Release build outputs; vm-release.ps1 runs it on both published release payloads before signing.

.EXAMPLE
build/Assert-OnnxRuntimePin.ps1 -AppDirectory src/VoxClip.App/bin/x64/Release/net10.0-windows10.0.26100.0/win-x64 -RuntimeIdentifier win-x64
#>
param(
    [Parameter(Mandatory = $true)][string] $AppDirectory,
    [Parameter(Mandatory = $true)][ValidateSet('win-x64', 'win-arm64')][string] $RuntimeIdentifier,
    [string] $PackagesRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PackagesRoot) {
    $PackagesRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget/packages' }
}
[xml] $pins = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Directory.Packages.props') -Raw
$pin = @($pins.SelectNodes("//PackageVersion[@Include='Microsoft.ML.OnnxRuntime']"))
if ($pin.Count -ne 1) { throw 'Directory.Packages.props must pin Microsoft.ML.OnnxRuntime exactly once.' }
$version = $pin[0].GetAttribute('Version')
# SHA-256 of the natives in the nuget.org package, whose SHA-512 matched the nuget.org catalog on 2026-10-31.
# Bumping Microsoft.ML.OnnxRuntime requires recording the new package's reviewed values here.
$reviewed = @{
    '1.19.2' = @{
        'win-x64/onnxruntime.dll' = '14119125df2dcf9ff3e083afdba5fcc4b09b4186d8762404eb7b1fbccde3fcf2'
        'win-x64/onnxruntime_providers_shared.dll' = '7d11a2a851ad86095a7ad1f4d96927ff0a48fa86311699fbb6a7c21914bbb69f'
        'win-arm64/onnxruntime.dll' = '2e2f59400be789072e4b1aa572f7041d4e0378f7c9cbcbb30e55485eb75bfe2c'
        'win-arm64/onnxruntime_providers_shared.dll' = 'd0384f674bb7df302e8253dbc8439d8540b6070d1485d3e79bc1f0684f737eab'
    }
}
if (-not $reviewed.ContainsKey($version)) { throw "Record the reviewed nuget.org SHA-256 values of the Microsoft.ML.OnnxRuntime $version natives in Assert-OnnxRuntimePin.ps1." }
if (-not (Test-Path -LiteralPath $AppDirectory -PathType Container)) { throw "The App output folder is missing: $AppDirectory" }
$root = (Get-Item -LiteralPath $AppDirectory).FullName.TrimEnd('\', '/')
$native = Join-Path $PackagesRoot "microsoft.ml.onnxruntime/$version/runtimes/$RuntimeIdentifier/native"
$failures = @()

foreach ($name in @('onnxruntime.dll', 'onnxruntime_providers_shared.dll')) {
    $expected = Join-Path $native $name
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { throw "The pinned package file is missing: $expected" }
    $expectedHash = (Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedHash -ne $reviewed[$version]["$RuntimeIdentifier/$name"]) {
        $failures += "the package cache's $name is not the reviewed nuget.org Microsoft.ML.OnnxRuntime $version $RuntimeIdentifier file"
    }
    $actual = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $actual -PathType Leaf)) {
        $failures += "$name is missing"
        continue
    }
    $actualHash = (Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash.ToLowerInvariant()
    $fileVersion = (Get-Item -LiteralPath $actual).VersionInfo.FileVersion
    Write-Output "${RuntimeIdentifier} ${name}: sha256 $actualHash, file version $fileVersion"
    Write-Output "  pinned Microsoft.ML.OnnxRuntime $version runtimes/$RuntimeIdentifier/native/${name}: sha256 $expectedHash"
    if ($actualHash -ne $expectedHash) { $failures += "$name is not the pinned Microsoft.ML.OnnxRuntime $version $RuntimeIdentifier file" }
}

$managed = Join-Path $root 'Microsoft.ML.OnnxRuntime.dll'
if (-not (Test-Path -LiteralPath $managed -PathType Leaf)) {
    $failures += 'Microsoft.ML.OnnxRuntime.dll is missing'
} else {
    $assemblyVersion = [Reflection.AssemblyName]::GetAssemblyName($managed).Version
    Write-Output "${RuntimeIdentifier} Microsoft.ML.OnnxRuntime.dll: assembly version $assemblyVersion"
    if ($assemblyVersion.ToString(3) -ne $version) { $failures += "Microsoft.ML.OnnxRuntime.dll is $assemblyVersion, not $version" }
}

# Excluded with ExcludeAssets="all" in VoxClip.App.csproj; any of these names means a component came back.
$excluded = @('DirectML*.dll', 'Microsoft.Windows.AI.*', 'Microsoft.Windows.Search*', 'Microsoft.Windows.Widgets*',
    'Microsoft.Windows.Workloads*', 'Microsoft.Graphics.Imaging*')
$allowed = @('onnxruntime.dll', 'onnxruntime_providers_shared.dll')
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File)
foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    if ($file.Name -like 'onnxruntime*.dll' -and $allowed -notcontains $relative) { $failures += "unexpected ONNX Runtime library: $relative" }
    foreach ($pattern in $excluded) {
        if ($file.Name -like $pattern) { $failures += "excluded Windows component file: $relative" }
    }
}

if ($failures.Count) {
    foreach ($failure in $failures) { Write-Output "FAIL: $failure" }
    throw "ONNX Runtime pin check failed for ${RuntimeIdentifier}: $($failures.Count) problem(s): $($failures -join '; ')"
}
Write-Output "PASS: $RuntimeIdentifier ships only the pinned Microsoft.ML.OnnxRuntime $version runtime ($($files.Count) files checked; no Windows ML, DirectML or other ONNX Runtime)."
