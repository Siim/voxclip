#if DEBUG
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using Windows.Foundation;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    internal async Task DebugLayoutGateAsync(MainWindow window, string output, List<string> checks)
    {
        var root = (FrameworkElement)window.Content;
        var initial = window.AppWindow.Size;
        var theme = root.RequestedTheme;
        var observations = new List<object>();
        try
        {
            foreach (var item in new[] { (1440, 900, 388, ElementTheme.Light), (1440, 900, 388, ElementTheme.Dark),
                (1280, 800, 348, ElementTheme.Light), (1440, 900, 300, ElementTheme.Light),
                (1440, 900, 560, ElementTheme.Light), (760, 600, 300, ElementTheme.Light), (1000, 800, 0, ElementTheme.Light) })
            {
                root.RequestedTheme = item.Item4;
                var scale = XamlRoot.RasterizationScale;
                window.AppWindow.Resize(new((int)(item.Item1 * scale), (int)(item.Item2 * scale)));
                await Task.Delay(200);
                viewerForced = item.Item1 == 760;
                ShowViewer(item.Item3 > 0);
                if (item.Item3 is 300 or 560) RightColumn.Width = new(item.Item3);
                await Task.Delay(100);
                UpdateLayout();
                NativeRequire(Math.Abs(CommandRow.ActualHeight - 56) <= 4 && Math.Abs(Timeline.ActualHeight - 72) <= 4,
                    "Native command row/timeline differ from the mockups by more than 4 epx.");
                var expectedRight = item.Item3;
                if (expectedRight > 0)
                    NativeRequire(RightPane.Visibility == Visibility.Visible && Math.Abs(RightColumn.ActualWidth - expectedRight) <= 4,
                        "Native right column differs from the mockup by more than 4 epx.");
                else NativeRequire(RightPane.Visibility == Visibility.Collapsed, "Compact mockup did not collapse the viewer first.");
                observations.Add(new { Width = item.Item1, Theme = item.Item4.ToString(), Command = CommandRow.ActualHeight,
                    Timeline = Timeline.ActualHeight, Right = RightColumn.ActualWidth, expectedRight, RightVisible = RightPane.Visibility.ToString() });
                var label = $"layout-{item.Item1}-{item.Item3}-{item.Item4}";
                if (expectedRight > 0)
                {
                    var elapsed = TransportElapsed.Text; var total = TransportTotal.Text; var ai = AiModified.Visibility;
                    var state = mediaState;
                    try
                    {
                        TransportElapsed.Text = "9:59:59.9"; TransportTotal.Text = " / 9:59:59.9"; AiModified.Visibility = Visibility.Visible;
                        await captions!.DebugFitStatesAsync(name => DebugRightColumnBoundsAsync(window, output, label + "-" + name,
                            name == "fine-tune" ? ColumnFitState.FineTune : ColumnFitState.Captions));
                        foreach (var unavailable in new[] { EditorMediaState.Missing, EditorMediaState.Corrupt })
                        {
                            mediaState = unavailable; SizeStage();
                            await DebugRightColumnBoundsAsync(window, output, label + "-" + unavailable);
                        }
                    }
                    finally { TransportElapsed.Text = elapsed; TransportTotal.Text = total; AiModified.Visibility = ai; mediaState = state; SizeStage(); }
                }
                await NativeImageAsync(window, output, label);
            }
            await File.WriteAllTextAsync(Path.Combine(output, "layout-geometry.json"), JsonSerializer.Serialize(observations, new JsonSerializerOptions { WriteIndented = true }));
            checks.Add("light/dark/1280/compact native geometry: command row, timeline and right column within 4 epx of mockup; compact viewer collapses first");
        }
        finally { root.RequestedTheme = theme; window.AppWindow.Resize(initial); await Task.Delay(100); viewerForced = false; ShowViewer(true); }
    }
    internal async Task DebugCaptionGateAsync(MainWindow window, string output, List<string> checks)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        NativeGateInput.Key(0x1b); NativeGateInput.Key(0x12); NativeGateInput.SetForegroundWindow(hwnd);
        NativeRequire(NativeGateInput.GetForegroundWindow() == hwnd, "Caption pointer probe has no foreground ownership.");
        ViewModel.SetMediaUnavailable(false);
        ViewModel.Apply(new VoxClip.Core.Domain.Editing.EditOperation.SetActiveClip(null));
        ShowViewer(true);
        async Task Begin()
        {
            var snapshot = await SnapshotAsync(CancellationToken.None);
            CaptionDrag.Update(snapshot.Captions, 0);
            EditorRoot.UpdateLayout();
            var target = NativeDescendants(CaptionDrag).OfType<FrameworkElement>().Single(element => AutomationProperties.GetName(element) == "Caption position. Drag to move captions.");
            var point = target.TransformToVisual(window.Content).TransformPoint(new Point(target.ActualWidth / 2, target.ActualHeight / 2));
            var screen = new NativeGateInput.NativePoint();
            NativeRequire(NativeGateInput.ClientToScreen(hwnd, ref screen), "Caption client-to-screen failed.");
            var scale = XamlRoot.RasterizationScale;
            NativeGateInput.SetCursorPos(screen.X + (int)(point.X * scale), screen.Y + (int)(point.Y * scale));
            NativeGateInput.Mouse(2);
            await Task.Delay(120);
            NativeRequire(CaptionDrag.IsDragging, "Native left-down did not begin caption drag.");
            NativeGateInput.SetCursorPos(screen.X + (int)((point.X - 40) * scale), screen.Y + (int)((point.Y - 25) * scale));
            await Task.Delay(100);
        }
        async Task Release() { NativeGateInput.Mouse(4); await Task.Delay(150); }
        var initial = CaptionFineTune.StoredPosition(ViewModel.Project);
        var initialAspect = ViewModel.Project.Export.Aspect;
        var originalPath = window.ProjectPath;
        try
        {
            await Begin();
            await NativeImageAsync(window, output, "caption-drag-guides");
            await Release();
            var moved = CaptionFineTune.StoredPosition(ViewModel.Project);
            NativeRequire(moved != initial, "Native drag did not commit a new position.");
            ViewModel.Undo(); NativeRequire(CaptionFineTune.StoredPosition(ViewModel.Project) == initial, "Caption drag did not undo in one step.");
            ViewModel.Redo(); NativeRequire(CaptionFineTune.StoredPosition(ViewModel.Project) == moved, "Caption drag redo did not restore its position.");
            await Begin(); ViewModel.Undo();
            NativeRequire(!CaptionDrag.IsDragging, "Undo left the native caption drag live.");
            await Release(); NativeRequire(CaptionFineTune.StoredPosition(ViewModel.Project) == initial, "Stale native release overwrote Undo.");
            await Begin(); ViewModel.Redo();
            NativeRequire(!CaptionDrag.IsDragging, "Redo left the native caption drag live.");
            await Release(); NativeRequire(CaptionFineTune.StoredPosition(ViewModel.Project) == moved, "Stale native release overwrote Redo.");
            await Begin(); ViewModel.SetExport(ViewModel.Project.Export with { Aspect = initialAspect == VoxClip.Core.Domain.Shared.ExportAspect.Portrait
                ? VoxClip.Core.Domain.Shared.ExportAspect.Landscape : VoxClip.Core.Domain.Shared.ExportAspect.Portrait });
            NativeRequire(!CaptionDrag.IsDragging, "Aspect switch left native caption drag live.");
            var switched = ViewModel.Project.Captions;
            await Release(); NativeRequire(ViewModel.Project.Captions == switched, "Stale native release wrote a different aspect.");
            ViewModel.SetExport(ViewModel.Project.Export with { Aspect = initialAspect });
            await Begin();
            ViewModel.SetTranscript(ViewModel.Project.Transcript!);
            NativeRequire(!CaptionDrag.IsDragging, "Transcript reload left the native caption drag live.");
            var reloaded = ViewModel.Project.Captions;
            await Release(); NativeRequire(ViewModel.Project.Captions == reloaded, "Stale native release changed reloaded captions.");
            var reloadPath = Path.Combine(output, "caption-reload.voxclip");
            await File.WriteAllTextAsync(reloadPath, VoxClip.Core.Domain.Shared.ProjectSerialization.Serialize(ViewModel.Project));
            await Begin();
            await window.OpenPathAsync(reloadPath, ShellPath.Launch);
            NativeRequire(!CaptionDrag.IsDragging && window.DebugEditor is { } replacement && !ReferenceEquals(replacement, this),
                "Actual project-file reload retained the old editor or its pointer drag. " + window.DebugOpenError);
            var loaded = window.DebugEditor!.ViewModel.Project.Captions;
            await Release();
            NativeRequire(window.DebugEditor.ViewModel.Project.Captions == loaded, "A stale native release changed the reloaded project's captions.");
            checks.Add("native caption pointer down/move/up: one-step drag Undo/Redo, live-drag Undo/Redo, aspect switch and transcript reload all reject stale release");
            checks.Add("actual project-file replacement during a native caption drag cancels it; stale mouse-up preserves the reloaded file's position");
        }
        finally
        {
            NativeGateInput.Mouse(4); CaptionDrag.Cancel();
            if (originalPath is not null && window.ProjectPath != originalPath) await window.OpenPathAsync(originalPath, ShellPath.Launch);
            window.DebugEditor?.ViewModel.SetMediaUnavailable(false);
        }
    }

    internal async Task DebugRewriteGateAsync(MainWindow window, string output, List<string> checks)
    {
        var originalTranscript = ViewModel.Project.Transcript!;
        var originalReadOnly = ViewModel.IsReadOnly;
        var enabled = App.Services.Get("voiceLab.enabled", false);
        var first = ViewModel.SelectionStart; var last = ViewModel.SelectionEnd;
        try
        {
            ViewModel.SetMediaUnavailable(false);
            var diffWords = originalTranscript.Words.ToArray();
            diffWords[4] = diffWords[4] with { Text = "[laughter]", Kind = VoxClip.Core.Domain.Shared.WordKind.Event };
            diffWords[5] = diffWords[5] with { Text = "[unlabeled speech]", Kind = VoxClip.Core.Domain.Shared.WordKind.UnlabeledSpeech };
            ViewModel.SetTranscript(originalTranscript with { Words = diffWords });
            await App.Services.SetAsync("voiceLab.enabled", true, CancellationToken.None);
            ViewModel.Select(3); ViewModel.Select(7, true);
            FocusTranscript();
            await NativeWaitAsync(() => Transcript.IsLoaded && Transcript.ActualWidth > 0 && Transcript.CanRewrite &&
                ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), Transcript), "The selected transcript did not become realized and focused.");
            await OpenRewriteAsync(false);
            await NativeWaitAsync(() => rewrite is { IsOpen: true } && NativeDescendants(this).OfType<RewritePanel>().Any(candidate =>
                candidate.IsLoaded && candidate.ActualWidth > 0 && ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), candidate.FocusTarget)),
                "Actual Rewrite did not become realized and focus its instruction field.");
            NativeRequire(rewrite is { IsOpen: true }, $"Actual Rewrite route did not open: readonly={ViewModel.IsReadOnly}, busy={ViewModel.Busy}, leaving={ViewModel.IsLeaving}, selection={ViewModel.HasSelection}, column={rightContent is not null}, disposed={disposed}.");
            var panel = NativeDescendants(this).OfType<RewritePanel>().Single();
            NativeRequire(Math.Abs(panel.ActualWidth - CaptionsHost.ActualWidth) <= 4, "Rewrite is not the right-column width within 4 epx.");
            NativeRequire(FocusManager.GetFocusedElement(XamlRoot) is FrameworkElement focused && AutomationProperties.GetName(focused) == "What should change?",
                "Opening Rewrite did not focus its instruction field.");
            rewrite!.Edit("Sunday");
            await NativeWaitAsync(() => rewrite is { NewWords: "Sunday", Review: not null } && panel.IsLoaded && panel.ActualHeight > 0,
                "The edited Rewrite review was not ready.");
            var rightWidth = RightColumn.Width;
            try
            {
                foreach (var width in new[] { 300, 348, 388, 560 })
                {
                    RightColumn.Width = new(width);
                    await DebugRightColumnBoundsAsync(window, output, "rewrite-" + width, ColumnFitState.Rewrite);
                }
        }
        finally { RightColumn.Width = rightWidth; }
        NativeRequire(rewrite.Review!.Diff.Hunks.SelectMany(hunk => hunk.AbsorbedItemIds).Count() == 2 &&
            rewrite.Review.Runs.Any(run => run.Text == "[laughter]" && run.Kind == RewriteDiffKind.Removed) &&
            rewrite.Review.Runs.Any(run => run.Text == "[unlabeled speech]" && run.Kind == RewriteDiffKind.Removed),
            "Native Rewrite did not show both absorbed labels in its Core diff.");
        var focus = new List<string>();
        for (var index = 0; index < 6; index++)
        {
            NativeGateInput.Key(0x75);
            await Task.Delay(80);
            var current = FocusManager.GetFocusedElement(XamlRoot) as FrameworkElement;
            focus.Add(current is null ? "<none>" : AutomationProperties.GetName(current));
        }
        NativeRequire(focus.Contains("What should change?"), "F6 skipped the open Rewrite panel.");
        var geometry = new { Window = new { window.AppWindow.Size.Width, window.AppWindow.Size.Height },
            CommandRow = new { CommandRow.ActualWidth, CommandRow.ActualHeight }, Timeline = new { Timeline.ActualWidth, Timeline.ActualHeight },
            RightColumn = new { RightPane.ActualWidth, RightPane.ActualHeight }, Rewrite = new { panel.ActualWidth, panel.ActualHeight },
            focus, Diff = rewrite.Review?.AccessibleDescription, Absorbed = rewrite.Review?.Diff.Hunks.SelectMany(hunk => hunk.AbsorbedItemIds).ToArray() };
        await File.WriteAllTextAsync(Path.Combine(output, "rewrite-geometry.json"), JsonSerializer.Serialize(geometry, new JsonSerializerOptions { WriteIndented = true }));
        await NativeImageAsync(window, output, "rewrite-review");
        var diffLine = NativeDescendants(panel).OfType<RewriteDiffLine>().Single();
        diffLine.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
        await Task.Delay(200);
        await NativeImageAsync(window, output, "rewrite-diff-review");
        var instruction = NativeDescendants(panel).OfType<TextBox>().Single(element => AutomationProperties.GetName(element) == "What should change?");
        instruction.Focus(FocusState.Keyboard);
        NativeGateInput.Key(0x1b);
        await NativeWaitAsync(() => rewrite is not { IsOpen: true } && ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), Transcript),
            "Escape did not close Rewrite and restore transcript focus.");
        NativeRequire(rewrite is not { IsOpen: true } && ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), Transcript), "Escape did not close Rewrite and restore transcript focus.");
        checks.Add("native DEBUG Rewrite through actual opening route: instruction focus, right-column width within 4 epx, Core diff/absorbed metadata, F6 inclusion, Escape-to-transcript; no connector or generation");
        }
        finally
        {
            rewrite?.Dispose(); rightContent?.CloseRewrite();
            ViewModel.SetTranscript(originalTranscript);
            ViewModel.SetMediaUnavailable(originalReadOnly);
            if (first >= 0) { ViewModel.Select(first); if (last >= first) ViewModel.Select(last, true); }
            await App.Services.SetAsync("voiceLab.enabled", enabled, CancellationToken.None);
        }
    }
    private static async Task NativeWaitAsync(Func<bool> ready, string failure)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!ready())
        {
            NativeRequire(DateTime.UtcNow < deadline, failure);
            await Task.Delay(25);
        }
    }
    internal async Task DebugBusyGateAsync(MainWindow window, string output, List<string> checks)
    {
        foreach (var owner in new[] { "Rewrite", "Find Clips" })
        {
            using (var lease = ViewModel.LlmRuns.TryAcquire())
            {
                NativeRequire(lease is not null, "Native busy probe could not acquire the project lease.");
                await Task.Delay(100);
                NativeRequire(!FindClipsCommand.IsEnabled && FindClipsBusy.IsActive && FindClipsBusyHost.Visibility == Visibility.Visible,
                    owner + " did not disable the command-bar Find Clips entry and show its busy ring.");
                NativeRequire(!RewriteCommand.IsEnabled, owner + " left Rewrite enabled.");
                var row = window.Shell.Rows.Single(row => row.Kind == SidebarKind.Action && row.Title == "Find clips with AI");
                NativeRequire(!row.IsEnabled && row.IsLlmBusy, owner + " left the sidebar Find Clips entry enabled or idle.");
                NativeRequire(NativeDescendants(window.Content).OfType<ProgressRing>().Any(ring => ring.IsActive &&
                    AutomationProperties.GetName(ring) == "Finish the current task first."), "The realized sidebar busy ring is absent.");
                await NativeImageAsync(window, output, "busy-" + owner.Replace(" ", "-"));
            }
            await Task.Delay(100);
            NativeRequire(FindClipsCommand.IsEnabled && !FindClipsBusy.IsActive, "Find Clips did not recover after " + owner + " released its lease.");
        }
        using var cancellation = new CancellationTokenSource();
        var pending = Ui.ConfirmAsync(XamlRoot, "Use this connector?", "Native cancellation probe. No connector or request is created.", "Continue", cancellation.Token);
        await Task.Delay(150);
        var dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(XamlRoot).SelectMany(popup =>
            new[] { popup.Child }.Concat(NativeDescendants(popup.Child))).OfType<ContentDialog>().Single(item => item.Title as string == "Use this connector?");
        var closed = false;
        dialog.Closed += (_, _) => closed = true;
        await NativeImageAsync(window, output, "consent-pending");
        cancellation.Cancel();
        try { await pending.WaitAsync(TimeSpan.FromSeconds(2)); }
        catch (OperationCanceledException) { }
        var dismissal = System.Diagnostics.Stopwatch.StartNew();
        while (!closed && dismissal.Elapsed < TimeSpan.FromSeconds(2)) await Task.Delay(25);
        NativeRequire(closed, "Cancelled native consent did not raise Closed within two seconds.");
        checks.Add("realized command-bar/sidebar busy rings and disabled Find Clips/Rewrite in both lease directions; real consent ContentDialog cancels and dismisses within two seconds without discovery or send");
    }
    private static IEnumerable<DependencyObject> NativeDescendants(DependencyObject root)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var descendant in NativeDescendants(child)) yield return descendant;
        }
    }
    private static async Task NativeImageAsync(MainWindow window, string output, string name)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(window.Content);
        using var stream = File.Create(Path.Combine(output, name + ".png"));
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, (await bitmap.GetPixelsAsync()).ToArray());
        await encoder.FlushAsync();
    }
    private static void NativeRequire(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static class NativeGateInput
    {
        [StructLayout(LayoutKind.Sequential)] internal struct NativePoint { internal int X, Y; }
        [DllImport("user32.dll")] internal static extern bool ClientToScreen(IntPtr window, ref NativePoint point);
        [DllImport("user32.dll")] internal static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
        [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
        internal static void Key(byte key) { keybd_event(key, 0, 0, UIntPtr.Zero); keybd_event(key, 0, 2, UIntPtr.Zero); }
        internal static void Mouse(uint flags) => mouse_event(flags, 0, 0, 0, UIntPtr.Zero);
    }
}
#endif
