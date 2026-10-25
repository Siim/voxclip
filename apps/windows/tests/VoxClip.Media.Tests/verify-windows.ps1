param([string]$LockOwner = '', [string]$FfmpegDirectory = $env:VOXCLIP_FFMPEG_DIR, [switch]$WithoutEncoders, [switch]$DiagnoseMf, [switch]$ManagedOnly)
$ErrorActionPreference = 'Stop'
Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..'))
if (-not $PWD.Path.StartsWith('C:\voxclip-build\win-media\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Run only in an archived win-media workspace.' }
if (-not (Test-Path 'C:\voxclip-build\vm.lock\owner') -or (Get-Content 'C:\voxclip-build\vm.lock\owner') -ne $LockOwner) { throw 'The caller must own the VM lock.' }
if (-not $ManagedOnly -and (-not $FfmpegDirectory -or -not (Test-Path $FfmpegDirectory))) { throw 'Pass -FfmpegDirectory with the self-built LGPL FFmpeg 9 native directory.' }
if ($FfmpegDirectory -and -not $FfmpegDirectory.StartsWith('C:\voxclip-build\win-media\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Copy approved DLLs into the win-media VM directory first.' }
$env:VOXCLIP_FFMPEG_DIR = $FfmpegDirectory
$env:VOXCLIP_REQUIRE_NATIVE = '1'
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
$runs = Join-Path $PWD 'apps\windows\tests\VoxClip.Media.Tests\.runs'
New-Item -ItemType Directory -Force $runs | Out-Null
Set-Content (Join-Path $runs 'runner.pid') $PID
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
        if (-not $process.HasExited) { & taskkill.exe /PID $process.Id /T /F | Out-Null }
        $process.Dispose()
    }
}
try {
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
    Invoke-Bounded 'build' @('build', 'VoxClip.CrossPlatform.slnf', '-c', 'Release', '--nologo', '-m:1', '-p:UseSharedCompilation=false', '-nodeReuse:false') 300
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
