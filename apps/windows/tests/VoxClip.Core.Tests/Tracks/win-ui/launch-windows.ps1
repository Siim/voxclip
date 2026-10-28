param([ValidateSet('editor', 'home', 'settings')][string]$Screen = 'editor', [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug', [string]$Root = 'C:\voxclip-build\win-ui', [ValidateSet('win-x64', 'win-arm64')][string]$RuntimeIdentifier = 'win-arm64', [ValidateSet('1440x900', '1440x960', '1280x800', '1024x700', '900x720')][string]$WindowSize = '1440x900')
$ErrorActionPreference = 'Stop'
$root = $Root
$env:VOXCLIP_DATA_DIR = Join-Path $root 'capture-data'
$platform = if ($RuntimeIdentifier -eq 'win-arm64') { 'ARM64' } else { 'x64' }
$exe = Join-Path $root "apps\windows\src\VoxClip.App\bin\$platform\$Configuration\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"
if (-not (Test-Path -LiteralPath $exe)) { throw "Build the $RuntimeIdentifier $Configuration App before capturing." }
$captureFixture = Join-Path $root 'capture-project.voxclip'
$fixture = if (Test-Path $captureFixture) { $captureFixture } else { Join-Path $root 'shared\fixtures\projects\interview-take.voxclip' }
$report = Join-Path $root "screenshots\$Screen-self-check.json"
if ($Configuration -eq 'Release') {
    if ($Screen -ne 'home') { throw 'Release probes support Home only; fixture mode is debug-only.' }
    & $exe --self-check $report
} else {
    & $exe --demo-project $fixture --demo-screen $Screen --self-check $report "--window-size=$WindowSize" --capture-appearance=light --capture-fixture
}
