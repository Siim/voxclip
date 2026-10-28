param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$EvidenceDir,
    [Parameter(Mandatory=$true)][string]$AcceptedDataRoot, [Parameter(Mandatory=$true)][string]$OwnerToken,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceSha,
    [ValidateSet('win-x64','win-arm64')][string]$RuntimeIdentifier='win-arm64', [switch]$Schedule)
$ErrorActionPreference = 'Stop'
function Assert-Lease {
    if ((Get-Content -LiteralPath 'C:\voxclip-build\vm.lock\owner.txt' -Raw).Trim() -ne $OwnerToken) { throw 'The VM lease is not owned by this run.' }
}
Assert-Lease
$root = (Resolve-Path -LiteralPath $Root).Path
if (Test-Path -LiteralPath $EvidenceDir) { throw 'Use a fresh route evidence directory for each architecture and run.' }
$report = Join-Path $EvidenceDir 'route-repetitions.json'
if ($Schedule) {
    $task = 'VoxClipRoutes-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Root `"$root`" -EvidenceDir `"$EvidenceDir`" -AcceptedDataRoot `"$AcceptedDataRoot`" -OwnerToken `"$OwnerToken`" -SourceSha $SourceSha -RuntimeIdentifier $RuntimeIdentifier"
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    try {
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $task
        $deadline = [DateTime]::UtcNow.AddSeconds(300)
        while (-not (Test-Path -LiteralPath $report) -and [DateTime]::UtcNow -lt $deadline) { Assert-Lease; Start-Sleep -Milliseconds 500 }
        if (-not (Test-Path -LiteralPath $report)) { throw 'The interactive route harness wrote no report within five minutes.' }
        if ((Get-Content -LiteralPath $report -Raw | ConvertFrom-Json).Status -ne 'passed') { throw 'The interactive route harness failed; retain every iteration.' }
    } finally {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        $ownedExe = Join-Path $root "apps\windows\src\VoxClip.App\bin\$(if ($RuntimeIdentifier -eq 'win-arm64') { 'ARM64' } else { 'x64' })\Debug\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"
        Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $ownedExe -and $_.CommandLine.Contains('--shell-route-probe') -and $_.CommandLine.Contains($EvidenceDir) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    }
    return
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$receipt = Join-Path $AcceptedDataRoot 'windows-runtime-agreement.txt'
if (-not (Test-Path -LiteralPath $receipt)) { throw 'Accept the bundled runtime terms explicitly before running routes.' }
if (-not [Environment]::UserInteractive) { throw 'Route repetitions need the owned interactive desktop.' }
if (Get-Process VoxClip -ErrorAction SilentlyContinue) { throw 'Close existing VoxClip instances before the isolated route gate.' }
New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
$platform = if ($RuntimeIdentifier -eq 'win-arm64') { 'ARM64' } else { 'x64' }
$architecture = if ($RuntimeIdentifier -eq 'win-arm64') { 'Arm64' } else { 'X64' }
$exe = Join-Path $root "apps\windows\src\VoxClip.App\bin\$platform\Debug\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"
$app = $null; $status = 'failed'; $failure = $null; $iterations = @()
try {
    for ($iteration = 1; $iteration -le 5; $iteration++) {
        Assert-Lease
        $directory = Join-Path $EvidenceDir "iteration-$iteration"
        New-Item -ItemType Directory -Path $directory | Out-Null
        $data = Join-Path $directory 'data'
        New-Item -ItemType Directory -Path $data | Out-Null
        Copy-Item -LiteralPath $receipt -Destination (Join-Path $data 'windows-runtime-agreement.txt')
        $env:VOXCLIP_DATA_DIR = $data
        $env:VOXCLIP_SHARED_DIR = Join-Path $root 'shared'
        $env:VOXCLIP_NATIVE_SOURCE_SHA = $SourceSha
        $env:VOXCLIP_LIVE_TESTS = '0'; $env:VOXCLIP_TEST_DOWNLOAD = '0'
        $env:VOXCLIP_TIMELINE_LISTENER_PROBE = '0'
        $result = Join-Path $directory 'routes.json'
        $app = Start-Process -FilePath $exe -ArgumentList "--shell-route-probe `"$directory`"" -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(50)
        while (-not (Test-Path -LiteralPath $result) -and [DateTime]::UtcNow -lt $deadline) {
            Assert-Lease
            if ($app.HasExited) { throw "Iteration $iteration exited without a route report." }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $result)) { throw "Iteration $iteration timed out." }
        $observed = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        if ($observed.Status -ne 'passed' -or $observed.Architecture -ne $architecture -or $observed.SourceSha -ne $SourceSha) { throw "Iteration $iteration failed or used the wrong candidate/architecture." }
        foreach ($route in @('first-open','recent','drop','caption-file-replacement')) {
            $passed = @($observed.Routes | Where-Object { $_.Route -eq $route -and $_.Status -eq 'passed' -and $_.RootLoaded -and $_.Rendered -and $_.TranscriptVisible -and $_.ProcessId -eq $app.Id })
            if ($passed.Count -ne 1) { throw "Iteration $iteration has no unique rendered $route result." }
        }
        $iterations += @{ Iteration=$iteration; ProcessId=$app.Id; Evidence=$result; Routes=$observed.Routes }
        if (-not $app.WaitForExit(5000)) { Stop-Process -Id $app.Id -Force; if (-not $app.WaitForExit(5000)) { throw 'The owned route process did not stop.' } }
    }
    $status = 'passed'
} catch { $failure = $_.Exception.ToString(); throw }
finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force; [void]$app.WaitForExit(5000) }
    @{ Status=$status; Failure=$failure; SourceSha=$SourceSha; Runtime=$RuntimeIdentifier; Iterations=$iterations } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report
}
