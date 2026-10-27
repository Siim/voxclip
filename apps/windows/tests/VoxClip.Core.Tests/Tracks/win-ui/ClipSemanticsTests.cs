#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

/// <summary>Clip semantics for the clips-first pane (ADR-R29): numbering, suggestions, one-step AI results and the summary
/// line; design §2, §3.5 and §6.2. The core reducer is unchanged.</summary>
public sealed class ClipSemanticsTests
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

    /// <summary>The long take with no clips, no cuts and no earlier clip-finding runs.</summary>
    private static EditorViewModel Clean()
    {
        var project = Fixture("clip-from-long-take.voxclip");
        return new EditorViewModel(project with { Edits = project.Edits with { Clips = [], CutWordIds = [], CutPauseIds = [], ActiveClipId = null }, Ai = project.Ai with { Results = [] } });
    }

    private static string Clip(EditorViewModel model, int first, int last)
    {
        model.Select(first); model.Select(last, true);
        return model.MakeClip()!;
    }

    private static AiResult Result(EditorViewModel model, params (int First, int Last)[] ranges) => new("run-1", DateTimeOffset.UtcNow, "anthropic", "test-model",
        ClipPreset.Best, null, "en", new string('0', 64),
        ranges.Select((range, index) => new AiClip($"Idea {index + 1}", $"Reason {index + 1}", 8 - index, model.Words[range.First].Id, model.Words[range.Last].Id)).ToArray());

    [Fact]
    public void FindClipsAddsSuggestionsAsOneUndoStep()
    {
        var model = Clean();
        var added = model.AddAiResult(Result(model, (0, 3), (5, 8), (10, 14)));
        Assert.Equal(model.SuggestedClips.Select(clip => clip.Id), added);
        Assert.Equal(3, model.SuggestedClips.Count);
        Assert.Empty(model.KeptClips);
        Assert.All(model.Clips, clip => Assert.True(clip.IsSuggested && !clip.Selected));
        Assert.Single(model.Project.Ai.Results);
        Assert.Equal("8/10 · Reason 1", model.Clips[0].ToolTip);

        model.Undo();
        Assert.Empty(model.Clips);
        Assert.False(model.CanUndo);

        model.Redo();
        Assert.Equal(3, model.SuggestedClips.Count);
        Assert.True(model.KeepAll());
        Assert.Equal(3, model.KeptClips.Count);
        Assert.Empty(model.SuggestedClips);
        model.Undo();
        Assert.Equal(3, model.SuggestedClips.Count);
    }

    [Fact]
    public void KeptClipsAreNumberedBeforeSuggestions()
    {
        var model = Clean();
        var late = Clip(model, 20, 22);
        Clip(model, 0, 2);
        Clip(model, 4, 6);
        Clip(model, 12, 14);
        model.AddAiResult(Result(model, (8, 10)));
        Assert.Equal([1, 2, 3, 4, 5], model.Clips.Select(clip => clip.Number));
        Assert.Equal(late, model.KeptClips[3].Id);
        var suggestion = Assert.Single(model.SuggestedClips);
        Assert.Equal(5, suggestion.Number);
        Assert.Equal("Idea 1", suggestion.Title);

        Assert.True(model.Keep(suggestion.Id));
        Assert.Equal(3, model.Clips.Single(clip => clip.Id == suggestion.Id).Number);
        Assert.True(model.Rename(suggestion.Id, "  Third idea "));
        Assert.Equal("Third idea", model.Clips.Single(clip => clip.Id == suggestion.Id).Title);
        Assert.True(model.Remove(late));
        Assert.Equal(4, model.Clips.Count);
    }

    /// <summary>Export's "Selected clips" exports the kept clips (ADR-R29): every manual clip, whatever its stored selected
    /// flag, and the AI clips the user kept, never a suggestion.</summary>
    [Fact]
    public void ExportedClipsAreTheKeptClipsWithEveryManualClip()
    {
        var model = Clean();
        var manual = Clip(model, 20, 24);
        Assert.True(model.Apply(new EditOperation.SetClipSelected(manual, false)));
        var suggestions = model.AddAiResult(Result(model, (0, 3), (5, 8)));
        Assert.True(model.Apply(new EditOperation.SetClipSelected(suggestions[1], true)));
        Assert.Equal([suggestions[1], manual], model.KeptClips.Select(clip => clip.Id));
        Assert.Equal([suggestions[0]], model.SuggestedClips.Select(clip => clip.Id));
        Assert.False(model.Clips.Single(clip => clip.Id == manual).Selected);
    }

    /// <summary>Design §6.2: from the Full take row, ] selects clip 1; the window cycles by the row's step.</summary>
    [Fact]
    public void RightBracketFromFullTakeSelectsClipOne()
    {
        var model = Clean();
        var first = Clip(model, 0, 3);
        Clip(model, 10, 14);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        Assert.Equal(1, ShortcutPolicy.RowClipStep(']', SidebarKind.FullTake, false));
        model.CycleClip(ShortcutPolicy.RowClipStep(']', SidebarKind.FullTake, false));
        Assert.Equal(first, model.State!.ActiveClipId);
    }

    /// <summary>Rename takes at most 120 code points once trimmed; the dialog explains a longer title instead of the reducer
    /// dropping it.</summary>
    [Fact]
    public void RenameExplainsATitleOverTheLimit()
    {
        var model = Clean();
        var id = Clip(model, 0, 3);
        var longest = string.Concat(Enumerable.Repeat("👩🏽‍💻", 30));
        Assert.Equal(120, longest.EnumerateRunes().Count());
        Assert.True(longest.Length > 120);
        Assert.Null(EditorViewModel.ClipTitleProblem(longest));
        Assert.Null(EditorViewModel.ClipTitleProblem("  " + new string('a', 120) + "  "));
        Assert.Null(EditorViewModel.ClipTitleProblem(""));
        Assert.Equal("Use 120 characters or fewer.", EditorViewModel.ClipTitleProblem(new string('a', 121)));
        Assert.Equal("Use 120 characters or fewer.", EditorViewModel.ClipTitleProblem(longest + "!"));
        Assert.True(model.Rename(id, longest));
        Assert.Equal(longest, model.Project.Edits.Clips.Single(clip => clip.Id == id).Title);
        // What the dialog refuses, the reducer would have dropped without a word.
        Assert.False(model.Rename(id, new string('a', 121)));
        Assert.Equal(longest, model.Project.Edits.Clips.Single(clip => clip.Id == id).Title);
    }

    /// <summary>A clip row's Export clip… is judged on its own clip, not on the active scope: a clip with kept words exports
    /// while another clip with every word cut is active, and a clip with every word cut is refused from Full take.</summary>
    [Fact]
    public void ExportIsJudgedOnTheRequestedClip()
    {
        var model = Clean();
        var first = Clip(model, 0, 3);
        var second = Clip(model, 10, 14);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(first)));
        model.Select(0); model.Select(3, true);
        model.CutSelection(false);
        const string NoWords = "Keep at least one word before exporting.";
        Assert.Equal(NoWords, model.ExportBlocked(false, false, first));
        Assert.Null(model.ExportBlocked(false, false, second));
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        Assert.Equal(NoWords, model.ExportBlocked(false, false, first));
        Assert.Null(model.ExportBlocked(false, false, second));
        Assert.Null(model.ExportBlocked(false, false, null));
    }

    /// <summary>Ctrl+E, the Export button and a clip row's Export clip… share one reason (delta §3.5).</summary>
    [Fact]
    public void ExportSaysWhyItCannotRunForTheScope()
    {
        var model = Clean();
        Assert.Null(model.ExportBlocked(false, false, null));
        var suggestion = model.AddAiResult(Result(model, (0, 3)))[0];
        Assert.Equal("Keep this clip to export it.", model.ExportBlocked(false, false, suggestion));
        Assert.Equal("Open the project and find the video to export.", model.ExportBlocked(false, true, suggestion));
        Assert.Equal("Demo projects have no video to export.", model.ExportBlocked(true, true, null));
        model.Busy = true;
        Assert.Equal("Finish the current task first.", model.ExportBlocked(false, false, null));
        model.Busy = false;
        model.Select(0); model.Select(model.Words.Count - 1, true);
        model.CutSelection(false);
        Assert.Equal("Keep at least one word before exporting.", model.ExportBlocked(false, false, null));
    }

    [Fact]
    public void DismissRemovesOnlyTheSuggestion()
    {
        var model = Clean();
        var kept = Clip(model, 0, 2);
        model.AddAiResult(Result(model, (5, 8), (10, 14)));
        var dismissed = model.SuggestedClips[0].Id;
        Assert.True(model.Dismiss(dismissed));
        Assert.DoesNotContain(model.Clips, clip => clip.Id == dismissed);
        Assert.Equal(kept, Assert.Single(model.KeptClips).Id);
        Assert.Single(model.SuggestedClips);
        Assert.Single(model.Project.Ai.Results);
    }

    [Fact]
    public void MakeClipReturnsTheClipThatAlreadyCoversTheSelection()
    {
        var model = Clean();
        var first = Clip(model, 4, 9);
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        model.Notice = "stale";
        model.Select(4); model.Select(9, true);
        Assert.Equal(first, model.MakeClip());
        Assert.Single(model.Clips);
        Assert.Equal("", model.Notice);
        Assert.Equal(["Clip 1 already covers these words."], announced);
    }

    /// <summary>Delta §6.2: making a clip is one addClip undo step that selects it, so revealing its row (MainWindow.RevealClip
    /// → EditorPage.SelectScope, which applies setActiveClip) adds no second step and Narrator hears "Clip 1 made.".</summary>
    [Fact]
    public void MakeClipIsOneUndoStepAndRevealingItAddsNone()
    {
        var model = Clean();
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        var id = Clip(model, 4, 9);
        Assert.Equal(id, model.State!.ActiveClipId);
        Assert.False(model.Apply(new EditOperation.SetActiveClip(id)));
        Assert.Equal(["Clip 1 made."], announced);
        model.Undo();
        Assert.Empty(model.Clips);
        Assert.Null(model.State!.ActiveClipId);
        Assert.False(model.CanUndo);
    }

    [Fact]
    public void MakingAnExistingClipSelectsItAndSaysSoOnce()
    {
        var model = Clean();
        var first = Clip(model, 0, 2);
        var second = Clip(model, 4, 6);
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        model.Select(0); model.Select(2, true);
        Assert.Equal(first, model.MakeClip());
        Assert.Equal(first, model.State!.ActiveClipId);
        // Revealing the row changes nothing more, and the edit summary never replaces the message.
        Assert.False(model.Apply(new EditOperation.SetActiveClip(first)));
        Assert.Equal(["Clip 1 already covers these words."], announced);
        model.Undo();
        Assert.Equal((second, 2), (model.State!.ActiveClipId, model.Clips.Count));
    }

    /// <summary>Design §6.2: a manual clip is titled with the first seven words of the selection, as shown.</summary>
    [Fact]
    public void ManualClipsTakeTheFirstSevenWordsAsTheirTitle()
    {
        var model = Clean();
        var whole = Clip(model, 0, 9);
        Assert.Equal("Tere! Täna näitan, kuidas lõigata videot sõnade", model.Clips.Single(clip => clip.Id == whole).Title);
        model.Select(2);
        model.Correct("näitasin,");
        var corrected = Clip(model, 1, 3);
        Assert.Equal("Täna näitasin, kuidas", model.Clips.Single(clip => clip.Id == corrected).Title);
        Assert.Equal("Täna näitasin, kuidas", model.Project.Edits.Clips.Single(clip => clip.Id == corrected).Title);
    }

    [Fact]
    public void RemovingAnEarlierClipKeepsALaterClipsTitle()
    {
        var model = Clean();
        var early = Clip(model, 0, 2);
        var later = Clip(model, 12, 20);
        Assert.Equal(("Tere! Täna näitan,", 1), (model.Clips.Single(clip => clip.Id == early).Title, model.Clips.Single(clip => clip.Id == early).Number));
        Assert.True(model.Remove(early));
        var row = model.Clips.Single(clip => clip.Id == later);
        Assert.Equal(("palju kiirem kui ajateljel kerimine. Iga sõna", 1), (row.Title, row.Number));
    }

    [Fact]
    public void ClipCommandsAnnounceWhatTheyDid()
    {
        var model = Clean();
        var announced = new List<string>();
        model.Announcement += (_, text) => announced.Add(text);
        var first = Clip(model, 0, 2);
        model.AddAiResult(Result(model, (5, 8), (10, 14)));
        Assert.True(model.Keep(model.SuggestedClips[0].Id));
        Assert.True(model.Dismiss(model.SuggestedClips[0].Id));
        Assert.True(model.Remove(first));
        Assert.True(model.Rename(model.KeptClips[0].Id, "Renamed"));
        Assert.Equal(["Clip 1 made.", "Clip 2 kept.", "Suggestion dismissed.", "Clip 1 removed."], announced);
    }

    [Fact]
    public void CycleClipWalksKeptClipsOnly()
    {
        var model = Clean();
        var one = Clip(model, 0, 2);
        var two = Clip(model, 12, 14);
        model.AddAiResult(Result(model, (5, 8)));
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        model.CycleClip(1);
        Assert.Equal(one, model.State!.ActiveClipId);
        model.CycleClip(1);
        Assert.Equal(two, model.State!.ActiveClipId);
        model.CycleClip(1);
        Assert.Equal(two, model.State!.ActiveClipId);
        model.CycleClip(-1);
        Assert.Equal(one, model.State!.ActiveClipId);
    }

    [Fact]
    public void SummaryLineCountsCutRunsAndPausesInScope()
    {
        var model = Clean();
        // The length export renders for a scope, worked out without the view model: ExportSelection's frozen state, then
        // the edit plan.
        double Planned(ExportTarget target)
        {
            var state = ExportSelection.Scope(model.State, target)!;
            var source = model.Project.Media.Source;
            var sampleRate = source.Audio?.SampleRate is > 0 ? source.Audio.SampleRate : 48000;
            return EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, source.DurationSeconds), source.DurationSeconds, sampleRate, state.PauseKeepSeconds).Duration;
        }
        Assert.Equal("0:16 · No cuts yet", model.SummaryLine);
        Assert.Equal(Planned(new ExportTarget.FullEdit()), model.FullTakeDuration, 9);

        // The long take has pauses after words 16 and 22; clip A spans 12–20 and clip B 21–25.
        var a = Clip(model, 12, 20);
        var b = Clip(model, 21, 25);
        string[] Words(params int[] indexes) => indexes.Select(index => model.Words[index].Id).ToArray();
        // Making a clip makes it the scope (design §6.2); go back to Full take.
        Assert.Equal(b, model.State!.ActiveClipId);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        // Three cut runs: words 2–3, 14 and 18–19.
        Assert.True(model.Apply(new EditOperation.SetWordCuts(Words(2, 3, 14, 18, 19), true)));
        Assert.Equal("0:14 after cuts · 3 cuts", model.SummaryLine);
        Assert.Equal("0:16 source · 5 words cut in 3 places · 0 pauses cut", model.SummaryTooltip);
        Assert.Equal(Planned(new ExportTarget.FullEdit()), model.FullTakeDuration, 9);

        // Clip A holds the runs at 14 and 18–19; clip B holds none until its pause is cut.
        Assert.True(model.Apply(new EditOperation.SetActiveClip(a)));
        Assert.Equal("Clip 1 · 0:04 after cuts · 2 cuts", model.SummaryLine);
        Assert.Equal(EditorViewModel.Duration(Planned(new ExportTarget.Clip(a))), model.Clips.Single(clip => clip.Id == a).Duration);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(b)));
        Assert.Equal("Clip 2 · 0:04 · No cuts yet", model.SummaryLine);

        var pause = model.State!.Pauses.Single(item => item.AfterIndex == 22).Id;
        Assert.True(model.Apply(new EditOperation.SetPauseCuts([pause], true)));
        Assert.Equal("Clip 2 · 0:03 after cuts · 1 cut", model.SummaryLine);
        Assert.Equal(EditorViewModel.Duration(Planned(new ExportTarget.Clip(b))), model.Clips.Single(clip => clip.Id == b).Duration);
        Assert.True(model.Apply(new EditOperation.SetActiveClip(null)));
        Assert.Equal("0:13 after cuts · 4 cuts", model.SummaryLine);
        Assert.Equal("0:16 source · 5 words cut in 3 places · 1 pause cut", model.SummaryTooltip);
        // A clip in scope never changes the Full take length.
        Assert.Equal(Planned(new ExportTarget.FullEdit()), model.FullTakeDuration, 9);
    }
}
#endif
