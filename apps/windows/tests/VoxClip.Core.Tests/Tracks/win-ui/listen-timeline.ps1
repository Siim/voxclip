param([Parameter(Mandatory=$true)][string]$EvidenceDir, [Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'MTA') {
    & powershell.exe -NoProfile -NonInteractive -Mta -ExecutionPolicy Bypass -File $PSCommandPath -EvidenceDir $EvidenceDir -Executable $Executable
    if ($LASTEXITCODE) { throw 'MTA listener failed.' }
    exit 0
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -ReferencedAssemblies UIAutomationClient, UIAutomationTypes @'
using System.Threading;
using System.Windows.Automation;
public static class TimelinePropertyListener {
    public static int Events;
    public static readonly AutomationPropertyChangedEventHandler Handler = OnChanged;
    private static void OnChanged(object sender, AutomationPropertyChangedEventArgs args) { Interlocked.Increment(ref Events); }
}
'@
$ready = Join-Path $EvidenceDir 'timeline-listener-ready.txt'
$result = Join-Path $EvidenceDir 'timeline-allocations.json'
$deadline = [DateTime]::UtcNow.AddMinutes(5)
while (-not (Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
if (-not (Test-Path -LiteralPath $ready)) { throw 'The owned timeline did not request a listener.' }
$appId = [int](Get-Content -LiteralPath $ready -Raw)
$app = Get-Process -Id $appId
if ($app.Path -ne (Resolve-Path -LiteralPath $Executable).Path) { throw 'Listener target is not the owned executable.' }
if ($app.MainWindowHandle -eq [IntPtr]::Zero) { throw 'The owned timeline has no window.' }
$window = [System.Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
$playhead = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'NativeProbe.Playhead'))
if (-not $playhead -or $playhead.Current.ProcessId -ne $appId) { throw 'The owned probe playhead did not realize.' }
try {
    [System.Windows.Automation.Automation]::AddAutomationPropertyChangedEventHandler($playhead,
        [System.Windows.Automation.TreeScope]::Element, [TimelinePropertyListener]::Handler,
        @([System.Windows.Automation.RangeValuePattern]::ValueProperty, [System.Windows.Automation.RangeValuePattern]::MinimumProperty,
          [System.Windows.Automation.RangeValuePattern]::MaximumProperty, [System.Windows.Automation.RangeValuePattern]::SmallChangeProperty,
          [System.Windows.Automation.AutomationElement]::HelpTextProperty))
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $result) -and -not $app.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $result)) { throw 'The listener run produced no native allocation result.' }
    $measured = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
    if (-not $measured.PropertyListener) { throw 'The app did not observe the real property listener.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([TimelinePropertyListener]::Events -eq 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if ([TimelinePropertyListener]::Events -eq 0) { throw 'No actual UIA property change was delivered.' }
    [TimelinePropertyListener]::Events | Set-Content -LiteralPath (Join-Path $EvidenceDir 'timeline-listener-events.txt')
} finally {
    [System.Windows.Automation.Automation]::RemoveAutomationPropertyChangedEventHandler($playhead, [TimelinePropertyListener]::Handler)
    [IO.File]::WriteAllText((Join-Path $EvidenceDir 'timeline-listener-stopped.txt'), 'unsubscribed')
}
[Environment]::Exit(0)
