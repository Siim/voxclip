#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Services;

/// <summary>Isolated, Debug-only WinUI-thread acceptance probe for the ADR-R29 navigation paths. Sidebar Home keeps the
/// editor; Recent and drop replace the project only through OpenPathAsync's save-before-leaving boundary, and a refused
/// leave or close from Home shows the editor with its notice. The sidebar's header rows keep their controls enabled and
/// named. run-native-flow.ps1 runs it on the VM.</summary>
internal static class ShellNativeProbe
{
    internal static async Task RunAsync(MainWindow window, string output)
    {
        Directory.CreateDirectory(output);
        var checks = new List<string>();
        var failures = new List<string>();
        async Task Gate(string name, Func<Task> run)
        {
            await File.AppendAllTextAsync(Path.Combine(output, "native-phases.txt"), "begin " + name + Environment.NewLine);
            try { await run(); }
            catch (Exception exception)
            {
                failures.Add(name + ": " + exception); checks.Add("FAILED native gate: " + name);
                await File.WriteAllTextAsync(Path.Combine(output, name + "-error.txt"), exception.ToString());
            }
            await File.AppendAllTextAsync(Path.Combine(output, "native-phases.txt"), "end " + name + Environment.NewLine);
        }
        var report = Path.Combine(output, "shell-native-result.json");
        try
        {
            var fixture = "";
            for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            {
                var candidate = Path.Combine(directory.FullName, "shared", "fixtures", "projects", "interview-take.voxclip");
                if (File.Exists(candidate)) { fixture = candidate; break; }
            }
            Require(File.Exists(fixture), "project fixture missing");
            var first = Path.Combine(output, "first.voxclip");
            var second = Path.Combine(output, "second.voxclip");
            var third = Path.Combine(output, "third.voxclip");
            foreach (var path in new[] { first, second, third }) File.Copy(fixture, path, true);

            Require(window.CurrentScreen == "home" && window.DebugSelectedRow?.Kind == SidebarKind.Home, "launch did not show Home");
            await window.OpenPathAsync(first, ShellPath.Launch);
            var editor = window.DebugEditor;
            Require(editor is not null && window.CurrentScreen == "editor" && window.ProjectPath == first, "first project did not open");
            Require(window.DebugSelectedRow?.Kind == SidebarKind.FullTake, "Full take is not selected after opening");
            Require(editor!.ViewModel.IsReadOnly && !editor.ViewModel.CanExport, "missing fixture media was not read-only");
            checks.Add("missing media is read-only; remaining navigation checks use a synthetic resolved-media state");
            editor.ViewModel.SetMediaUnavailable(false);
            await Gate("timeline", () => TimelineNativeProbe.RunAsync(window, editor.ViewModel.Project, checks));
            await Gate("transcript", () => TranscriptNativeProbe.RunAsync(window, editor.ViewModel.Project, checks));
            await Gate("layout", () => editor.DebugLayoutGateAsync(window, output, checks));
            await Gate("caption", () => editor.DebugCaptionGateAsync(window, output, checks));
            editor = window.DebugEditor!;
            await Gate("rewrite", () => editor.DebugRewriteGateAsync(window, output, checks));
            await Gate("busy-consent", () => editor.DebugBusyGateAsync(window, output, checks));
            editor!.ViewModel.Select(0); editor.ViewModel.Select(1, true);
            Require(editor.ViewModel.MakeClip() is not null, "manual clip was refused");
            await Task.Delay(1200); // let the 500 ms autosave settle before injecting failures
            checks.Add("opened the first project with Full take selected and made a clip");

            window.DebugSelect(window.Shell.Home);
            Require(window.CurrentScreen == "home", "the Home row did not show Home");
            Require(ReferenceEquals(window.DebugEditor, editor) && window.ProjectPath == first, "Home replaced or closed the editor");
            Require(!editor.ViewModel.IsLeaving && editor.ViewModel.CanExport, "Home ran the leave boundary");
            Require(window.Shell.Rows.Any(row => row.Kind == SidebarKind.FullTake) && window.Shell.Rows.Any(row => row.Kind == SidebarKind.Clip),
                "the project section left the sidebar on Home");
            Require(!window.Shell.Rows.Any(row => row.Kind == SidebarKind.Action), "pane actions showed on Home");
            checks.Add("sidebar Home kept the same editor object, its project section and its edits, without the leave boundary");
            await window.OpenPathAsync(first, ShellPath.HomeTile);
            Require(window.CurrentScreen == "editor" && ReferenceEquals(window.DebugEditor, editor) && !editor.ViewModel.IsLeaving,
                "opening the open project from Home did not return to its editor");
            window.DebugSelect(window.Shell.Home);
            checks.Add("opening the project this window holds returns to its editor without saving or replacing it");

            window.DebugSelect(window.Shell.ScopeRow(null)!);
            Require(window.CurrentScreen == "editor" && ReferenceEquals(window.DebugEditor, editor), "Full take did not return to the same editor");
            var clip = window.Shell.Rows.First(row => row.Kind == SidebarKind.Clip);
            window.DebugSelect(clip);
            Require(editor.ViewModel.State?.ActiveClipId == clip.ClipId && clip.IsActive, "the clip row did not set activeClipId");
            Require(editor.ViewModel.SelectionStart == editor.ViewModel.Index(editor.ViewModel.Clips.Single().Clip.StartWordId), "the clip row did not select its first word");
            editor.ViewModel.Undo();
            Require(editor.ViewModel.State?.ActiveClipId is null && window.DebugSelectedRow?.Kind == SidebarKind.FullTake, "undo did not return the selection to Full take");
            checks.Add("Full take and clip rows drive activeClipId; undo synchronises the selected row");

            await App.Services.RememberAsync(second, CancellationToken.None);
            window.DebugSelect(window.Shell.Home);
            var recent = window.Shell.Rows.FirstOrDefault(row => row.Kind == SidebarKind.Recent && row.Recent!.Path.Equals(second, StringComparison.OrdinalIgnoreCase));
            Require(recent is not null, "the second project is not in the sidebar Recent list");
            await using (new FileStream(first, FileMode.Open, FileAccess.Read, FileShare.None))
                await window.DebugInvokeAsync(recent!);
            Require(ReferenceEquals(window.DebugEditor, editor) && window.ProjectPath == first, "a failed save let Recent replace the first project");
            Require(!editor.ViewModel.IsLeaving && editor.ViewModel.CanExport, "the first editor stayed frozen after the failed save");
            Require(editor.ViewModel.Notice.StartsWith("Couldn't save this project.", StringComparison.Ordinal), "the failed save did not explain itself");
            checks.Add("Recent with an injected save failure kept the first editor, editable, with the save notice");

            Require(window.CurrentScreen == "editor", "the refused leave stayed on Home, so its notice was hidden");
            checks.Add("the refused leave from Home brought the editor and its notice back");

            window.DebugSelect(window.Shell.Home);
            await using (new FileStream(first, FileMode.Open, FileAccess.Read, FileShare.None))
                await window.DebugRequestCloseAsync();
            Require(App.Windows.Contains(window) && ReferenceEquals(window.DebugEditor, editor) && window.CurrentScreen == "editor",
                "a refused close from Home closed the window or left the editor hidden");
            Require(editor.ViewModel.Notice.StartsWith("Couldn't save this project.", StringComparison.Ordinal), "the refused close did not explain itself");
            checks.Add("closing from Home with an injected save failure kept the window and showed the editor with its notice");

            window.DebugSelect(window.Shell.Home);
            await window.DebugInvokeAsync(recent!);
            Require(window.ProjectPath == second && window.DebugEditor is { } secondEditor && !ReferenceEquals(secondEditor, editor), "Recent did not open the second project. " + window.DebugOpenError);
            Require(window.DebugSelectedRow?.Kind == SidebarKind.FullTake && window.CurrentScreen == "editor", "Recent did not show the editor with Full take");
            var saved = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(first));
            Require(saved.Edits.Clips.Count == 1, "the first project was not saved before Recent replaced it");
            checks.Add("Recent saved the first project, then replaced it in place");

            var replaced = window.DebugEditor!;
            replaced.ViewModel.SetMediaUnavailable(false);
            await using (new FileStream(second, FileMode.Open, FileAccess.Read, FileShare.None))
            {
                replaced.ViewModel.Select(2); replaced.ViewModel.Correct("probe-drop");
                await window.OpenDroppedAsync(third);
            }
            Require(ReferenceEquals(window.DebugEditor, replaced) && window.ProjectPath == second, "a failed save let the drop replace the project");
            await window.OpenDroppedAsync(Path.Combine(output, "clip.avi"));
            Require(window.DebugNotice.StartsWith("VoxClip can't open AVI files on PC yet.", StringComparison.Ordinal) && ReferenceEquals(window.DebugEditor, replaced),
                "an unsupported drop changed the project or showed the wrong copy");
            await window.OpenDroppedAsync(third);
            Require(window.ProjectPath == third && !ReferenceEquals(window.DebugEditor, replaced), "the drop did not open the third project");
            saved = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(second));
            Require(saved.Edits.Corrections.Values.Contains("probe-drop"), "the second project was not saved before the drop replaced it");
            checks.Add("drop with an injected save failure kept the editor; an unsupported type showed the copy; drop saved, then replaced");

