#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>The ADR-R29 sidebar: design §2 and §3.4.</summary>
public sealed class ShellViewModelTests
{
    private static Project Fixture(string name)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, "shared", "fixtures", "projects", name);
            if (File.Exists(path)) return ProjectSerialization.Deserialize(File.ReadAllText(path));
        }
        throw new FileNotFoundException("Shared project fixture not found.", name);
    }

    /// <summary>The long-take fixture with its AI clip left unchecked: one kept manual clip and one suggestion.</summary>
    private static EditorViewModel WithSuggestion()
    {
        var project = Fixture("clip-from-long-take.voxclip");
        var clips = project.Edits.Clips.Select(clip => clip.Origin == ClipOrigin.Ai ? clip with { Selected = false } : clip).ToArray();
        return new EditorViewModel(project with { Edits = project.Edits with { Clips = clips, ActiveClipId = null } });
    }

    /// <summary>Design §2: while Home shows, the editor is hidden, so the project's clip, suggestion, Suggested and none-found
    /// rows only navigate. Keep, Dismiss, Rename, Remove, Export clip…, Keep all and Find clips… come back with the editor,
    /// on the same row instances.</summary>
    [Fact]
    public void OnHomeTheProjectsRowsOnlyNavigate()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel { NoneFound = "No clips found. Try another preset." };
        shell.Update(editor, true, [], null);
        SidebarKind[] project = [SidebarKind.Clip, SidebarKind.SuggestedHeader, SidebarKind.Suggestion, SidebarKind.NoneFound];
        var rows = shell.Rows.Where(row => project.Contains(row.Kind)).ToArray();
        Assert.Equal(project, rows.Select(row => row.Kind));
        Assert.All(rows, row => Assert.False(row.Edits, row.Key));
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.Action);
        shell.Update(editor, false, [], null);
        Assert.All(rows, row => Assert.Contains(row, shell.Rows));
        Assert.All(rows, row => Assert.True(row.Edits, row.Key));
        shell.Update(editor, true, [], null);
        Assert.All(rows, row => Assert.False(row.Edits, row.Key));
    }

    [Fact]
    public void EditorRowsFollowTheSharedOrder()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        Assert.Equal([SidebarKind.Home, SidebarKind.Separator, SidebarKind.Project, SidebarKind.FullTake, SidebarKind.Clip,
            SidebarKind.SuggestedHeader, SidebarKind.Suggestion, SidebarKind.Separator, SidebarKind.Action, SidebarKind.Action],
            shell.Rows.Select(row => row.Kind));
        var kept = shell.Rows.Single(row => row.Kind == SidebarKind.Clip);
        var suggestion = shell.Rows.Single(row => row.Kind == SidebarKind.Suggestion);
        Assert.Equal(("1", "Iga sõna asukoht"), (kept.Number, kept.Title));
        Assert.Equal(("2", "Miks sõnade kaupa on kiirem"), (suggestion.Number, suggestion.Title));
        Assert.StartsWith("Clip 1, Iga sõna asukoht, ", kept.AccessibleName);
        Assert.StartsWith("Suggested clip 2, Miks sõnade kaupa on kiirem, ", suggestion.AccessibleName);
        Assert.EndsWith(" · Suggested", suggestion.Meta);
        // Design §3.4: the duration alone is set in Cascadia Mono; " · Suggested" is UI text.
        Assert.Equal((suggestion.MetaTime, " · Suggested"), (suggestion.Meta[..^" · Suggested".Length], suggestion.MetaStatus));
        Assert.Matches(@"^\d+:\d{2}$", kept.MetaTime);
        Assert.Equal(("", kept.MetaTime), (kept.MetaStatus, kept.Meta));
        Assert.Equal("Suggested", shell.Rows.Single(row => row.Kind == SidebarKind.SuggestedHeader).Title);
        Assert.Equal("Sõnade kaupa lõikamine", shell.Rows.Single(row => row.Kind == SidebarKind.Project).Title);
        Assert.Equal("voxclip-demo.mp4", shell.Rows.Single(row => row.Kind == SidebarKind.Project).Detail);
        Assert.Equal(["New clip from selection", "Find clips with AI"], shell.Rows.Where(row => row.Kind == SidebarKind.Action).Select(row => row.Title));
        Assert.Equal(["Ctrl+K", "Ctrl+Shift+K"], shell.Rows.Where(row => row.Kind == SidebarKind.Action).Select(row => row.Detail));
    }

    [Fact]
    public void FullTakeNamesItsEditedLength()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var full = shell.Rows.Single(row => row.Kind == SidebarKind.FullTake);
        Assert.Equal(EditorViewModel.Duration(editor.FullTakeDuration), full.Meta);
        Assert.Equal($"Full take, {ShellViewModel.Spoken(editor.FullTakeDuration)} after cuts", full.AccessibleName);
        Assert.InRange(editor.FullTakeDuration, 1, editor.Project.Media.Source.DurationSeconds);
    }

    [Theory]
    [InlineData(0, "0 seconds")]
    [InlineData(1, "1 second")]
    [InlineData(20.4, "20 seconds")]
    [InlineData(60, "1 minute")]
    [InlineData(130, "2 minutes 10 seconds")]
    [InlineData(61, "1 minute 1 second")]
    public void SpokenLengthsReadNaturally(double seconds, string expected) => Assert.Equal(expected, ShellViewModel.Spoken(seconds));

    [Fact]
    public void RowsKeepTheirInstancesAcrossRebuilds()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var before = shell.Rows.ToArray();
        var changes = 0;
        shell.Rows.CollectionChanged += (_, _) => changes++;
        shell.Update(editor, false, [], null);
        Assert.Equal(before, shell.Rows);
        Assert.Equal(0, changes);
        editor.Select(0); editor.Select(2, true);
        Assert.NotNull(editor.MakeClip());
        shell.Update(editor, false, [], null);
        Assert.Equal(1, changes);
        Assert.All(before, row => Assert.Contains(row, shell.Rows));
        var numbers = shell.Rows.Where(row => row.Kind is SidebarKind.Clip or SidebarKind.Suggestion).Select(row => row.Number);
        Assert.Equal(["1", "2", "3"], numbers);
    }

    [Fact]
    public void ScopeRowFollowsTheActiveClipAndFallsBackToFullTake()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        Assert.Equal(SidebarKind.FullTake, shell.ScopeRow(null)!.Kind);
        var suggestion = editor.Clips.Single(ShellViewModel.IsSuggestion);
        Assert.True(editor.Apply(new EditOperation.SetActiveClip(suggestion.Id)));
        shell.Update(editor, false, [], null);
        var active = shell.ScopeRow(editor.State!.ActiveClipId)!;
        Assert.Equal((SidebarKind.Suggestion, suggestion.Id, true), (active.Kind, active.ClipId, active.IsActive));
        Assert.All(shell.Rows.Where(row => row.ClipId is not null && row != active), row => Assert.False(row.IsActive));
        Assert.Equal(SidebarKind.FullTake, shell.ScopeRow("missing")!.Kind);
    }

    [Fact]
    public void HomeKeepsTheProjectSectionWithoutActionsAndListsOtherRecents()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        var recent = Enumerable.Range(0, 15).Select(index => new RecentProject($@"C:\Projects\take-{index}.voxclip", $"take-{index}")).ToArray();
        shell.Update(editor, true, recent, @"c:\projects\TAKE-0.voxclip");
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.Action);
        Assert.Contains(shell.Rows, row => row.Kind == SidebarKind.FullTake);
        var recents = shell.Rows.Where(row => row.Kind == SidebarKind.Recent).ToArray();
        Assert.Equal(ShellViewModel.RecentLimit, recents.Length);
        Assert.DoesNotContain(recents, row => row.Recent!.Path.EndsWith("take-0.voxclip", StringComparison.Ordinal));
        Assert.Equal("take-1", recents[0].Title);
        Assert.Equal(SidebarKind.RecentHeader, shell.Rows[shell.Rows.IndexOf(recents[0]) - 1].Kind);
        shell.Update(null, true, recent, null);
        Assert.Equal([SidebarKind.Home, SidebarKind.Separator, SidebarKind.RecentHeader], shell.Rows.Take(3).Select(row => row.Kind));
        Assert.Equal("take-0", shell.Rows.First(row => row.Kind == SidebarKind.Recent).Title);
    }

    [Fact]
    public void ActionsFollowSelectionAndTranscript()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        Assert.False(shell.Rows.Single(row => row.Key == "action:make").IsEnabled);
        Assert.True(shell.Rows.Single(row => row.Key == "action:find").IsEnabled);
        editor.Select(3);
        shell.Update(editor, false, [], null);
        Assert.True(shell.Rows.Single(row => row.Key == "action:make").IsEnabled);
        editor.Busy = true;
        shell.Update(editor, false, [], null);
        Assert.All(shell.Rows.Where(row => row.Kind == SidebarKind.Action), row => Assert.False(row.IsEnabled));
    }

    [Fact]
    public void EmptyRowSitsUnderFullTakeUntilThereIsAClip()
    {
        var editor = WithSuggestion();
        foreach (var clip in editor.Clips.ToArray()) Assert.True(editor.Remove(clip.Id));
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var empty = shell.Rows.Single(row => row.Kind == SidebarKind.Empty);
        Assert.Equal(SidebarKind.FullTake, shell.Rows[shell.Rows.IndexOf(empty) - 1].Kind);
        Assert.Equal("No clips yet. Select words and press Ctrl+K.", empty.Title);
        shell.Finding = "Claude Code · reading 2:10 of transcript";
        shell.Update(editor, false, [], null);
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.Empty);
        shell.Finding = null;
        editor.Select(0); editor.Select(2, true);
        Assert.NotNull(editor.MakeClip());
        shell.Update(editor, false, [], null);
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.Empty);
    }

    [Fact]
    public void FindingRowSitsUnderSuggestedWithItsConnectorLine()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel { Finding = "Claude Code · reading 2:10 of transcript" };
        shell.Update(editor, false, [], null);
        Assert.Equal([SidebarKind.SuggestedHeader, SidebarKind.Suggestion, SidebarKind.Finding, SidebarKind.Separator],
            shell.Rows.SkipWhile(row => row.Kind != SidebarKind.SuggestedHeader).Take(4).Select(row => row.Kind));
        var finding = shell.Rows.Single(row => row.Kind == SidebarKind.Finding);
        Assert.Equal(("Finding clips…", "Claude Code · reading 2:10 of transcript"), (finding.Title, finding.Detail));
        Assert.True(editor.Dismiss(editor.Clips.Single(ShellViewModel.IsSuggestion).Id));
        shell.Update(editor, false, [], null);
        Assert.Equal([SidebarKind.Clip, SidebarKind.SuggestedHeader, SidebarKind.Finding],
            shell.Rows.SkipWhile(row => row.Kind != SidebarKind.Clip).Take(3).Select(row => row.Kind));
        Assert.Equal("Suggested", shell.Rows.Single(row => row.Kind == SidebarKind.SuggestedHeader).Title);
        shell.Finding = null;
        shell.Update(editor, false, [], null);
        Assert.DoesNotContain(shell.Rows, row => row.Kind is SidebarKind.Finding or SidebarKind.SuggestedHeader);
    }

    [Fact]
    public void CalloutFollowsTheActionsOnlyInTheEditor()
    {
        var editor = WithSuggestion();
        var shell = new ShellViewModel { Callout = ClipCallouts.NoConnector };
        shell.Update(editor, false, [], null);
        var callout = shell.Rows[^1];
        Assert.Equal((SidebarKind.Callout, "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.",
            "You can also select words and press Ctrl+K to make a clip yourself.", "Set up AI…", true),
            (callout.Kind, callout.Title, callout.Detail, callout.Action, callout.HasAction));
        Assert.Equal(SidebarKind.Action, shell.Rows[^2].Kind);
        shell.Callout = ClipCallouts.NotReady(ConnectorId.Codex, "Codex (installed CLI)", new ConnectorStatus.CliMissing(), "Install Codex, then run codex login.", null);
        shell.Update(editor, false, [], null);
        Assert.Same(callout, shell.Rows[^1]);
        Assert.Equal(("", "Codex isn't installed. Install Codex, then run codex login. Your edits are saved.", false),
            (callout.Title, callout.Detail, callout.HasAction));
        shell.Update(editor, true, [], null);
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.Callout);
    }

    /// <summary>Find clips and its callout's Retry use the connector llm.connector names when they run (AI spec §11 gate 4):
    /// after Settings changes it they never reach the old one, and an empty or unknown setting is "Clips: no connector".</summary>
    [Fact]
    public void RetryUsesTheConnectorChosenNow()
    {
        string[] catalogue = ["anthropic", "ollama", "codex"];
        Assert.Equal("ollama", ClipCallouts.Chosen("ollama", catalogue, id => id));
        Assert.Equal("anthropic", ClipCallouts.Chosen("anthropic", catalogue, id => id));
        Assert.Null(ClipCallouts.Chosen("", catalogue, id => id));
        Assert.Null(ClipCallouts.Chosen("apple-foundation", catalogue, id => id));
        Assert.Equal(("Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.", "Set up AI…"),
            (ClipCallouts.NoConnector.Title, ClipCallouts.NoConnector.Action));
    }

    /// <summary>Design §13's callout rows and AI spec §5's messages, each ending "Your edits are saved." once (AI spec §5).</summary>
    [Fact]
    public void ClipCalloutsUseTheDesignCopy()
    {
        static (string, string) Read(SidebarCallout callout) => (callout.Message, callout.Action);
        Assert.Equal(("Claude Code isn't signed in. Open Terminal, run claude, and sign in. Your edits are saved.", "Sign-in help"),
            Read(ClipCallouts.NotReady(ConnectorId.ClaudeCode, "Claude Code (installed CLI)", new ConnectorStatus.CliSignedOut(), null, "Open Terminal, run claude, and sign in.")));
        Assert.Equal(("Ollama isn't running at http://127.0.0.1:11434. Start Ollama and try again. Your edits are saved.", ""),
            Read(ClipCallouts.NotReady(ConnectorId.Ollama, "Ollama", new ConnectorStatus.NotRunning("http://127.0.0.1:11434"), null, null)));
        Assert.Equal(("LM Studio's server isn't running at http://127.0.0.1:1234. Start it from LM Studio's Developer tab. Your edits are saved.", ""),
            Read(ClipCallouts.NotReady(ConnectorId.LmStudio, "LM Studio", new ConnectorStatus.NotRunning("http://127.0.0.1:1234"), null, null)));
        Assert.Equal(("Add your Anthropic API key in Settings › AI. Your edits are saved.", "Retry"),
            Read(ClipCallouts.NotReady(ConnectorId.Anthropic, "Anthropic", new ConnectorStatus.NeedsKey(), null, null)));
        Assert.Equal(("Ollama has no chat models. Run `ollama pull <model>`, then refresh. Your edits are saved.", "Retry"),
            Read(ClipCallouts.NotReady(ConnectorId.Ollama, "Ollama", new ConnectorStatus.NoModels(), null, null)));
        Assert.Equal(("Load or download a model in LM Studio, then refresh. Your edits are saved.", "Retry"),
            Read(ClipCallouts.NotReady(ConnectorId.LmStudio, "LM Studio", new ConnectorStatus.NoModels(), null, null)));
        Assert.Equal(("Your Codex 0.9.1 is too old for VoxClip. Update it, then try again. Your edits are saved.", "Retry"),
            Read(ClipCallouts.NotReady(ConnectorId.Codex, "Codex (installed CLI)", new ConnectorStatus.CliTooOld("0.9.1", ["--json"]), null, null)));
        Assert.Equal(("Your Claude Code is too old for VoxClip. Update it, then try again. Your edits are saved.", "Retry"),
            Read(ClipCallouts.NotReady(ConnectorId.ClaudeCode, "Claude Code (installed CLI)", new ConnectorStatus.CliTooOld("unknown", []), null, null)));
        Assert.Equal(("The model returned clips VoxClip can't use. Try again. Your edits are saved.", "Retry"),
            Read(ClipCallouts.Failed("The model returned clips VoxClip can't use. Try again. Your edits are saved.")));
        Assert.Equal(("You're offline. Your edits are saved.", "Retry"), Read(ClipCallouts.Failed("You're offline.")));
    }

    /// <summary>Design §7.1: without a transcript the Full take reads "Not transcribed" and the actions explain why they're off.</summary>
    [Fact]
    public void UntranscribedTakeSaysSoAndExplainsTheActions()
    {
        var project = Fixture("clip-from-long-take.voxclip");
        var editor = new EditorViewModel(project with
        {
            Transcript = null, Edits = project.Edits with { Clips = [], CutWordIds = [], CutPauseIds = [], ActiveClipId = null }, Ai = project.Ai with { Results = [] }
        });
        Assert.False(editor.HasTranscript);
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var full = shell.Rows.Single(row => row.Kind == SidebarKind.FullTake);
        Assert.Equal(("", "Not transcribed", "Not transcribed", "Full take, not transcribed", false),
            (full.MetaTime, full.MetaStatus, full.Meta, full.AccessibleName, full.ShowsCancel));
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.Empty);
        var actions = shell.Rows.Where(row => row.Kind == SidebarKind.Action).ToArray();
        Assert.Equal(2, actions.Length);
        Assert.All(actions, row => Assert.Equal((false, "Transcribe the video to select words."), (row.IsEnabled, row.ToolTip)));

        shell.TakeMedia = new MediaTile("take", null, null, new MediaStatus.Transcribing(0.42, MediaTranscriptionStage.Transcribing));
        shell.Update(editor, false, [], null);
        Assert.Equal(("", "Transcribing · 42%", true, "Cancel transcribing Sõnade kaupa lõikamine", "Full take, transcribing 42 percent"),
            (full.MetaTime, full.MetaStatus, full.ShowsCancel, full.CancelName, full.AccessibleName));
    }

    /// <summary>Design §13 "Clips: none found": the prompt file's message under Suggested, until the next run.</summary>
    [Fact]
    public void NoneFoundSitsUnderSuggested()
    {
        var editor = WithSuggestion();
        Assert.True(editor.Dismiss(editor.Clips.Single(ShellViewModel.IsSuggestion).Id));
        var shell = new ShellViewModel { NoneFound = "No clips matched. Try another style or describe what you want." };
        shell.Update(editor, false, [], null);
        Assert.Equal([SidebarKind.Clip, SidebarKind.SuggestedHeader, SidebarKind.NoneFound, SidebarKind.Separator],
            shell.Rows.SkipWhile(row => row.Kind != SidebarKind.Clip).Take(4).Select(row => row.Kind));
        var none = shell.Rows.Single(row => row.Kind == SidebarKind.NoneFound);
        Assert.Equal(("No clips matched. Try another style or describe what you want.", "No clips matched. Try another style or describe what you want."),
            (none.Title, none.AccessibleName));
        Assert.Equal("Suggested", shell.Rows.Single(row => row.Kind == SidebarKind.SuggestedHeader).Title);
        // A new run replaces it with the Finding row; a run that finds clips clears it.
        shell.Finding = "Claude Code · reading 2:10 of transcript";
        shell.Update(editor, false, [], null);
        Assert.DoesNotContain(shell.Rows, row => row.Kind == SidebarKind.NoneFound);
        shell.Finding = null;
        shell.NoneFound = null;
        shell.Update(editor, false, [], null);
        Assert.DoesNotContain(shell.Rows, row => row.Kind is SidebarKind.NoneFound or SidebarKind.SuggestedHeader);
    }

    [Fact]
    public void SuggestedHeaderCountsFromTwoAndOffersKeepAll()
    {
        var project = Fixture("clip-from-long-take.voxclip");
        var editor = new EditorViewModel(project with { Edits = project.Edits with { Clips = [], ActiveClipId = null } });
        var words = editor.Words;
        editor.AddAiResult(new("run-1", DateTimeOffset.UtcNow, "anthropic", "test-model", ClipPreset.Best, null, "et", new string('0', 64),
            [new("One", "Strong hook", 8, words[0].Id, words[3].Id), new("Two", "", 6, words[5].Id, words[8].Id)]));
        var shell = new ShellViewModel();
        shell.Update(editor, false, [], null);
        var header = shell.Rows.Single(row => row.Kind == SidebarKind.SuggestedHeader);
        Assert.Equal(("Suggested (2)", true), (header.Title, header.ShowsKeepAll));
        var suggestions = shell.Rows.Where(row => row.Kind == SidebarKind.Suggestion).ToArray();
        Assert.Equal(("8/10 · Strong hook", "6/10"), (suggestions[0].ToolTip, suggestions[1].ToolTip));
        Assert.Equal(("Keep suggested clip 1", "Dismiss suggested clip 1"), (suggestions[0].KeepName, suggestions[0].DismissName));
        Assert.True(editor.Keep(suggestions[0].ClipId!));
        shell.Update(editor, false, [], null);
        Assert.Equal(("Suggested", false), (header.Title, header.ShowsKeepAll));
        Assert.Equal(("Keep suggested clip 2", "2"), (suggestions[1].KeepName, suggestions[1].Number));
        Assert.True(editor.KeepAll());
        shell.Update(editor, false, [], null);
        Assert.DoesNotContain(shell.Rows, row => row.Kind is SidebarKind.SuggestedHeader or SidebarKind.Suggestion);
    }

    [Fact]
    public void ClipRowsTakeTheirTilesById()
    {
        var editor = WithSuggestion();
        var suggestion = editor.Clips.Single(ShellViewModel.IsSuggestion);
        var tile = new MediaTile("take|" + suggestion.Id, null, null, new MediaStatus.None());
        var shell = new ShellViewModel { ClipMedia = new Dictionary<string, MediaTile> { [suggestion.Id] = tile } };
        shell.Update(editor, false, [], null);
        Assert.Same(tile, shell.Rows.Single(row => row.Kind == SidebarKind.Suggestion).Media);
        Assert.Null(shell.Rows.Single(row => row.Kind == SidebarKind.Clip).Media);
    }
}
#endif
