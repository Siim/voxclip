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
        // Making a clip leaves the scope on Full take.
        Assert.Null(model.State!.ActiveClipId);
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
