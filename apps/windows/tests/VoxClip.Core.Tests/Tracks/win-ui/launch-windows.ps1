param([ValidateSet('editor', 'home', 'settings')][string]$Screen = 'editor', [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug', [string]$Root = 'C:\voxclip-build\win-ui')
$ErrorActionPreference = 'Stop'
$root = $Root
$env:VOXCLIP_DATA_DIR = Join-Path $root 'capture-data'
$exe = Join-Path $root "apps\windows\src\VoxClip.App\bin\ARM64\$Configuration\net10.0-windows10.0.26100.0\win-arm64\VoxClip.exe"
$captureFixture = Join-Path $root 'capture-project.voxclip'
$fixture = if (Test-Path $captureFixture) { $captureFixture } else { Join-Path $root 'shared\fixtures\projects\interview-take.voxclip' }
$report = Join-Path $root "screenshots\$Screen-self-check.json"
if ($Configuration -eq 'Release') {
    if ($Screen -ne 'home') { throw 'Release probes support Home only; fixture mode is debug-only.' }
    & $exe --self-check $report
} else {
    & $exe --demo-project $fixture --demo-screen $Screen --self-check $report
}
