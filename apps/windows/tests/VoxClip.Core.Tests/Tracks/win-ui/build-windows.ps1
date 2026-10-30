param([string]$Configuration = 'Debug', [string]$Rid = 'win-arm64', [string]$Root = 'C:\voxclip-build\win-ui')
$ErrorActionPreference = 'Stop'
$root = $Root
if ((Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).TrimEnd('\').TrimEnd(':'))).Free -lt (6GB + 1536MB)) {
    throw 'Native builds require 6 GiB reserve plus 1.5 GiB headroom.'
}
$platform = if ($Rid -eq 'win-arm64') { 'ARM64' } else { 'x64' }
$log = Join-Path $root "build-$Configuration-$Rid.log"
$errorLog = "$log.stderr"
$arguments = @('build', 'apps\windows\src\VoxClip.App', '-c', $Configuration, '-r', $Rid, "-p:Platform=$platform", '-m:1', '--disable-build-servers', '-p:UseSharedCompilation=false')
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = 'C:\Program Files\dotnet\dotnet.exe'
$start.Arguments = $arguments -join ' '
$start.WorkingDirectory = $root
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$build = New-Object System.Diagnostics.Process
$build.StartInfo = $start
[void]$build.Start()
$pidFile = Join-Path $root 'build.pid'
[System.IO.File]::WriteAllText($pidFile, $build.Id.ToString())
$standardOutput = $build.StandardOutput.ReadToEndAsync()
$standardError = $build.StandardError.ReadToEndAsync()
try {
    if (-not $build.WaitForExit(540000)) { & taskkill.exe /PID $build.Id /T /F; throw 'Build exceeded nine minutes.' }
    [System.IO.File]::WriteAllText($log, $standardOutput.Result)
    [System.IO.File]::WriteAllText($errorLog, $standardError.Result)
    Write-Output $standardOutput.Result
    Write-Output $standardError.Result
    exit $build.ExitCode
} finally {
    if (-not $build.HasExited) { & taskkill.exe /PID $build.Id /T /F }
    $build.Dispose()
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
