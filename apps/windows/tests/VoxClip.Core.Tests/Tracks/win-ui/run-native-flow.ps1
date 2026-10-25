param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$TestToolsZip)
$ErrorActionPreference = 'Stop'
$project = Join-Path $Root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\VoxClip.Ui.Tests.csproj'
$evidence = Join-Path $Root 'native-flow-evidence'
$tools = Join-Path $Root 'test-only-ffmpeg'
if ((Get-FileHash -LiteralPath $TestToolsZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'ceeb03d5354e5213a0e8f36046edbca2c07e03780cb3984469feffb6a99c40fd') {
    throw 'The test-only FFmpeg archive does not match the reviewed hash.'
}
New-Item -ItemType Directory -Force $evidence | Out-Null
Push-Location $Root
try {
    & 'C:\Program Files\dotnet\dotnet.exe' build $project -c Release -r win-arm64 '-p:Platform=ARM64' -m:1 --disable-build-servers '-p:UseSharedCompilation=false' 2>&1 | Tee-Object (Join-Path $evidence 'build.log')
    if ($LASTEXITCODE -ne 0) { throw 'UI companion native build failed.' }
    Expand-Archive -LiteralPath $TestToolsZip -DestinationPath $tools -Force
    $outputs = @(Get-ChildItem (Join-Path $Root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\.artifacts\bin') -Filter 'VoxClip.Ui.Tests.dll' -Recurse | Where-Object { $_.FullName -like '*Release*win-arm64*' })
    if ($outputs.Count -ne 1) { throw "Expected one ARM64 UI companion output; found $($outputs.Count)." }
    Copy-Item (Join-Path $tools 'bin\*.dll') $outputs[0].DirectoryName -Force
    $env:VOXCLIP_UI_NATIVE_FIXTURE = Join-Path $Root 'shared\fixtures\media\bars-1080p.mp4'
    $env:VOXCLIP_UI_EVIDENCE_DIR = $evidence
    $env:VOXCLIP_DATA_DIR = Join-Path $Root 'test-data'
    & 'C:\Program Files\dotnet\dotnet.exe' $outputs[0].FullName -noLogo 2>&1 | Tee-Object (Join-Path $evidence 'test.log')
    if ($LASTEXITCODE -ne 0) { throw 'Native UI companion test failed.' }
} finally {
    Pop-Location
}
