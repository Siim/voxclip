#if DEBUG
using System.Text.Json;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Services;

/// <summary>Isolated, Debug-only WinUI-thread acceptance probe for the ADR-R29 navigation paths. Sidebar Home keeps the
/// editor; Recent and drop replace the project only through OpenPathAsync's save-before-leaving boundary.</summary>
internal static class ShellNativeProbe
{
    internal static async Task RunAsync(MainWindow window, string output)
    {
        Directory.CreateDirectory(output);
        var checks = new List<string>();
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
            await window.OpenPathAsync(first);
            var editor = window.DebugEditor;
            Require(editor is not null && window.CurrentScreen == "editor" && window.ProjectPath == first, "first project did not open");
            Require(window.DebugSelectedRow?.Kind == SidebarKind.FullTake, "Full take is not selected after opening");
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
            await window.OpenPathAsync(first);
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
            Require(editor.ViewModel.Notice.StartsWith("Could not save this project.", StringComparison.Ordinal), "the failed save did not explain itself");
            checks.Add("Recent with an injected save failure kept the first editor, editable, with the save notice");

            await window.DebugInvokeAsync(recent!);
            Require(window.ProjectPath == second && window.DebugEditor is { } secondEditor && !ReferenceEquals(secondEditor, editor), "Recent did not open the second project");
            Require(window.DebugSelectedRow?.Kind == SidebarKind.FullTake && window.CurrentScreen == "editor", "Recent did not show the editor with Full take");
            var saved = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(first));
            Require(saved.Edits.Clips.Count == 1, "the first project was not saved before Recent replaced it");
            checks.Add("Recent saved the first project, then replaced it in place");

            var replaced = window.DebugEditor!;
            replaced.ViewModel.Select(2); replaced.ViewModel.Correct("probe-drop");
            await Task.Delay(1200);
            await using (new FileStream(second, FileMode.Open, FileAccess.Read, FileShare.None))
                await window.OpenDroppedAsync(third);
            Require(ReferenceEquals(window.DebugEditor, replaced) && window.ProjectPath == second, "a failed save let the drop replace the project");
            await window.OpenDroppedAsync(Path.Combine(output, "clip.avi"));
            Require(window.DebugNotice.StartsWith("VoxClip can't open AVI files on PC yet.", StringComparison.Ordinal) && ReferenceEquals(window.DebugEditor, replaced),
                "an unsupported drop changed the project or showed the wrong copy");
            await window.OpenDroppedAsync(third);
            Require(window.ProjectPath == third && !ReferenceEquals(window.DebugEditor, replaced), "the drop did not open the third project");
            saved = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(second));
            Require(saved.Edits.Corrections.Values.Contains("probe-drop"), "the second project was not saved before the drop replaced it");
            checks.Add("drop with an injected save failure kept the editor; an unsupported type showed the copy; drop saved, then replaced");

            var other = App.NewWindow();
            Require(other.CurrentScreen == "home" && other.DebugEditor is null && other.DebugSelectedRow?.Kind == SidebarKind.Home, "Ctrl+N did not open a window on Home");
            other.Close();
            checks.Add("a new window opens on Home");
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new { status = "passed", checks }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception exception)
        {
            await File.WriteAllTextAsync(report, JsonSerializer.Serialize(new { status = "failed", checks, error = exception.ToString() },
                new JsonSerializerOptions { WriteIndented = true }));
            throw;
        }
    }

    private static void Require(bool condition, string reason)
    {
        if (!condition) throw new InvalidOperationException(reason);
    }
}
#endif
