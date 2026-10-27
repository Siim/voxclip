param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$TestToolsZip, [Parameter(Mandatory = $true)][string]$AcceptedDataRoot)
# $AcceptedDataRoot is an isolated data root in which the bundled Windows runtime terms were accepted explicitly, as
# native-accessibility-walk.ps1 requires. The shell probe runs on a fresh root that carries only that receipt, so its
# settings (no connector, no recent projects) are the defaults.
$ErrorActionPreference = 'Stop'
$project = Join-Path $Root 'apps\windows\tests\VoxClip.Core.Tests\Tracks\win-ui\VoxClip.Ui.Tests.csproj'
$evidence = Join-Path $Root 'native-flow-evidence'
$tools = Join-Path $Root 'test-only-ffmpeg'
$receipt = Join-Path $AcceptedDataRoot 'windows-runtime-agreement.txt'
if (-not (Test-Path -LiteralPath $receipt)) { throw 'Accept the bundled Windows runtime terms explicitly in the isolated data root first.' }
if ((Get-FileHash -LiteralPath $TestToolsZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'ceeb03d5354e5213a0e8f36046edbca2c07e03780cb3984469feffb6a99c40fd') {
    throw 'The test-only FFmpeg archive does not match the reviewed hash.'
}
New-Item -ItemType Directory -Force $evidence | Out-Null
Push-Location $Root
$probeData = Join-Path $Root ('shell-probe-data-' + [Guid]::NewGuid().ToString('N'))
$probeApp = $null
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

    # The Debug-only shell probe (Services/ShellNativeProbe.cs): Home, Recent, drop, close and the sidebar header rows
    # through the save-before-leaving boundary, in the real window.
    & 'C:\Program Files\dotnet\dotnet.exe' build (Join-Path $Root 'apps\windows\src\VoxClip.App\VoxClip.App.csproj') -c Debug -r win-arm64 '-p:Platform=ARM64' -m:1 --disable-build-servers '-p:UseSharedCompilation=false' 2>&1 | Tee-Object (Join-Path $evidence 'app-debug-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Debug App build for the shell probe failed.' }
    New-Item -ItemType Directory -Force $probeData | Out-Null
    Copy-Item -LiteralPath $receipt -Destination $probeData
    $probe = Join-Path $evidence 'shell-probe'
    $report = Join-Path $probe 'shell-native-result.json'
    $start = New-Object System.Diagnostics.ProcessStartInfo((Join-Path $Root 'apps\windows\src\VoxClip.App\bin\ARM64\Debug\net10.0-windows10.0.26100.0\win-arm64\VoxClip.exe'))
    $start.UseShellExecute = $false
    $start.Arguments = "--shell-probe `"$probe`""
    $start.EnvironmentVariables['VOXCLIP_DATA_DIR'] = $probeData
    $start.EnvironmentVariables['VOXCLIP_SHARED_DIR'] = Join-Path $Root 'shared'
    $probeApp = [System.Diagnostics.Process]::Start($start)
    # A passing probe exits the app; a failing one writes its report and leaves the window open with the error.
    for ($i = 0; $i -lt 360 -and -not $probeApp.HasExited -and -not (Test-Path -LiteralPath $report); $i++) { Start-Sleep -Milliseconds 500 }
    for ($i = 0; $i -lt 20 -and -not $probeApp.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path -LiteralPath $report)) { throw 'The shell probe wrote no report within three minutes.' }
    $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($result.status -ne 'passed') { throw "The shell probe failed: $($result.error)" }
    Write-Output "Shell probe passed $(@($result.checks).Count) checks."
} finally {
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
