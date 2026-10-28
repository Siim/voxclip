param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$EvidenceDir,
    [ValidateSet('win-x64','win-arm64')][string]$RuntimeIdentifier='win-x64', [switch]$Schedule, [switch]$Hosted)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Root).Path
New-Item -ItemType Directory -Force $EvidenceDir | Out-Null
$evidence = (Resolve-Path -LiteralPath $EvidenceDir).Path
$report = Join-Path $evidence 'observed-self-check.json'
if (Test-Path -LiteralPath $report) { throw 'Use a fresh smoke evidence directory; stale reports are not accepted.' }
if ($Schedule) {
    $task = 'VoxClipLaunchSmoke-' + [Guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Root `"$root`" -EvidenceDir `"$evidence`" -RuntimeIdentifier $RuntimeIdentifier"
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive
    try {
        Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $task
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $report) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
        if (-not (Test-Path -LiteralPath $report)) { throw 'The interactive smoke wrote no report within 30 seconds.' }
        $observed = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        if ($observed.status -ne 'ok' -or -not $observed.rootLoaded -or -not $observed.rendered) { throw "Interactive launch smoke failed: $($observed.reason)" }
    } finally {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }
    return
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SmokeDesktop {
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
$desktop = [SmokeDesktop]::OpenInputDesktop(0, $false, 1)
$desktopError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
$observed = [ordered]@{ status='failed'; runtime=$RuntimeIdentifier; rootLoaded=$false; rendered=$false;
    sessionId=(Get-Process -Id $PID).SessionId; userInteractive=[Environment]::UserInteractive; inputDesktop=($desktop -ne [IntPtr]::Zero); desktopError=$desktopError }
$app = $null
try {
    if ($desktop -eq [IntPtr]::Zero -or -not [Environment]::UserInteractive) {
        $observed.status = 'not runnable'
        $observed.reason = 'This process has no interactive input desktop. The owned VM pre-merge launch gate is required.'
        if (-not $Hosted) { throw $observed.reason }
        Write-Warning $observed.reason
        return
    }
    $env:VOXCLIP_DATA_DIR = Join-Path $evidence 'data'
    $env:VOXCLIP_SHARED_DIR = Join-Path $root 'shared'
    $env:VOXCLIP_LIVE_TESTS = '0'
    $env:VOXCLIP_TEST_DOWNLOAD = '0'
    $platform = if ($RuntimeIdentifier -eq 'win-arm64') { 'ARM64' } else { 'x64' }
    $exe = Join-Path $root "apps\windows\src\VoxClip.App\bin\$platform\Debug\net10.0-windows10.0.26100.0\$RuntimeIdentifier\VoxClip.exe"
    $raw = Join-Path $evidence 'app-self-check.json'
    $fixture = Join-Path $root 'shared\fixtures\projects\interview-take.voxclip'
    $app = Start-Process -FilePath $exe -ArgumentList "--demo-project `"$fixture`" --self-check `"$raw`"" -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $accepted = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($app.HasExited) { throw 'The app exited before the Editor self-check.' }
        if (Test-Path -LiteralPath $raw) {
            try { $check = Get-Content -LiteralPath $raw -Raw | ConvertFrom-Json } catch { $check = $null }
            if ($check -and $check.status -eq 'failed') { throw 'The Editor reported a failed self-check.' }
            if ($check -and $check.status -eq 'ready') { break }
        }
        $app.Refresh()
        if (-not $accepted -and $app.MainWindowHandle -ne [IntPtr]::Zero) {
            $window = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
            $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Accept and continue')
            $accept = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($accept) { $accept.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $accepted = $true }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $check -or $check.status -ne 'ready' -or $check.screen -ne 'editor' -or -not $check.rootLoaded -or -not $check.rendered -or $check.processId -ne $app.Id) { throw 'No owned, loaded and rendered Editor within 15 seconds.' }
    $windowHandle = [IntPtr]([long]$check.windowHandle)
    if (-not [SmokeDesktop]::IsWindowVisible($windowHandle)) { throw 'The reported Editor window is not visible.' }
    [void][SmokeDesktop]::SetForegroundWindow($windowHandle)
    if ([SmokeDesktop]::GetForegroundWindow() -ne $windowHandle) { throw 'The owned Editor could not be foregrounded on this desktop.' }
    $window = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.')
    $transcript = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $transcript -or $transcript.Current.IsOffscreen) { throw 'The visible Editor transcript is absent from UIA.' }
    $observed.status = 'ok'
    $observed.applicationStatus = $check.status
    $observed.rootLoaded = $check.rootLoaded
    $observed.rendered = $check.rendered
    $observed.processId = $app.Id
    $observed.windowHandle = $check.windowHandle
} catch {
    $observed.reason = $_.Exception.Message
    throw
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force; [void]$app.WaitForExit(5000) }
    if ($desktop -ne [IntPtr]::Zero) { [void][SmokeDesktop]::CloseDesktop($desktop) }
    $observed | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $report
}