            // The sidebar's header rows host real controls (design §3.4, §13): each is enabled, named for Narrator and acts.
            var last = window.DebugEditor!;
            last.ViewModel.SetMediaUnavailable(false);
            var words = last.ViewModel.Words;
            last.ViewModel.AddAiResult(new AiResult("probe-run", DateTimeOffset.UtcNow, "anthropic", "probe-model", ClipPreset.Best, null, "en", new string('0', 64),
                [new AiClip("Probe idea one", "Probe reason", 8, words[2].Id, words[4].Id), new AiClip("Probe idea two", "Probe reason", 7, words[6].Id, words[8].Id)]));
            await Until(() => window.Shell.Rows.Any(row => row.Kind == SidebarKind.SuggestedHeader), "the sidebar did not realize suggestions");
            var header = window.Shell.Rows.Single(row => row.Kind == SidebarKind.SuggestedHeader);
            Require(header.Title == "Suggested (2)" && header.ShowsKeepAll, "two suggestions did not show Suggested (2) with Keep all");
            Invoke(await ControlIn<HyperlinkButton>(window, header, "Keep all suggested clips"));
            Require(!window.Shell.Rows.Any(row => row.Kind == SidebarKind.Suggestion), "Keep all did not keep the suggestions");
            checks.Add("Suggested (2) showed an enabled, named Keep all that kept both suggestions");

