param([ValidateSet('editor', 'home', 'settings')][string]$Screen = 'editor', [switch]$Exercise, [string]$Root = 'C:\voxclip-build\win-ui', [ValidateSet('win-x64', 'win-arm64')][string]$RuntimeIdentifier = 'win-arm64', [string]$CaptureName = '', [ValidateSet('home-empty', 'home-dragover', 'finding', 'suggested', 'exported', 'export-edited', 'exporting', 'export-failed', 'transcribing', 'focus', 'opaque-flyout', 'splitter', 'high-contrast-black', 'high-contrast-white')][string]$ManualState, [string]$RequiredName)
$ErrorActionPreference = 'Stop'
$root = $Root
$shots = Join-Path $root "screenshots\$RuntimeIdentifier"
New-Item -ItemType Directory -Force $shots | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
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
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
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
    public static void MakeClipShortcut() {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x4B, 0, 0, UIntPtr.Zero);
        keybd_event(0x4B, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
    public static void ContextMenuKey() {
        keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(0x79, 0, 0, UIntPtr.Zero);
        keybd_event(0x79, 0, 2, UIntPtr.Zero);
        keybd_event(0x10, 0, 2, UIntPtr.Zero);
    }
    public static void SelectOpeningWords() {
        keybd_event(0x24, 0, 0, UIntPtr.Zero);
        keybd_event(0x24, 0, 2, UIntPtr.Zero);
        keybd_event(0x10, 0, 0, UIntPtr.Zero);
        for (var index = 0; index < 5; index++) {
            keybd_event(0x27, 0, 0, UIntPtr.Zero);
            keybd_event(0x27, 0, 2, UIntPtr.Zero);
        }
        keybd_event(0x10, 0, 2, UIntPtr.Zero);
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
    if ([VoxClipScreen]::GetForegroundWindow() -ne $Window -or -not [VoxClipScreen]::BelongsTo($Window, $app.Id)) { throw "The $Name capture is not the owned foreground window." }
    $bounds = New-Object VoxClipScreen+Rect
    if (-not [VoxClipScreen]::GetWindowRect($Window, [ref]$bounds)) { throw 'The self-check window has no capture bounds.' }
    if (-not $ManualState) { [void][VoxClipScreen]::SetCursorPos(($bounds.Left + 280), ($bounds.Top + 25)) }
    Start-Sleep -Milliseconds 750
    $bitmap = New-Object System.Drawing.Bitmap(($bounds.Right - $bounds.Left), ($bounds.Bottom - $bounds.Top))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        if (-not [VoxClipScreen]::HasContent($bitmap)) {
            $bitmap.Save((Join-Path $shots "$Name-rejected.png"), [System.Drawing.Imaging.ImageFormat]::Png)
            throw "The $Name window is blank. No successful screenshot was saved. Inspect its rejected diagnostic image."
        }
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
function Find-SelectedRow([IntPtr]$Window, [string]$Pattern) {
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $rows = [System.Windows.Automation.AutomationElement]::FromHandle($Window).FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -match $Pattern }
        foreach ($row in $rows) {
            $selection = $null
            if ($row.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selection) -and $selection.Current.IsSelected) { return $row }
        }
        Start-Sleep -Milliseconds 250
    }
    throw "No selected row matching '$Pattern' appeared."
}
function Find-Prefix([IntPtr]$Window, [string]$Prefix) {
    $items = [System.Windows.Automation.AutomationElement]::FromHandle($Window).FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $item = $items | Where-Object { -not $_.Current.IsOffscreen -and $_.Current.Name.StartsWith($Prefix) } | Select-Object -First 1
    if (-not $item) { throw "Missing visible accessible name starting with '$Prefix'." }
    return $item
}
function Use-Control($Control) {
    $pattern = $null
    if ($Control.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select() }
    elseif ($Control.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke() }
    elseif ($Control.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $pattern.Toggle() }
    else { throw "The control '$($Control.Current.Name)' has no selection or invoke pattern." }
    Start-Sleep -Milliseconds 500
}
try {
    $app = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $app = Get-Process VoxClip -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\*\$RuntimeIdentifier\VoxClip.exe" -and $_.MainWindowTitle -like 'VoxClip*' } | Select-Object -First 1
        if ($app -and $app.Responding) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $app) { Save-Screen 'startup-failed'; throw 'VoxClip did not remain running.' }
    if ($ManualState) {
        if (-not $RequiredName) { throw 'Manual states require -RequiredName: the exact visible UIA name witnessing the intended state.' }
        $window = [IntPtr]$app.MainWindowHandle
        [void](Find-Control $window $RequiredName)
        Save-Window $ManualState $window
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        [IO.File]::WriteAllText((Join-Path $shots "$ManualState-evidence.json"), (ConvertTo-Json -Depth 5 -InputObject @{
            state=$ManualState; runtime=$RuntimeIdentifier; requiredName=$RequiredName; processId=$app.Id;
            focusedName=$focused.Current.Name; focusedBounds=$focused.Current.BoundingRectangle.ToString();
            capturedAt=[DateTime]::UtcNow.ToString('O'); visualReview='pending'; narrator='not observed'
        }))
        return
    }
    $receipt = Join-Path $root 'capture-data\windows-runtime-agreement.txt'
    if (-not (Test-Path $receipt)) {
        $termsHost = [IntPtr]$app.MainWindowHandle
        if ($termsHost -eq [IntPtr]::Zero -or -not [VoxClipScreen]::BelongsTo($termsHost, $app.Id)) { throw 'The first-launch terms host does not belong to VoxClip.' }
        $accept = Find-Control $termsHost 'Accept and continue'
        Use-Control $accept
        for ($acceptAttempt = 0; $acceptAttempt -lt 20 -and -not (Test-Path $receipt); $acceptAttempt++) { Start-Sleep -Milliseconds 250 }
        if (-not (Test-Path $receipt)) { throw 'Explicit first-launch acceptance did not write the isolated receipt.' }
    }
    $report = Join-Path $root "screenshots\$Screen-self-check.json"
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
    if (-not $CaptureName) { $CaptureName = $Screen }
    Save-Window $CaptureName $window
    Copy-Item -LiteralPath $report -Destination (Join-Path $shots "$CaptureName-self-check.json") -Force
    Save-Screen $Screen
    if ($Exercise) {
        $checks = New-Object 'System.Collections.Generic.List[string]'
        if ($Screen -eq 'editor') {
            [void](Find-Control $window 'Find clips')
            [void](Find-Control $window ('Export video' + [char]0x2026))
            Save-Window 'editor-full-take' $window
            $checks.Add('The command row shows Find clips and the one Export video button')
            Use-Control (Find-Control $window 'Find clips')
            [void](Find-Control $window ('Set up AI' + [char]0x2026))
            Save-Window 'editor-find-clips' $window
            $checks.Add('Find Clips with no connector shows the Set up AI callout under the pane actions without starting a provider')
            $transcript = Find-Control $window 'Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.'
            $transcript.SetFocus()
            [VoxClipScreen]::SelectOpeningWords()
            Start-Sleep -Milliseconds 400
            [VoxClipScreen]::ContextMenuKey()
            [void](Find-Control $window 'Make clip')
            Save-Window 'editor-light' $window
            [VoxClipScreen]::DismissShell()
            Start-Sleep -Milliseconds 200
            $transcript.SetFocus()
            [VoxClipScreen]::MakeClipShortcut()
            $clip = Find-SelectedRow $window '^Clip \d+, '
            Save-Window 'editor-manual-clip' $window
            $checks.Add('Keyboard-selected transcript words made a clip whose pane row is selected, so it is the preview range')
            Use-Control (Find-Control $window 'Play')
            Start-Sleep -Seconds 4
            $clock = [System.Windows.Automation.AutomationElement]::FromHandle($window).FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -match '^([0-9:.]+) / ([0-9:.]+)$' } | Select-Object -First 1
            if (-not $clock -or $clock.Current.Name -notmatch '^([0-9:.]+) / \1$') { throw 'Clip preview did not stop at its scoped duration.' }
            Save-Window 'editor-preview-end' $window
            $checks.Add('Clip preview stops at its local duration')
            $clip.SetFocus()
            [VoxClipScreen]::ContextMenuKey()
            Use-Control (Find-Control $window ('Export clip' + [char]0x2026))
            $thisClip = Find-Prefix $window 'This clip'
            if (-not $thisClip.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) { throw 'The clip export did not default to This clip.' }
            [void](Find-Prefix $window 'All ')
            [void](Find-Prefix $window 'Full video')
            Save-Window 'export-this-clip' $window
            $checks.Add('The clip row menu opens This clip; All clips and Full video remain explicit choices')
            Use-Control (Find-Control $window 'Cancel')
            $off = Find-Control $window 'Off, just the video'
            if ($off.Current.ControlType -ne [System.Windows.Automation.ControlType]::RadioButton) { throw 'Caption styles do not expose radio-button semantics.' }
            $selected = Find-Prefix $window 'Bold: '
            if (-not $selected.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) { throw 'The fixture caption style is not selected in the gallery.' }
            Save-Window 'editor-captions' $window
            $checks.Add('Caption styles expose named radio buttons and the fixture selection')
            Use-Control (Find-Control $window ('Export clip' + [char]0x2026))
            [void](Find-Control $window 'Cancel')
            Save-Window 'export' $window
            $checks.Add('Export clip opens the export sheet without exporting the fixture')
            Use-Control (Find-Control $window 'Cancel')
            $scale = [double]$check.rasterizationScale
            [void][VoxClipScreen]::SetWindowPos($window, [IntPtr]::Zero, 32, 32, [int](1024 * $scale), [int](700 * $scale), 0x0040)
            Start-Sleep -Milliseconds 600
            [void](Find-Control $window 'Play')
            Save-Window 'editor-compact-resize-probe' $window
            Use-Control (Find-Control $window 'Viewer')
            [void](Find-Control $window 'Off, just the video')
            Save-Window 'editor-compact-viewer' $window
            $checks.Add('The compact editor collapses the viewer to a timeline transport, and Viewer brings captions back')
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
            Use-Control (Find-Prefix $main 'Clip 2, ')
            Save-Window 'editor-dark' $main
            $scale = [double]$check.rasterizationScale
            [void][VoxClipScreen]::SetWindowPos($main, [IntPtr]::Zero, 32, 32, [int](900 * $scale), [int](720 * $scale), 0x0040)
            Start-Sleep -Milliseconds 600
            Save-Window 'editor-compact-dark' $main
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
    if (-not $ManualState -and $app -and -not $app.HasExited) { $app | Stop-Process -Force -ErrorAction SilentlyContinue }
    [System.IO.File]::WriteAllText((Join-Path $shots 'complete'), [DateTime]::UtcNow.ToString('O'))
}
