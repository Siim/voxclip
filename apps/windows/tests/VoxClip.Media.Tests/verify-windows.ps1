param([string]$LockOwner = '', [string]$FfmpegDirectory = $env:VOXCLIP_FFMPEG_DIR, [switch]$WithoutEncoders, [switch]$DiagnoseMf, [switch]$ManagedOnly,
    [switch]$ShippingAcceptance, [switch]$FocusedCaptions, [switch]$DiagnoseColorPath, [switch]$ConversionTiming, [switch]$ConversionTimingOnly, [string]$ShippingRid = '', [string]$BuildReport = '',
    [string]$ScratchRoot = 'C:\voxclip-build\win-media')
$ErrorActionPreference = 'Stop'
if ($ScratchRoot -notmatch '^C:\\voxclip-build\\[a-z0-9][a-z0-9-]*$') { throw 'The scratch root must be one track directory directly under C:\voxclip-build.' }
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..'))
if (-not $PWD.Path.StartsWith("$ScratchRoot\", [StringComparison]::OrdinalIgnoreCase)) { throw "Run only in an archived workspace under $ScratchRoot." }
if (-not (Test-Path 'C:\voxclip-build\vm.lock\owner') -or (Get-Content 'C:\voxclip-build\vm.lock\owner') -ne $LockOwner) { throw 'The caller must own the VM lock.' }
if (-not $ManagedOnly -and (-not $FfmpegDirectory -or (-not $ShippingAcceptance -and -not (Test-Path $FfmpegDirectory)))) { throw 'Pass -FfmpegDirectory with the self-built LGPL FFmpeg 9 native directory.' }
if ($FfmpegDirectory -and -not $FfmpegDirectory.StartsWith("$ScratchRoot\", [StringComparison]::OrdinalIgnoreCase)) { throw "Copy approved DLLs into $ScratchRoot first." }
$env:VOXCLIP_FFMPEG_DIR = $FfmpegDirectory
$env:VOXCLIP_REQUIRE_NATIVE = '1'
# The VM has a default audio output device, so the full and shipping-acceptance runs fail the real WASAPI preview test without one.
$env:VOXCLIP_REQUIRE_AUDIO_OUTPUT = '1'
$env:VOXCLIP_DATA_DIR = Join-Path $PWD 'apps\windows\tests\VoxClip.Media.Tests\.runs\data'
$env:VOXCLIP_SHARED_DIR = Join-Path $PWD 'shared'
$env:VOXCLIP_E2E_OUT = Join-Path $PWD 'apps\windows\tests\VoxClip.Media.Tests\.runs\e2e'
$env:VOXCLIP_REQUIRE_E2E = '1'
$env:VOXCLIP_LIVE_TESTS = '0'
$env:VOXCLIP_TEST_DOWNLOAD = '0'
$env:MSBUILDDISABLENODEREUSE = '1'
$env:DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER = '1'
$env:UseSharedCompilation = 'false'
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
$workspaceRoot = $PWD.Path
$runs = Join-Path $PWD 'apps\windows\tests\VoxClip.Media.Tests\.runs'
New-Item -ItemType Directory -Force $runs | Out-Null
Set-Content (Join-Path $runs 'runner.pid') $PID
function Assert-ScratchBudget {
    $free = (Get-PSDrive C).Free
    if ($free -lt 6GB) { throw "C: free space fell below 6 GiB: $free bytes." }
    $owned = (Get-ChildItem $workspaceRoot -Recurse -File -ErrorAction Stop | Measure-Object Length -Sum).Sum
    if ($owned -gt 2GB) { throw "Owned workspace scratch exceeded 2 GiB: $owned bytes." }
    Write-Output ("C: free GiB: {0:N2}; owned scratch MiB: {1:N1}" -f ($free / 1GB), ($owned / 1MB))
}
$acceptanceFailures = [System.Collections.Generic.List[string]]::new()
$collectFailures = $false
function Invoke-Bounded([string]$Name, [string[]]$Arguments, [int]$Seconds, [int]$ExpectedExit = 0, [string]$Executable = $dotnet) {
    $stdout = Join-Path $runs ($Name + '.out.log')
    $stderr = Join-Path $runs ($Name + '.err.log')
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle
    try {
        if (-not $process.WaitForExit($Seconds * 1000)) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            throw "$Name exceeded $Seconds seconds."
        }
        $process.WaitForExit()
        Get-Content $stdout
        Get-Content $stderr
        Write-Output "$Name exit code: $($process.ExitCode)"
        if ($ExpectedExit -ge 0 -and $process.ExitCode -ne $ExpectedExit) {
            $failure = "$Name failed: $($process.ExitCode); expected $ExpectedExit"
            if ($collectFailures) { $acceptanceFailures.Add($failure) } else { throw $failure }
        }
    } finally {
        if (-not $process.HasExited) {
            & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
            $null = $process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}
try {
    if ($ShippingAcceptance) {
        if ($ShippingRid -notin @('win-arm64', 'win-x64')) { throw 'Shipping RID must be win-arm64 or win-x64.' }
        if (-not (Test-Path $BuildReport)) { throw 'Audited build report is missing.' }
        Assert-ScratchBudget
        $manifest = Get-Content 'apps\windows\build\ffmpeg.json' -Raw | ConvertFrom-Json
        $report = Get-Content $BuildReport -Raw | ConvertFrom-Json
        $pin = $manifest.builds.PSObject.Properties[$ShippingRid].Value
        $archive = Join-Path $PWD 'ffmpeg.zip'
        if ($report.rid -ne $ShippingRid -or $report.buildInputsSha256 -ne $manifest.buildInputsSha256 -or
            $report.archive -ne $pin.name -or $report.sha256 -ne $pin.sha256 -or $report.size -ne $pin.size -or
            (Get-Item $archive).Length -ne $pin.size -or (Get-FileHash $archive -Algorithm SHA256).Hash -ne $pin.sha256) {
            throw 'Shipping archive/report does not match the committed manifest.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $PWD 'native') -ErrorAction Stop
        $expected = @('avcodec-63.dll', 'avformat-63.dll', 'avutil-61.dll', 'avfilter-12.dll', 'swresample-7.dll', 'swscale-10.dll')
        $actual = @(Get-ChildItem $FfmpegDirectory -File | Select-Object -ExpandProperty Name)
        if (@(Compare-Object $expected $actual).Count -ne 0) { throw 'Shipping archive has a different DLL set.' }
        foreach ($name in $expected) {
            $dll = Join-Path $FfmpegDirectory $name
            $record = $report.dlls.PSObject.Properties[$name].Value
            if (-not $record -or (Get-Item $dll).Length -ne $record.size -or
                (Get-FileHash $dll -Algorithm SHA256).Hash -ne $record.sha256) { throw "Shipping DLL mismatch: $name" }
        }
        $env:VOXCLIP_SHIPPING_REPORT = $BuildReport
        $env:VOXCLIP_MODULE_EVIDENCE = Join-Path $runs 'loaded-modules.json'
        $env:VOXCLIP_CLI_MODULE_EVIDENCE = Join-Path $runs 'loaded-cli-modules.json'
        $env:VOXCLIP_REQUIRE_VM_EVIDENCE = '1'
        Assert-ScratchBudget
    }
    Set-Location apps\windows
    if ($DiagnoseMf) {
        $ffmpeg = Get-ChildItem $FfmpegDirectory -Filter ffmpeg.exe | Select-Object -First 1
        if (-not $ffmpeg) { throw 'The optional MF diagnostic needs ffmpeg.exe in -FfmpegDirectory, including lavfi/testsrc2.' }
        Invoke-Bounded 'mf-buildconf' @('-hide_banner', '-buildconf') 15 0 $ffmpeg.FullName
        Invoke-Bounded 'mf-help' @('-hide_banner', '-h', 'encoder=h264_mf') 15 0 $ffmpeg.FullName
        Invoke-Bounded 'mf-minimal' @('-hide_banner', '-loglevel', 'debug', '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=30', '-t', '2', '-an', '-pix_fmt', 'nv12', '-c:v', 'h264_mf', '-hw_encoding', '0', '-y', (Join-Path $runs 'mf-minimal.mp4')) 45 -1 $ffmpeg.FullName
        Invoke-Bounded 'mf-configured' @('-hide_banner', '-loglevel', 'debug', '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=30', '-t', '2', '-an', '-pix_fmt', 'nv12', '-c:v', 'h264_mf', '-hw_encoding', '0', '-profile:v', '100', '-rate_control', 'pc_vbr', '-b:v', '4000000', '-g', '60', '-y', (Join-Path $runs 'mf-configured.mp4')) 45 -1 $ffmpeg.FullName
        Write-Output ('Windows encoder DLL present: ' + (Test-Path C:\Windows\System32\msmpeg2venc.dll))
        Get-CimInstance Win32_OperatingSystem | Select-Object Caption, OSArchitecture
    }
    $buildArgs = @('build', 'VoxClip.CrossPlatform.slnf', '-c', 'Release', '--nologo', '-m:1', '-p:UseSharedCompilation=false', '-nodeReuse:false')
    if ($ShippingAcceptance) { $buildArgs += '-p:RestoreSources=C:\Users\siim\.nuget\packages' }
    Invoke-Bounded 'build' $buildArgs 300
    if ($ShippingAcceptance -and $ShippingRid -eq 'win-x64') {
        $publishArgs = @('publish', 'tests\VoxClip.Media.Tests\VoxClip.Media.Tests.csproj', '-c', 'Release', '-r', 'win-x64',
            '--self-contained', 'true', '--nologo', '-m:1', '-p:UseAppHost=true', '-p:UseSharedCompilation=false',
            '-nodeReuse:false', '-p:RestoreSources=C:\Users\siim\.nuget\packages', '-o', (Join-Path $runs 'x64-tests'))
        Invoke-Bounded 'publish-x64-tests' $publishArgs 360
        $publishArgs[1] = 'src\VoxClip.Cli\VoxClip.Cli.csproj'
        $publishArgs[-1] = Join-Path $runs 'x64-cli'
        Invoke-Bounded 'publish-x64-cli' $publishArgs 360
        Assert-ScratchBudget
    }
    if ($ShippingAcceptance) {
        Assert-ScratchBudget
        if ($ShippingRid -eq 'win-x64') {
            $cliOutput = Join-Path $runs 'x64-cli'
            $testExecutable = Join-Path $runs 'x64-tests\VoxClip.Media.Tests.exe'
            $env:VOXCLIP_CLI = Join-Path $cliOutput 'voxclip-cli.exe'
        } else {
            $cliOutput = Join-Path $PWD 'src\VoxClip.Cli\bin\Release\net10.0'
            $testExecutable = Join-Path $PWD 'tests\VoxClip.Media.Tests\bin\Release\net10.0\VoxClip.Media.Tests.dll'
            $env:VOXCLIP_CLI = Join-Path $cliOutput 'voxclip-cli.dll'
        }
        Copy-Item (Join-Path $FfmpegDirectory '*.dll') $cliOutput -Force
        if ($ConversionTimingOnly) {
            $env:VOXCLIP_CONVERSION_TIMING = '1'
            $env:VOXCLIP_NATIVE_CONVERSION_PROBE = '1'
            $timingArgs = if ($ShippingRid -eq 'win-x64') { @('-class', 'VoxClip.Media.Tests.Bt709ConversionTimingTests', '-showLiveOutput') } else { @($testExecutable, '-class', 'VoxClip.Media.Tests.Bt709ConversionTimingTests', '-showLiveOutput') }
            $timingRunner = if ($ShippingRid -eq 'win-x64') { $testExecutable } else { $dotnet }
            Invoke-Bounded 'conversion-probe' $timingArgs 180 0 $timingRunner
            Assert-ScratchBudget
            return
        }
        $collectFailures = $true
        $converterArgs = if ($ShippingRid -eq 'win-x64') { @('-class', 'VoxClip.Media.Tests.Bt709BgraConverterTests') } else { @($testExecutable, '-class', 'VoxClip.Media.Tests.Bt709BgraConverterTests') }
        $converterRunner = if ($ShippingRid -eq 'win-x64') { $testExecutable } else { $dotnet }
        Invoke-Bounded 'shipping-converter' $converterArgs 90 0 $converterRunner
        if ($ConversionTiming) {
            $env:VOXCLIP_CONVERSION_TIMING = '1'
            $timingArgs = if ($ShippingRid -eq 'win-x64') { @('-class', 'VoxClip.Media.Tests.Bt709ConversionTimingTests', '-showLiveOutput') } else { @($testExecutable, '-class', 'VoxClip.Media.Tests.Bt709ConversionTimingTests', '-showLiveOutput') }
            $timingRunner = if ($ShippingRid -eq 'win-x64') { $testExecutable } else { $dotnet }
            Invoke-Bounded 'conversion-timing' $timingArgs 180 0 $timingRunner
            Remove-Item Env:VOXCLIP_CONVERSION_TIMING
        }
        if ($DiagnoseColorPath) {
            $env:VOXCLIP_DIAGNOSE_COLOR_PATHS = '1'
            if ($ShippingRid -eq 'win-x64') {
                Invoke-Bounded 'color-paths' @('-class', 'VoxClip.Media.Tests.E2E.ColorPathDiagnostics') 180 0 $testExecutable
            } else {
                Invoke-Bounded 'color-paths' @($testExecutable, '-class', 'VoxClip.Media.Tests.E2E.ColorPathDiagnostics') 180
            }
        } elseif ($FocusedCaptions) {
            $testRunner = if ($ShippingRid -eq 'win-x64') { $testExecutable } else { $dotnet }
            $prefix = @()
            if ($ShippingRid -ne 'win-x64') { $prefix = @($testExecutable) }
            Invoke-Bounded 'focused-opacity' ($prefix + @('-class', 'VoxClip.Media.Tests.Captions.CaptionOpacityTests')) 180 0 $testRunner
            Invoke-Bounded 'focused-goldens' ($prefix + @('-class', 'VoxClip.Media.Tests.Captions.CaptionConformanceTests', '-method', 'VoxClip.Media.Tests.Captions.CaptionConformanceTests.CommittedGoldensMatchEverySampleAndGalleryTile')) 300 0 $testRunner
            Invoke-Bounded 'focused-shadow' ($prefix + @('-class', 'VoxClip.Media.Tests.Captions.CaptionRenderStateTests', '-method', 'VoxClip.Media.Tests.Captions.CaptionRenderStateTests.ShadowScratchStaysFlatAcrossFiftyAndThreeHundredPages')) 180 0 $testRunner
        } else {
            $testArgs = if ($ShippingRid -eq 'win-x64') { @('-class', 'VoxClip.Media.Tests.ShippingRuntimeIdentityTests') } else { @($testExecutable, '-class', 'VoxClip.Media.Tests.ShippingRuntimeIdentityTests') }
            $testRunner = if ($ShippingRid -eq 'win-x64') { $testExecutable } else { $dotnet }
            $cleanupArgs = if ($ShippingRid -eq 'win-x64') { @('-class', 'VoxClip.Media.Tests.E2E.CliProcessCleanupTests') } else { @($testExecutable, '-class', 'VoxClip.Media.Tests.E2E.CliProcessCleanupTests') }
            Invoke-Bounded 'shipping-cleanup' $cleanupArgs 90 0 $testRunner
            Invoke-Bounded 'shipping-modules' $testArgs 90 0 $testRunner
            foreach ($suite in @(
                @('shipping-e2e', 'VoxClip.Media.Tests.E2E.MediaCliE2ETests', 900),
                @('shipping-colour', 'VoxClip.Media.Tests.E2E.SoftwareMfBarColorTests', 180),
                @('shipping-native-conformance', 'VoxClip.Media.Tests.NativeMediaConformanceTests', 180),
                @('shipping-native-pipeline', 'VoxClip.Media.Tests.NativePipelineTests', 300),
                @('shipping-windows-pipeline', 'VoxClip.Media.Tests.WindowsPipelineTests', 300),
                @('shipping-preview-audio', 'VoxClip.Media.Tests.VoiceLabAudioMixerTests', 180))) {
                $arguments = if ($ShippingRid -eq 'win-x64') { @('-class', $suite[1]) } else { @($testExecutable, '-class', $suite[1]) }
                if ($suite[0] -eq 'shipping-native-pipeline') { $arguments += @('-method-', 'VoxClip.Media.Tests.NativePipelineTests.DecoderReconfiguresWhenAudioChannelsChange') }
                if ($suite[0] -eq 'shipping-windows-pipeline') { $arguments += @('-method-', 'VoxClip.Media.Tests.WindowsPipelineTests.IdentityExportAndPreviewAudioStartSeekFromZero') }
                if ($suite[0] -eq 'shipping-preview-audio') { $arguments += @('-method', 'VoxClip.Media.Tests.VoiceLabAudioMixerTests.NativePreviewPlaysPausesSeeksAndReleasesSynthLease') }
                Invoke-Bounded $suite[0] $arguments $suite[2] 0 $testRunner
            }
        }
        Assert-ScratchBudget
        if ($acceptanceFailures.Count -gt 0) { throw ($acceptanceFailures -join '; ') }
        return
    }
    if ($ManagedOnly) {
        Invoke-Bounded 'managed-tests' @('test', '--project', 'tests\VoxClip.Media.Tests', '-c', 'Release', '--no-build', '--filter-not-trait', 'Category=RequiresFFmpeg', '--filter-not-trait', 'Category=RequiresWindows') 180
        Write-Output 'Managed verification only. Native FFmpeg acceptance remains pending.'
        return
    }
    $collectFailures = $true
    Copy-Item (Join-Path $FfmpegDirectory '*.dll') 'src\VoxClip.Cli\bin\Release\net10.0' -Force
    $testArguments = @('test', '--project', 'tests\VoxClip.Media.Tests\VoxClip.Media.Tests.csproj', '-c', 'Release', '--no-build')
    if ($WithoutEncoders) { $testArguments += @('--filter-not-trait', 'Category=RequiresWindows') }
    Invoke-Bounded 'tests' $testArguments 1200
    Invoke-Bounded 'probe' @('src\VoxClip.Cli\bin\Release\net10.0\voxclip-cli.dll', 'probe', 'tests\VoxClip.Media.Tests\Fixtures\generated\hevc10-two-audio.mp4', '--json') 30
    Invoke-Bounded 'encoders' @('src\VoxClip.Cli\bin\Release\net10.0\voxclip-cli.dll', 'encoders', '--json') 60
    $available = @((Get-Content (Join-Path $runs 'encoders.out.log') -Raw | ConvertFrom-Json).encoders | Where-Object available)
    $exportExit = if ($available.Count -gt 0) { 0 } else { 5 }
    Invoke-Bounded 'export' @('src\VoxClip.Cli\bin\Release\net10.0\voxclip-cli.dll', '--open', 'tests\VoxClip.Media.Tests\Fixtures\generated\bars-4k.mkv', '--export', (Join-Path $runs 'cli.mp4'), '--style', 'off', '--json') 120 $exportExit
    if ($exportExit -eq 0 -and (Get-ChildItem $FfmpegDirectory -Filter ffprobe.exe)) {
        $probe = Get-ChildItem $FfmpegDirectory -Filter ffprobe.exe | Select-Object -First 1
        Invoke-Bounded 'ffprobe' @('-v', 'error', '-show_streams', '-show_format', '-of', 'json', (Join-Path $runs 'cli.mp4')) 30 0 $probe.FullName
    }
    if ($acceptanceFailures.Count -gt 0) { throw ($acceptanceFailures -join '; ') }
} finally {
    foreach ($name in @('cli.mp4', 'cli.mp4.partial', 'mf-minimal.mp4', 'mf-configured.mp4')) {
        Remove-Item (Join-Path $runs $name) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $runs 'runner.pid') -ErrorAction SilentlyContinue
}
