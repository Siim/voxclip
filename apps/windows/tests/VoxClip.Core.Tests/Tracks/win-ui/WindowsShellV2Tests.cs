#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class WindowsShellV2Tests
{
    [Fact]
    public void RowRewriteClearsThePreviousSelectionWithoutEditingTheClip()
    {
        var model = Model();
        var clip = model.Clips.First(clip => !clip.IsSuggested);
        model.Select(0);
        model.Select(2, true);
        model.SetScope(clip.Id);
        var project = model.Project;
        var revision = model.RewriteSelectionRevision;
        var notifications = 0;
        model.SelectionChanged += (_, _) => notifications++;
        model.ClearSelection();
        Assert.False(model.HasSelection);
        Assert.Equal("", model.SelectionText);
        Assert.Equal(clip.Id, model.State?.ActiveClipId);
        Assert.Same(project, model.Project);
        Assert.False(model.IsDirty);
        Assert.False(model.CanUndo);
        Assert.Equal(revision + 1, model.RewriteSelectionRevision);
        Assert.Equal(1, notifications);
        model.ClearSelection();
        Assert.Equal(1, notifications);
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(true, false, true)]
    [InlineData(false, true, true)]
    [InlineData(true, true, true)]
    public void ClipRowActionsReplaceDurationOnSelectionOrHover(bool selected, bool hovered, bool visible)
    {
        var row = new SidebarRow(SidebarKind.Clip, "clip:first") { Number = "12" };
        Assert.Equal(32, row.RowHeight);
        var changed = new List<string?>();
        row.PropertyChanged += (_, args) => changed.Add(args.PropertyName);
        row.IsSelected = selected;
        row.IsPointerOver = hovered;
        Assert.Equal(visible, row.ShowsActions);
        Assert.Equal(!visible, row.ShowsDuration);
        Assert.Equal(32, row.RowHeight);
        Assert.Equal("Rewrite Clip 12", row.RewriteName);
        Assert.Equal("Rewrite Clip 12 (Ctrl+R)", row.RewriteHelp);
        if (visible)
        {
            Assert.Contains(nameof(SidebarRow.ShowsActions), changed);
            Assert.Contains(nameof(SidebarRow.ShowsDuration), changed);
        }
        row.IsSelected = false;
        row.IsPointerOver = false;
        Assert.False(row.ShowsActions);
        Assert.True(row.ShowsDuration);
    }

    /// <summary>The user never saw the row actions: a selected or hovered suggestion shows ✦ and ⋯ in its duration's place.</summary>
    [Theory]
    [InlineData(false, false, false)]
    [InlineData(true, false, true)]
    [InlineData(false, true, true)]
    public void SuggestionRowActionsShowOnSelectionOrHover(bool selected, bool hovered, bool visible)
    {
        var row = new SidebarRow(SidebarKind.Suggestion, "suggestion:first") { Number = "5", IsSelected = selected, IsPointerOver = hovered };
        Assert.Equal(visible, row.ShowsActions);
        Assert.Equal(!visible, row.ShowsDuration);
        Assert.Equal(28, row.RowHeight);
        Assert.Equal("Rewrite Clip 5", row.RewriteName);
    }

    /// <summary>Rewrite and Export on a suggestion keep it first, as one undo step with no prompt; a kept clip adds no step.</summary>
    [Fact]
    public void RowActionKeepsASuggestionInOneUndoStep()
    {
        var model = Model(suggestion: true);
        var suggestion = model.Clips.First(clip => clip.IsSuggested).Id;
        var kept = model.Clips.First(clip => !clip.IsSuggested).Id;
        Assert.False(model.CanUndo);
        Assert.True(model.KeepForRowAction(kept));
        Assert.False(model.CanUndo);
        Assert.True(model.KeepForRowAction(suggestion));
        Assert.False(model.Clips.Single(clip => clip.Id == suggestion).IsSuggested);
        Assert.True(model.CanUndo);
        model.Undo();
        Assert.True(model.Clips.Single(clip => clip.Id == suggestion).IsSuggested);
        Assert.False(model.CanUndo);
        Assert.False(model.KeepForRowAction("missing"));
        model.SetMediaUnavailable(true);
        Assert.False(model.KeepForRowAction(suggestion));
        Assert.True(model.Clips.Single(clip => clip.Id == suggestion).IsSuggested);
    }

    [Theory]
    [InlineData(SidebarKind.FullTake)]
    [InlineData(SidebarKind.Home)]
    public void OtherRowsKeepTheirExistingActionsAndDuration(SidebarKind kind)
    {
        var row = new SidebarRow(kind, "other") { IsSelected = true, IsPointerOver = true };
        Assert.False(row.ShowsActions);
        Assert.True(row.ShowsDuration);
    }

    [Fact]
    public void ClipRewriteAvailabilityRequiresEditableKeptWordsWithoutVoiceLab()
    {
        var model = Model();
        var shell = new ShellViewModel();
        var clip = model.Clips.First(clip => !clip.IsSuggested).Clip;
        shell.Update(model, false, [], null);
        var row = Assert.Single(shell.Rows, row => row.Kind == SidebarKind.Clip && row.ClipId == clip.Id);
        Assert.True(row.CanRewrite);

        shell.Update(model, true, [], null);
        Assert.False(row.CanRewrite);
        model.Busy = true;
        shell.Update(model, false, [], null);
        Assert.False(row.CanRewrite);
        model.Busy = false;
        model.SetMediaUnavailable(true);
        shell.Update(model, false, [], null);
        Assert.False(row.CanRewrite);
        model.SetMediaUnavailable(false);
        var first = model.Index(clip.StartWordId);
        var last = model.Index(clip.EndWordId);
        model.Select(first);
        model.Select(last, true);
        model.CutSelection();
        shell.Update(model, false, [], null);
        Assert.False(row.CanRewrite);
    }

    [Fact]
    public void SuggestionRowsOfferRewriteLikeKeptClips()
    {
        var model = Model(suggestion: true);
        var shell = new ShellViewModel();
        shell.Update(model, false, [], null);
        var row = Assert.Single(shell.Rows, row => row.Kind == SidebarKind.Suggestion);
        Assert.True(row.CanRewrite);
        shell.Update(model, true, [], null);
        Assert.False(row.CanRewrite);
    }

    [Fact]
    public void ClipRowActionsReuseTheContextMenuAndDoNotSelectOrAddKeyboardStops()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var app = Path.Combine(root, "apps/windows/src/VoxClip.App");
        var window = File.ReadAllText(Path.Combine(app, "MainWindow.xaml"));
        var clip = window.Split("x:Key=\"ClipRow\"")[1].Split("</DataTemplate>")[0];
        var suggestion = window.Split("x:Key=\"SuggestionRow\"")[1].Split("</DataTemplate>")[0];
        Assert.Contains("PointerEntered=\"ClipRowPointerEntered\"", clip);
        Assert.Contains("PointerExited=\"ClipRowPointerExited\"", clip);
        Assert.Contains("Visibility=\"{x:Bind ShowsActions, Mode=OneWay}\"", clip);
        Assert.Contains("Visibility=\"{x:Bind ShowsDuration, Mode=OneWay}\"", clip);
        Assert.Contains("<Grid ColumnSpacing=\"8\" MinHeight=\"32\">", clip);
        // The row ✦ is Make it postable (design §6.7); Rewrite stays in the row's menu.
        Assert.Contains("Click=\"MakeItClipClicked\" Tapped=\"RowButtonTapped\"", clip);
        Assert.Contains("Click=\"MoreClipClicked\" Tapped=\"RowButtonTapped\"", clip);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind MakeItName, Mode=OneWay}\"", clip);
        Assert.Contains("AutomationProperties.Name=\"More\"", clip);
        Assert.Equal(2, clip.Split("Style=\"{ThemeResource SubtleButtonStyle}\"").Length - 1);
        Assert.Contains("IsTabStop=\"False\"", clip);
        Assert.Equal(1, clip.Split("<MenuFlyout>").Length - 1);
        Assert.Contains("PointerEntered=\"ClipRowPointerEntered\"", suggestion);
        Assert.Contains("Visibility=\"{x:Bind ShowsActions, Mode=OneWay}\"", suggestion);
        Assert.Contains("Visibility=\"{x:Bind ShowsDuration, Mode=OneWay}\"", suggestion);
        Assert.Contains("Click=\"MakeItClipClicked\" Tapped=\"RowButtonTapped\"", suggestion);
        Assert.Contains("Click=\"MoreClipClicked\" Tapped=\"RowButtonTapped\"", suggestion);
        Assert.Equal(1, suggestion.Split("<MenuFlyout>").Length - 1);
        foreach (var template in new[] { clip, suggestion })
            foreach (var handler in new[] { "MakeItClipClicked", "RewriteClipClicked", "CaptionsClipClicked", "FindMoreClipsClicked", "ExportClipClicked" })
                Assert.Contains($"Click=\"{handler}\"", template.Split("</MenuFlyout>")[0]);
        Assert.Contains("Text=\"Keep clip\"", suggestion);
        Assert.Contains("Text=\"Dismiss\"", suggestion);
        Assert.Contains("Click=\"KeepClicked\" Tapped=\"RowButtonTapped\"", suggestion);
        Assert.Contains("Click=\"DismissClicked\" Tapped=\"RowButtonTapped\"", suggestion);
        var code = File.ReadAllText(Path.Combine(app, "MainWindow.xaml.cs"));
        Assert.Contains("menu.ShowAt(button)", code);
        Assert.Contains("command.TryExecute()", code);
        var rewrite = code.Split("private void RewriteClipClicked")[1].Split("private void ScopeRowKeys")[0];
        Assert.Contains("ShowScope(id)", rewrite);
        Assert.True(rewrite.IndexOf("KeepForRowAction(id)", StringComparison.Ordinal) is >= 0 and var keep && keep < rewrite.IndexOf("ShowScope(id)", StringComparison.Ordinal));
        var export = code.Split("private async void ExportClipClicked")[1].Split("private void CaptionsClipClicked")[0];
        Assert.True(export.IndexOf("KeepForRowAction(id)", StringComparison.Ordinal) is >= 0 and var kept && kept < export.IndexOf("ExportClipAsync(id)", StringComparison.Ordinal));
        Assert.Contains("page.ViewModel.ClearSelection()", rewrite);
        Assert.True(rewrite.IndexOf("ClearSelection()", StringComparison.Ordinal) < rewrite.IndexOf("command.TryExecute()", StringComparison.Ordinal));
        Assert.Contains("args.Handled = true", code);
    }

    /// <summary>The status bar and Settings name the effort AI decisions send (AI §2.1); a connector that ignores it shows none.</summary>
    [Theory]
    [InlineData("claude-code", "Claude Code", "opus", "Claude Code · Opus (latest) · extra high", "AI decisions use extra high effort.")]
    [InlineData("anthropic", "Anthropic", "claude-sonnet-5-5", "Anthropic · Claude Sonnet 5.5 · extra high", "AI decisions use extra high effort.")]
    [InlineData("openai", "OpenAI", "gpt-5.6-terra", "OpenAI · GPT-5.6 Terra · high", "AI decisions use high effort.")]
    [InlineData("codex", "Codex", "custom-model", "Codex · custom-model · high", "AI decisions use high effort.")]
    [InlineData("ollama", "Ollama", "gemma4:12b", "Ollama · gemma4:12b", null)]
    public void TheAINamesItsDecisionEffort(string id, string shortName, string model, string status, string? note)
    {
        var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
        using var catalog = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(shared, "catalog", "llm-providers.json")));
        var connector = catalog.RootElement.GetProperty("connectors").EnumerateArray().Single(item => item.GetProperty("id").GetString() == id);
        Assert.Equal(status, AiEffortLabel.Status(shortName, connector, model));
        Assert.Equal(note, AiEffortLabel.SettingsNote(connector));
    }

    /// <summary>The long-take fixture; with <paramref name="suggestion"/>, its AI clip is still a suggestion (not kept).</summary>
    private static EditorViewModel Model(bool suggestion = false)
    {
        var project = HomeViewModelTests.Fixture("clip-from-long-take.voxclip");
        var clips = project.Edits.Clips.Select(clip => suggestion && clip.Origin == ClipOrigin.Ai ? clip with { Selected = false } : clip).ToArray();
        return new(project with { Edits = project.Edits with { Clips = clips, ActiveClipId = null, CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>() } });
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
    public void EditorTabStripHostsANativeTabViewInsteadOfInheritingItsStyle()
    {
        // The managed surrogate cannot apply WinUI styles on this host. Protect the
        // composition that keeps TabView's native runtime type for its default style.
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Controls/EditorTabStrip.cs"));
        Assert.Matches(@"class\s+EditorTabStrip\s*:\s*Grid\b", source);
        Assert.Contains("private readonly TabView tabs = new();", source);
        Assert.Contains("Children.Add(tabs);", source);
        Assert.Contains("AutomationProperties.SetName(tabs, \"Editor tabs\");", source);
        Assert.Contains("internal object? SelectedItem => tabs.SelectedItem;", source);
        Assert.Contains("tabs.SelectionChanged +=", source);
        Assert.Contains("tabs.TabCloseRequested +=", source);
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
