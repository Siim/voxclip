param([ValidateSet('editor', 'home', 'settings')][string]$Screen = 'editor', [switch]$Exercise, [string]$Root = 'C:\voxclip-build\win-ui')
$ErrorActionPreference = 'Stop'
$root = $Root
$shots = Join-Path $root 'screenshots'
New-Item -ItemType Directory -Force $shots | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
public static class VoxClipScreen {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rectangle);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void DismissShell() { keybd_event(0x1B, 0, 0, UIntPtr.Zero); keybd_event(0x1B, 0, 2, UIntPtr.Zero); }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    private static string Title(IntPtr window) { var title = new StringBuilder(256); GetWindowText(window, title, title.Capacity); return title.ToString(); }
    public static IntPtr[] Windows(uint process) {
        var windows = new List<IntPtr>();
        EnumWindows((window, parameter) => { uint owner; GetWindowThreadProcessId(window, out owner); if (owner == process && Title(window).StartsWith("VoxClip")) windows.Add(window); return true; }, IntPtr.Zero);
        return windows.OrderBy(window => Title(window).Contains("Settings") ? 1 : 0).ToArray();
    }
    public static bool BelongsTo(IntPtr window, uint process) {
        uint owner;
        GetWindowThreadProcessId(window, out owner);
        return owner == process;
    }
    public static void ExportShortcut() {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x45, 0, 0, UIntPtr.Zero);
        keybd_event(0x45, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
    public static bool HasContent(System.Drawing.Bitmap bitmap) {
        if (bitmap.Width < 100 || bitmap.Height < 120) return false;
        var baseline = bitmap.GetPixel(24, 80);
        var different = 0;
        var total = 0;
        for (var top = 80; top < bitmap.Height - 24; top += 8)
            for (var left = 24; left < bitmap.Width - 24; left += 8) {
                var pixel = bitmap.GetPixel(left, top);
                total++;
                if (Math.Abs(pixel.R - baseline.R) + Math.Abs(pixel.G - baseline.G) + Math.Abs(pixel.B - baseline.B) > 24) different++;
            }
        return different >= Math.Max(16, total / 1000);
    }
}
'@ -ReferencedAssemblies System.Drawing, System.Core
[void][VoxClipScreen]::SetProcessDPIAware()
function Save-Screen([string]$Name) {
    $bitmap = New-Object System.Drawing.Bitmap([VoxClipScreen]::GetSystemMetrics(0), [VoxClipScreen]::GetSystemMetrics(1))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen(0, 0, 0, 0, $bitmap.Size)
        $bitmap.Save((Join-Path $shots "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Save-Window([string]$Name, [IntPtr]$Window) {
    [void][VoxClipScreen]::SetWindowPos($Window, [IntPtr](-1), 0, 0, 0, 0, 0x43)
    [void][VoxClipScreen]::SetForegroundWindow($Window)
    if ($Name -eq 'home') { [VoxClipScreen]::DismissShell() }
    Start-Sleep -Milliseconds 700
    $bounds = New-Object VoxClipScreen+Rect
    if (-not [VoxClipScreen]::GetWindowRect($Window, [ref]$bounds)) { throw 'The self-check window has no capture bounds.' }
    $bitmap = New-Object System.Drawing.Bitmap(($bounds.Right - $bounds.Left), ($bounds.Bottom - $bounds.Top))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        if (-not [VoxClipScreen]::HasContent($bitmap)) { throw "The $Name window is blank. No successful screenshot was saved." }
        $bitmap.Save((Join-Path $shots "$Name-window.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Save((Join-Path $shots "$Name-window.jpg"), [System.Drawing.Imaging.ImageFormat]::Jpeg)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Find-Control([IntPtr]$Window, [string]$Name) {
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle($Window).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($null -ne $element -and -not $element.Current.IsOffscreen) { return $element }
        Start-Sleep -Milliseconds 250
    }
    throw "The expected accessible control '$Name' did not appear."
}
function Use-Control($Control) {
    $pattern = $null
    if ($Control.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select() }
    elseif ($Control.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke() }
    else { throw "The control '$($Control.Current.Name)' has no selection or invoke pattern." }
    Start-Sleep -Milliseconds 500
}
try {
    $app = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $app = Get-Process VoxClip -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\*" -and $_.MainWindowTitle -like 'VoxClip*' } | Select-Object -First 1
        if ($app -and $app.Responding) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $app) { Save-Screen 'startup-failed'; throw 'VoxClip did not remain running.' }
    $report = Join-Path $shots "$Screen-self-check.json"
    $check = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ($app.HasExited) { throw 'VoxClip exited before its first rendered frame.' }
        if (Test-Path $report) {
            $check = Get-Content $report -Raw | ConvertFrom-Json
            if ($check.processId -eq $app.Id -and $check.status -eq 'failed') { throw 'VoxClip startup self-check failed. Inspect capture-data\Logs\voxclip.log.' }
            if ($check.processId -eq $app.Id -and $check.screen -eq $Screen -and $check.status -eq 'ready' -and $check.rootLoaded -and $check.rendered) { break }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $check -or $check.processId -ne $app.Id -or $check.screen -ne $Screen -or $check.status -ne 'ready' -or -not $check.rootLoaded -or -not $check.rendered) { throw 'VoxClip did not report a loaded and rendered XAML root within 60 seconds.' }
    $window = [IntPtr]([long]$check.windowHandle)
    if ($window -eq [IntPtr]::Zero -or -not [VoxClipScreen]::BelongsTo($window, $app.Id)) { throw 'The self-check window does not belong to the captured process.' }
    Save-Window $Screen $window
    Save-Screen $Screen
    if ($Exercise) {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $checks = New-Object 'System.Collections.Generic.List[string]'
        if ($Screen -eq 'editor') {
            $off = Find-Control $window 'Off, just the video'
            if ($off.Current.ControlType -ne [System.Windows.Automation.ControlType]::RadioButton) { throw 'Caption styles do not expose radio-button semantics.' }
            $selected = Find-Control $window 'Bold'
            if (-not $selected.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) { throw 'The fixture caption style is not selected in the gallery.' }
            $checks.Add('Caption styles expose named radio buttons and the fixture selection')
            Use-Control (Find-Control $window ('Export' + [char]0x2026))
            [void](Find-Control $window 'Cancel')
            Save-Window 'export' $window
            $checks.Add('Export button opens the export sheet without exporting the fixture')
            Use-Control (Find-Control $window 'Cancel')
            Use-Control (Find-Control $window 'Clips')
            [void](Find-Control $window 'Make clip from selection')
            Save-Window 'editor-clips' $window
            $checks.Add('Clips inspector remains available without a provider key')
        }
        if ($Screen -eq 'settings') {
            $main = @([VoxClipScreen]::Windows($app.Id) | Where-Object { $_ -ne $window })[0]
            if (-not $main) { throw 'The settings exercise requires the main editor window.' }
            foreach ($pane in @('Providers & Keys', 'Local Models', 'Export', 'Accounts', 'About')) {
                Use-Control (Find-Control $window $pane)
                $name = 'settings-' + ($pane.ToLowerInvariant() -replace ' & ', '-' -replace ' ', '-')
                Save-Window $name $window
                $checks.Add("Settings pane selected: $pane")
            }
            Use-Control (Find-Control $window 'Welcome tour')
            $steps = @('Step 1 of 3', 'Step 2 of 3', 'Step 3 of 3')
            for ($step = 0; $step -lt $steps.Count; $step++) {
                [void](Find-Control $main $steps[$step])
                Save-Window ("onboarding-" + ($step + 1)) $main
                if ($step -eq 0) { Use-Control (Find-Control $main 'Continue') }
                if ($step -eq 1) {
                    if ((Find-Control $main 'Continue').Current.IsEnabled) { throw 'Optional connector onboarding selected a provider before user choice.' }
                    Use-Control (Find-Control $main 'Not now')
                }
            }
            Use-Control (Find-Control $main 'Skip')
            $checks.Add('All three onboarding steps render and Skip closes the tour')
            [void][VoxClipScreen]::ShowWindow($window, 5)
            [void][VoxClipScreen]::SetForegroundWindow($window)
            Use-Control (Find-Control $window 'General')
            $appearance = Find-Control $window 'Appearance'
            $appearance.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
            Use-Control (Find-Control $window 'Dark')
            Save-Window 'settings-general-dark' $window
            [void][VoxClipScreen]::ShowWindow($window, 0)
            Save-Window 'editor-dark' $main
            $checks.Add('Dark appearance selected through Settings and applied to both windows')
            [void][VoxClipScreen]::ShowWindow($window, 5)
            [void][VoxClipScreen]::SetForegroundWindow($window)
            $appearance = Find-Control $window 'Appearance'
            $appearance.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
            Use-Control (Find-Control $window 'System')
        }
        [System.IO.File]::WriteAllText((Join-Path $shots "$Screen-interactions.json"), (ConvertTo-Json -InputObject @($checks)))
    }
} catch {
    [System.IO.File]::WriteAllText((Join-Path $shots 'error.txt'), $_.Exception.Message)
    throw
} finally {
    Get-Process VoxClip -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText((Join-Path $shots 'complete'), [DateTime]::UtcNow.ToString('O'))
}
