param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$TestToolsZip, [Parameter(Mandatory = $true)][string]$AcceptedDataRoot, [ValidateSet('win-x64','win-arm64')][string]$RuntimeIdentifier = 'win-arm64')
# $AcceptedDataRoot is an isolated data root in which the bundled Windows runtime terms were accepted explicitly, as
# native-accessibility-walk.ps1 requires. The shell probe runs on a fresh root that carries only that receipt, so its
# settings (no connector, no recent projects) are the defaults.
$ErrorActionPreference = 'Stop'
$project = Join-Path $Root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\VoxClip.Ui.Tests.csproj'
$evidence = Join-Path $Root "native-flow-evidence\$RuntimeIdentifier"
$tools = Join-Path $Root "test-only-ffmpeg\$RuntimeIdentifier"
$platform = if ($RuntimeIdentifier -eq 'win-arm64') { 'ARM64' } else { 'x64' }
$pin = Get-Content (Join-Path $Root 'apps\windows\build\ffmpeg.json') -Raw | ConvertFrom-Json
$receipt = Join-Path $AcceptedDataRoot 'windows-runtime-agreement.txt'
if (-not (Test-Path -LiteralPath $receipt)) { throw 'Accept the bundled Windows runtime terms explicitly in the isolated data root first.' }
if ((Get-FileHash -LiteralPath $TestToolsZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.testTools.$RuntimeIdentifier.sha256) {
    throw 'The test-only FFmpeg archive does not match the reviewed hash.'
}
New-Item -ItemType Directory -Force $evidence | Out-Null
Push-Location $Root
$probeData = Join-Path $Root ('shell-probe-data-' + [Guid]::NewGuid().ToString('N'))
$probeApp = $null
$phase = 'build companion'
$status = 'failed'
$failure = $null
function Assert-BuildSpace([long]$FreeBytes = (Get-PSDrive -Name ([IO.Path]::GetPathRoot($Root).TrimEnd('\').TrimEnd(':'))).Free) {
    if ($FreeBytes -lt (6GB + 1536MB)) { throw 'Native runs require 1.5 GiB headroom above the 6 GiB floor; keep owned scratch below 2 GiB.' }
}
try {
    Assert-BuildSpace
    & 'C:\Program Files\dotnet\dotnet.exe' build $project -c Release -r $RuntimeIdentifier "-p:Platform=$platform" -p:SelfContained=true -p:UseAppHost=true -m:1 --disable-build-servers '-p:UseSharedCompilation=false' 2>&1 | Tee-Object (Join-Path $evidence 'build.log')
    if ($LASTEXITCODE -ne 0) { throw 'UI companion native build failed.' }
    Expand-Archive -LiteralPath $TestToolsZip -DestinationPath $tools -Force
    $outputs = @(Get-ChildItem (Join-Path $Root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\.artifacts\bin') -Filter 'VoxClip.Ui.Tests.dll' -Recurse | Where-Object { $_.FullName -like "*Release*$RuntimeIdentifier*" })
    if ($outputs.Count -ne 1) { throw "Expected one $RuntimeIdentifier UI companion output; found $($outputs.Count)." }
    $toolBin = @(Get-ChildItem $tools -Filter 'ffmpeg.exe' -Recurse)
    if ($toolBin.Count -ne 1) { throw 'Expected exactly one pinned test-tools binary directory.' }
    Copy-Item (Join-Path $toolBin[0].DirectoryName '*.dll') $outputs[0].DirectoryName -Force
    $env:VOXCLIP_UI_NATIVE_FIXTURE = Join-Path $Root 'shared\fixtures\media\bars-1080p.mp4'
    $env:VOXCLIP_UI_EVIDENCE_DIR = $evidence
    $env:VOXCLIP_UI_NATIVE_RUNTIME = $RuntimeIdentifier
    $env:VOXCLIP_DATA_DIR = Join-Path $Root 'test-data'
    $companion = Join-Path $outputs[0].DirectoryName 'VoxClip.Ui.Tests.exe'
    if (-not (Test-Path -LiteralPath $companion)) { throw 'The architecture-matched self-contained test host is missing.' }
    Assert-BuildSpace
    $phase = 'native companion'
    & $companion -noLogo 2>&1 | Tee-Object (Join-Path $evidence 'test.log')
    if ($LASTEXITCODE -ne 0) { throw 'Native UI companion test failed.' }

    # The Debug-only shell probe (Services/ShellNativeProbe.cs): Home, Recent, drop, close and the sidebar header rows
    # through the save-before-leaving boundary, in the real window.
    $phase = 'build shell'
    Assert-BuildSpace
    & 'C:\Program Files\dotnet\dotnet.exe' build (Join-Path $Root 'apps\windows\src\VoxClip.App\VoxClip.App.csproj') -c Debug -r $RuntimeIdentifier "-p:Platform=$platform" -m:1 --disable-build-servers '-p:UseSharedCompilation=false' 2>&1 | Tee-Object (Join-Path $evidence 'app-debug-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Debug App build for the shell probe failed.' }
    New-Item -ItemType Directory -Force $probeData | Out-Null
    Copy-Item -LiteralPath $receipt -Destination $probeData
    $probe = Join-Path $evidence 'shell-probe'
    $report = Join-Path $probe 'shell-native-result.json'
    $start = New-Object System.Diagnostics.ProcessStartInfo((Join-Path $Root "apps\windows\src\VoxClip.App\bin\$platform\Debug\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"))
    $start.UseShellExecute = $false
    $start.Arguments = "--shell-probe `"$probe`""
    $start.EnvironmentVariables['VOXCLIP_DATA_DIR'] = $probeData
    $start.EnvironmentVariables['VOXCLIP_SHARED_DIR'] = Join-Path $Root 'shared'
    $probeApp = [System.Diagnostics.Process]::Start($start)
    # A passing probe exits the app; a failing one writes its report and leaves the window open with the error.
    $phase = 'shell'
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    while (-not $probeApp.HasExited -and -not (Test-Path -LiteralPath $report) -and $elapsed.Elapsed.TotalSeconds -lt 900) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path -LiteralPath $report)) { throw 'The shell probe wrote no report within 900 monotonic seconds.' }
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($result.status -ne 'passed') { throw ('The shell probe failed: ' + (@($result.checks | Where-Object { $_ -like 'FAILED native gate:*' }) -join ', ') + '; see shell-native-result.json.') }
    $exitWait = [Diagnostics.Stopwatch]::StartNew()
    while (-not $probeApp.HasExited -and $exitWait.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
    if ($probeApp.HasExited -and $probeApp.ExitCode -ne 0) { throw 'The shell probe exited unsuccessfully after its report.' }
    Write-Output "Shell probe passed $(@($result.checks).Count) checks."
    $status = 'passed'
} catch {
    $failure = $_.Exception.Message
    throw
} finally {
    @{ status = $status; phase = $phase; runtime = $RuntimeIdentifier; failure = $failure } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'native-flow-result.json') -Encoding ASCII
    # Wait for a stopped probe to exit, so it no longer holds its log or data root open when they are copied and removed.
    if ($probeApp -and -not $probeApp.HasExited) {
        Stop-Process -Id $probeApp.Id -Force -ErrorAction SilentlyContinue
        [void]$probeApp.WaitForExit(15000)
    }
    if (Test-Path -LiteralPath $probeData) {
        Copy-Item (Join-Path $probeData 'Logs\voxclip.log') (Join-Path $evidence 'shell-probe.log') -ErrorAction SilentlyContinue
        try { Remove-Item -LiteralPath $probeData -Recurse -Force }
        catch { Write-Warning "The shell probe's data root could not be removed: $($_.Exception.Message)" }
    }
    Pop-Location
}
