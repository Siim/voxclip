#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class WindowsShellV2Tests
{
    private static EditorViewModel Model()
    {
        var project = HomeViewModelTests.Fixture("clip-from-long-take.voxclip");
        return new(project with { Edits = project.Edits with { ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() } });
    }

    [Fact]
    public void OnlyOnePreviewIsReplacedAndFullTakeCannotClose()
    {
        var tabs = new EditorTabs();
        tabs.Open("first", "First", false);
        tabs.Open("second", "Second", true);
        Assert.Equal(new string?[] { null, "second" }, tabs.Items.Select(tab => tab.ClipId));
        Assert.True(tabs.Items[1].Suggested);
        Assert.False(tabs.Items[1].Pinned);
        Assert.Equal("second", tabs.ActiveClipId);
        Assert.False(tabs.Close(null));
        Assert.False(tabs.Close("missing"));
    }

    [Fact]
    public void PinnedTabsSurvivePreviewReplacementAndClosingInactiveDoesNotNavigate()
    {
        var tabs = new EditorTabs();
        tabs.Open("first", "First", false);
        tabs.Pin("first");
        tabs.Open("second", "Second", false);
        tabs.Open("third", "Third", true);
        Assert.Equal(new string?[] { null, "first", "third" }, tabs.Items.Select(tab => tab.ClipId));
        Assert.Equal("first", tabs.Adjacent(-1));
        Assert.Null(tabs.Adjacent(1));
        Assert.True(tabs.Close("first"));
        Assert.Equal("third", tabs.ActiveClipId);
        Assert.True(tabs.Close("third"));
        Assert.Null(tabs.ActiveClipId);
        Assert.Single(tabs.Items);
    }

    [Fact]
    public void ReconcileUsesLiveClipNamesAndRemovesDeletedClips()
    {
        var model = Model();
        var clip = model.Clips[0];
        var tabs = new EditorTabs();
        tabs.Open(clip.Id, clip.Title, false, pin: true);
        Assert.True(model.Rename(clip.Id, "A new title"));
        tabs.Reconcile(model.Clips);
        Assert.Equal("A new title", tabs.Items[1].Title);
        Assert.True(model.Remove(clip.Id));
        tabs.Reconcile(model.Clips);
        Assert.Single(tabs.Items);
        Assert.Null(tabs.ActiveClipId);
    }

    [Fact]
    public async Task ScopeChangesKeepTheDirtyIdentityTimestampAndHistoryUntouched()
    {
        var model = Model();
        var snapshot = model.Project;
        var changes = new List<bool>();
        var saves = 0;
        model.Changed += (_, _) => changes.Add(model.IsScopeChange);
        model.SaveRequested += (_, _) => saves++;
        var clip = model.Clips[0].Id;
        Assert.True(model.SetScope(clip));
        Assert.Equal(clip, model.State!.ActiveClipId);
        Assert.Equal(clip, model.Project.Edits.ActiveClipId);
        Assert.Equal(snapshot.ModifiedAt, model.Project.ModifiedAt);
        Assert.False(model.IsDirty);
        Assert.False(model.CanUndo);
        Assert.False(model.CanRedo);
        Assert.True(model.SetScope(null));
        Assert.Equal(snapshot, model.Project);
        Assert.False(model.SetScope("missing"));
        Assert.False(model.SetScope(null));
        Assert.Equal([true, true], changes);
        Assert.False(model.IsScopeChange);
        Assert.Equal(0, saves);
        var pending = new PendingProjectSave(model.Project, model.MarkSaved);
        Assert.False(pending.HasChanges);
        Assert.True(model.Apply(new EditOperation.SetWordCuts([model.Words[0].Id], true)));
        pending.Mark(model.Project);
        var modified = model.Project.ModifiedAt;
        Assert.True(model.SetScope(clip));
        Assert.True(pending.HasChanges);
        pending.Mark(model.Project);
        Project? written = null;
        await pending.FlushAsync((project, _) => { written = project; return Task.CompletedTask; }, CancellationToken.None);
        Assert.NotNull(written);
        Assert.Equal(clip, written.Edits.ActiveClipId);
        Assert.Equal(modified, written.ModifiedAt);
        Assert.Contains(model.Words[0].Id, written.Edits.CutWordIds);
        Assert.False(model.IsDirty);
    }

    [Fact]
    public void ExplorerOutlineUsesRealParagraphsAndKeepsItsRowsAcrossScopeChanges()
    {
        var model = Model();
        var shell = new ShellViewModel();
        shell.Update(model, false, [], null);
        var outline = shell.Rows.Where(row => row.Kind == SidebarKind.Outline).ToArray();
        Assert.Equal(model.Paragraphs.Select(paragraph => paragraph.StartIndex), outline.Select(row => row.WordIndex));
        Assert.All(outline, row => Assert.Contains(model.DisplayText(model.Words[row.WordIndex]), row.Title));
        Assert.True(model.SetScope(model.Clips[0].Id));
        shell.Update(model, false, [], null);
        Assert.Equal(outline, shell.Rows.Where(row => row.Kind == SidebarKind.Outline));
        Assert.False(model.IsDirty);
    }

    [Fact]
    public void FocusTraversalIncludesTabsAndStatusAndWrapsEveryRegion()
    {
        Assert.Equal(new[] { EditorFocusRegion.Pane, EditorFocusRegion.Tabs, EditorFocusRegion.CommandBar, EditorFocusRegion.Transcript,
            EditorFocusRegion.Viewer, EditorFocusRegion.Captions, EditorFocusRegion.Timeline, EditorFocusRegion.Status }, FocusCycle.Regions(true));
        Assert.Equal([1, 2, 3, 4, 5, 6, 7, 0], FocusCycle.NextIndices(0, 8, false));
        Assert.Equal([7, 6, 5, 4, 3, 2, 1, 0], FocusCycle.NextIndices(0, 8, true));
    }

    [Fact]
    public void TabNavigationPreservesRedoAndExistingDirtyEdits()
    {
        var model = Model();
        var word = model.Words[0].Id;
        Assert.True(model.Apply(new EditOperation.SetWordCuts([word], true)));
        model.Undo();
        Assert.True(model.CanRedo);
        Assert.False(model.IsDirty);
        Assert.True(model.SetScope(model.Clips[0].Id));
        Assert.True(model.CanRedo);
        Assert.False(model.IsDirty);
        model.Redo();
        Assert.Contains(word, model.State!.CutWordIds);
        Assert.True(model.IsDirty);
        var modified = model.Project.ModifiedAt;
        Assert.True(model.SetScope(model.Clips[0].Id));
        Assert.Equal(modified, model.Project.ModifiedAt);
        Assert.True(model.IsDirty);
        model.Undo();
        Assert.DoesNotContain(word, model.State!.CutWordIds);
    }

    [Fact]
    public void ReadOnlyTabsNavigateWithoutEnablingEditingAndLeavingStillRefuses()
    {
        var model = Model();
        model.SetMediaUnavailable(true);
        var clip = model.Clips[0].Id;
        Assert.True(model.SetScope(clip));
        Assert.True(model.IsReadOnly);
        Assert.False(model.IsDirty);
        Assert.False(model.CanUndo);
        Assert.False(model.Apply(new EditOperation.CutFillers()));
        Assert.False(model.Apply(new EditOperation.SetActiveClip(null)));
        model.BeginLeaving();
        Assert.False(model.SetScope(null));
        Assert.Equal(clip, model.State!.ActiveClipId);
    }

    [Fact]
    public void OneTightenUndoRestoresBothKindsOfCutsAndNoOtherScope()
    {
        var model = Model();
        var project = model.Project;
        var transcript = project.Transcript!;
        model = new(project with { Transcript = transcript with { Words = transcript.Words.Select((word, index) => index is 0 or 17 ? word with { Text = "um" } : word).ToArray() } });
        Assert.True(model.SetScope(model.Clips[1].Id));
        var before = model.State!;
        Assert.True(model.ApplyBatch([new EditOperation.CutFillers(), new EditOperation.TightenPauses()]));
        var after = model.State!;
        Assert.Contains(model.Words[17].Id, after.CutWordIds);
        Assert.DoesNotContain(model.Words[0].Id, after.CutWordIds);
        Assert.True(after.CutPauseIds.Count > before.CutPauseIds.Count);
        model.Undo();
        Assert.Equal(before, model.State);
        Assert.False(model.CanUndo);
        Assert.False(model.IsDirty);
    }

    [Fact]
    public void PaletteFiltersEveryTermWithoutDroppingDisabledCommandsAndRechecksAtInvocation()
    {
        var enabled = true;
        var invocations = 0;
        var export = new ShellCommand("export", "Export clip…", "Ctrl+E", () => enabled, () => invocations++, "Locate the original video first.");
        var commands = new[] { export, new ShellCommand("undo", "Undo", "Ctrl+Z", () => false, () => throw new InvalidOperationException()) };
        Assert.Same(export, Assert.Single(ShellCommands.Filter(commands, "CLIP ctrl+e")));
        Assert.Empty(ShellCommands.Filter(commands, "Export redo"));
        enabled = false;
        Assert.Contains(export, ShellCommands.Filter(commands, "export"));
        Assert.False(export.IsEnabled);
        Assert.Equal("Locate the original video first.", export.Detail);
        Assert.False(export.TryExecute());
        Assert.Equal(0, invocations);
        enabled = true;
        Assert.True(export.TryExecute());
        Assert.Equal(1, invocations);
    }

    [Fact]
    public void ImeCommitAndEscapeCannotSubmitOrDismissTheShellInTheSameKeyEvent()
    {
        var input = new ShellInputSession();
        input.CompositionStarted();
        Assert.False(input.MaySubmit(false));
        Assert.False(input.MayDismiss(false));
        input.CompositionEnded();
        Assert.False(input.MaySubmit(true));
        Assert.False(input.MayDismiss(true));
        Assert.True(input.MaySubmit(false));
        Assert.True(input.MayDismiss(false));
    }

    [Fact]
    public void ShellSourceMountsExistingChildrenAndHasNoReplacementModalOrInsertionRoute()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var app = Path.Combine(root, "apps/windows/src/VoxClip.App");
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml"));
        var page = File.ReadAllText(Path.Combine(app, "Pages/EditorPage.xaml"));
        var code = File.ReadAllText(Path.Combine(app, "Pages/EditorPage.xaml.cs"));
        var palette = File.ReadAllText(Path.Combine(app, "Controls/CommandPalette.cs"));
        Assert.Contains("controls:ExplorerPane", window);
        Assert.DoesNotContain("NavigationView", window);
        Assert.Contains("controls:ClipBar", page);
        Assert.DoesNotContain("CommandRow", page);
        Assert.Contains("controls:TranscriptView", page);
        Assert.Contains("controls:TimelineView", page);
        Assert.Contains("x:Name=\"CaptionsHost\"", page);
        Assert.DoesNotContain("InsertWordsRequested +=", code);
        Assert.DoesNotContain("ContentDialog", palette);
        Assert.DoesNotContain("Popup", palette);
        Assert.Contains("command.TryExecute()", palette);
        Assert.Contains("!ViewModel.IsScopeChange", code);
        Assert.Contains("if (projectWrites.HasChanges && !ViewModel.IsReadOnly) projectWrites.Mark(ViewModel.Project)", code);
        Assert.False(File.Exists(Path.Combine(app, "Controls/SidebarItems.cs")));
    }
}
#endif