            last.FindClips.DebugShowFinding("Probe · reading 0:16 of transcript");
            Invoke(await ControlIn<HyperlinkButton>(window, window.Shell.Rows.Single(row => row.Kind == SidebarKind.Finding), "Cancel finding clips"));
            last.FindClips.DebugShowFinding(null);
            checks.Add("Finding clips… showed an enabled, named Cancel");

            Require(App.Services.Get("llm.connector", "").Length == 0, "the probe data root has a connector");
            last.ShowFindClips(null);
            await Until(() => window.Shell.Rows.Any(row => row.Kind == SidebarKind.Callout), "Find clips with no connector showed no callout");
            var callout = window.Shell.Rows.Single(row => row.Kind == SidebarKind.Callout);
            Require(callout.Title == ClipCallouts.NoConnector.Title, "the no-connector callout has the wrong copy");
            var setUp = await ControlIn<Button>(window, callout, ClipCallouts.SetUp);
            await Until(() => window.DebugCalloutTipOpen, "no tip pointed at the callout from the command bar");
            Invoke(setUp);
            await Until(() => App.Settings is not null, "Set up AI… did not open Settings");
            App.Settings!.Close();
            checks.Add("with no connector, Find clips showed the callout under the actions, a tip pointing at it, and a named Set up AI… that opens Settings");

            var other = App.NewWindow();
            Require(other.CurrentScreen == "home" && other.DebugEditor is null && other.DebugSelectedRow?.Kind == SidebarKind.Home, "Ctrl+N did not open a window on Home");
            other.Close();
            checks.Add("a new window opens on Home");
            Require(failures.Count == 0, string.Join("\n\n", failures));
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new { status = "passed", checks }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception exception)
        {
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new { status = "failed", checks, error = exception + (window.DebugOpenError is { } openError ? "\nProject open: " + openError : "") },
                new JsonSerializerOptions { WriteIndented = true }));
            throw;
        }
    }

    private static void Require(bool condition, string reason)
    {
        if (!condition) throw new InvalidOperationException(reason);
    }

    private static async Task Until(Func<bool> condition, string reason)
    {
        for (var attempt = 0; attempt < 50 && !condition(); attempt++) await Task.Delay(100);
        Require(condition(), reason);
    }

    /// <summary>The control named <paramref name="name"/> inside a sidebar row, checked the way Narrator and a click reach it:
    /// the row is in the content view and enabled, and the control is a visible, enabled control element.</summary>
    private static async Task<T> ControlIn<T>(MainWindow window, SidebarRow row, string name) where T : Control
    {
        await Until(() => window.DebugContainer(row) is { ActualHeight: > 0 }, $"the {row.Kind} row was not realized");
        var container = (Control)window.DebugContainer(row)!;
        Require(container.IsEnabled && AutomationProperties.GetAccessibilityView(container) == AccessibilityView.Content, $"the {row.Kind} row is disabled or hidden from Narrator");
        var control = Descendants(container).OfType<T>().FirstOrDefault(item => FrameworkElementAutomationPeer.CreatePeerForElement(item).GetName() == name);
        Require(control is not null, $"the {row.Kind} row has no control named \"{name}\"");
        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(control!);
        Require(control!.IsEnabled && peer.IsEnabled() && peer.IsControlElement() && control.Visibility == Visibility.Visible && control.ActualWidth > 0,
            $"\"{name}\" is not a visible, enabled control element");
        return control;
    }

    private static void Invoke(Control control) =>
        ((IInvokeProvider)FrameworkElementAutomationPeer.CreatePeerForElement(control).GetPattern(PatternInterface.Invoke)).Invoke();

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
}
#endif
