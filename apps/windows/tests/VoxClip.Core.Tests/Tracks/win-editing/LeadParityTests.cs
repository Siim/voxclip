using System.Text.Json;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinEditing.EditingFixtureTests;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

[CollectionDefinition("EditingPerformance", DisableParallelization = true)]
public sealed class EditingPerformanceCollection;

public sealed class LeadParityTests
{
    [Theory]
    [InlineData(0, 3)]
    [InlineData(0, 2)]
    [InlineData(1, 3)]
    [InlineData(1, 2)]
    public void SingleKeptRangeHasEveryRequiredEdgeJoin(int start, int end)
    {
        var plan = EditingEngine.BuildEditPlan([new("head", EditSegmentKind.Range, null, null, 0, start, true),
            new("tail", EditSegmentKind.Range, null, null, end, 3, true)], 3, 48000);
        Assert.Single(plan.Kept);
        Assert.Equal((start > 0 ? 1 : 0) + (end < 3 ? 1 : 0), plan.Joins.Count);
        if (start > 0) Assert.Equal(new Join(0, 0, 240), plan.Joins[0]);
        if (end < 3) Assert.Equal(new Join(plan.OutputSamples, 240, 0), plan.Joins[^1]);
        for (long sample = -1; sample <= plan.OutputSamples; sample++) Assert.Equal(GainFromJoins(plan, sample), plan.JoinGain(sample));
    }

    [Fact]
    public void OneSampleClipOmitsZeroLengthEdgeJoins()
    {
        var plan = EditingEngine.BuildEditPlan([new("head", EditSegmentKind.Range, null, null, 0, 1, true),
            new("tail", EditSegmentKind.Range, null, null, 2, 3, true)], 3, 1);
        Assert.Empty(plan.Joins);
        Assert.Equal(1, plan.JoinGain(0));
    }

    [Fact]
    public void GainTableIsRebuiltForRecordCopiesWithoutMutatingOriginal()
    {
        var original = EditingEngine.BuildEditPlan([], 3, 48000);
        var clipped = original with { Kept = [new(48000, 96000)] };
        var slower = clipped with { SampleRate = 24000 };
        Assert.Equal(48000, clipped.OutputSamples);
        Assert.Equal(1, clipped.Duration);
        Assert.Equal([new Join(0, 0, 240), new Join(48000, 240, 0)], clipped.Joins);
        Assert.Equal([new Join(0, 0, 120), new Join(48000, 120, 0)], slower.Joins);
        Assert.Equal(1, original.JoinGain(0));
        Assert.Equal(0, clipped.JoinGain(0));
        Assert.Equal(0.5f, clipped.JoinGain(120));
        Assert.Equal(1, slower.JoinGain(120));
        Assert.Equal(0.5f, clipped.JoinGain(120));
    }

    [Fact]
    public void ConstructorAndRecordCopiesNormalizeStaleDerivedPlanValues()
    {
        var plan = new EditPlan(1000, 20, [new(0, 5), new(15, 20)], [new(5, 15)], 999, []);
        Assert.Equal(10, plan.OutputSamples);
        Assert.Equal([new Join(0, 0, 5), new Join(10, 5, 0)], plan.Joins);
        var copy = plan with { OutputSamples = 999, Joins = [new(500, 1, 1)] };
        Assert.Equal(plan.OutputSamples, copy.OutputSamples);
        Assert.Equal(plan.Joins, copy.Joins);
        var shortened = copy with { TotalSamples = 15 };
        Assert.Equal([new Join(0, 0, 5)], shortened.Joins);
        var single = shortened with { Kept = [new(5, 6)], OutputSamples = 999, Joins = [new(0, 4, 4)] };
        Assert.Equal(1, single.OutputSamples);
        Assert.Empty(single.Joins);
        Assert.Equal(1, single.JoinGain(0));
        Assert.Equal(0.005, single.SourceTime(0));
        var derivedFirst = plan with { OutputSamples = 999, Joins = [new(500, 1, 1)], Kept = [new(5, 6)] };
        Assert.Equal(single.OutputSamples, derivedFirst.OutputSamples);
        Assert.Equal(single.Joins, derivedFirst.Joins);
        Assert.Equal(1, derivedFirst.JoinGain(0));
        Assert.Equal(plan.Joins, copy.Joins);
    }

    [Fact]
    public void DecodingNormalizesStaleDerivedPlanValues()
    {
        var plan = JsonSerializer.Deserialize("""
            {"sampleRate":1000,"totalSamples":20,"cuts":[{"startSample":0,"endSample":5},{"startSample":15,"endSample":20}],
             "kept":[{"startSample":5,"endSample":15}],"outputSamples":999,"joins":[{"outSample":500,"fadeOutLen":1,"fadeInLen":1}]}
            """, ProjectJsonContext.Default.EditPlan)!;
        Assert.Equal(10, plan.OutputSamples);
        Assert.Equal([new Join(0, 0, 5), new Join(10, 5, 0)], plan.Joins);
        Assert.Equal(0, plan.JoinGain(0));
        Assert.Equal(GainFromJoins(plan, 5), plan.JoinGain(5));
    }

    [Fact]
    public void ReducerLimitsCountNormalizedUnicodeCodePointsNotUtf16Units()
    {
        var state = State([Word("a", "original", 0, 1)]);
        var correction = string.Concat(Enumerable.Repeat("😀", EditingLimits.MaxCorrectionCodePoints));
        var corrected = EditingEngine.Reduce(state, new EditOperation.Correct("a", correction));
        Assert.Equal(correction, corrected.Corrections["a"]);
        Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.Correct("a", correction + "a")));
        var normalized = EditingEngine.Reduce(state, new EditOperation.Correct("a", string.Concat(Enumerable.Repeat("o\u0303", 200))));
        Assert.Equal(new string('õ', 200), normalized.Corrections["a"]);
        var title = string.Concat(Enumerable.Repeat("😀", EditingLimits.MaxClipTitleCodePoints));
        var added = EditingEngine.Reduce(state, new EditOperation.AddClip(new("clip", "a", "a", title, ClipOrigin.Manual, null, null, false)));
        Assert.Equal(title, added.Clips[0].Title);
        Assert.Same(added, EditingEngine.Reduce(added, new EditOperation.RenameClip("clip", title + "a")));
        Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.AddClip(added.Clips[0] with { Title = title + "a" })));
        Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.AddAiClips("result", [new AiClip(title + "a", "", 8, "a", "a")])));
        Assert.Empty(state.Corrections);
        Assert.Empty(state.Clips);
    }

    [Theory]
    [InlineData("")]
    [InlineData("-clip")]
    [InlineData("clip id")]
    [InlineData("clip\n")]
    [InlineData("😀")]
    [InlineData("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklm")]
    public void ReducerRejectsNonPersistableClipAndResultIds(string id)
    {
        var state = State([Word("a", "word", 0, 1)]);
        Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.AddClip(new(id, "a", "a", null, ClipOrigin.Manual, null, null, true))));
        Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.AddAiClips(id, [])));
    }

    [Fact]
    public void MaximumLengthResultIdsProduceSchemaSafeUniqueClipIds()
    {
        var state = State([Word("a", "first", 0, 1), Word("b", "second", 1, 2)]);
        var resultId = new string('a', EditingLimits.MaxIdLength);
        state = EditingEngine.Reduce(state, new EditOperation.AddAiClips(resultId, [new AiClip("first", "", 8, "a", "a"), new AiClip("second", "", 8, "b", "b")]));
        Assert.Equal(2, state.Clips.Select(clip => clip.Id).Distinct().Count());
        Assert.All(state.Clips, clip => Assert.Matches("\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\\z", clip.Id));
    }

    [Theory]
    [InlineData(false, 1.0)]
    [InlineData(true, 0.8)]
    public void TranscriptReplacementKeepsBreathButClearsTranscriptDependentState(bool refined, double threshold)
    {
        var project = TestStorage.ProjectFixture();
        var transcript = project.Transcript! with { Words = [Word("new1", "new", 0, 1), Word("new2", "words", 3, 4)], Refined = refined };
        var oldState = State(project.Transcript.Words) with { PauseKeepSeconds = 0.42, CutWordIds = project.Edits.CutWordIds.ToHashSet(),
            CutPauseIds = project.Edits.CutPauseIds.ToHashSet(), Corrections = project.Edits.Corrections, Clips = project.Edits.Clips, ActiveClipId = project.Edits.ActiveClipId };
        var state = EditingEngine.Reduce(oldState, new EditOperation.ReplaceTranscript(transcript));
        var replaced = ProjectStore.ReplaceTranscript(project with { Edits = project.Edits with { PauseKeepSeconds = 0.42 } }, transcript);
        Assert.Same(transcript, state.Transcript);
        Assert.Same(transcript, replaced.Transcript);
        Assert.Equal(0.42, state.PauseKeepSeconds);
        Assert.Equal(0.42, replaced.Edits.PauseKeepSeconds);
        Assert.Equal(threshold, state.PauseThresholdSeconds);
        Assert.Equal(threshold, replaced.Edits.PauseThresholdSeconds);
        Assert.Single(state.Pauses);
        Assert.Empty(state.CutWordIds);
        Assert.Empty(state.CutPauseIds);
        Assert.Empty(state.Corrections);
        Assert.Empty(state.Clips);
        Assert.Null(state.ActiveClipId);
        Assert.Empty(replaced.Edits.CutWordIds);
        Assert.Empty(replaced.Edits.CutPauseIds);
        Assert.Empty(replaced.Edits.Corrections);
        Assert.Empty(replaced.Edits.Clips);
        Assert.Null(replaced.Edits.ActiveClipId);
        Assert.Empty(replaced.Ai.Results);
        Assert.Empty(replaced.Share.Captions);
        Assert.Equal(project.Captions, replaced.Captions);
        Assert.Equal(project.Export, replaced.Export);
        Assert.Equal(project.Media, replaced.Media);
    }

    [Theory]
    [InlineData(1e21, "1e+21")]
    [InlineData(1.2345678901234568e21, "1.2345678901234568e+21")]
    [InlineData(double.MaxValue, "1.7976931348623157e+308")]
    [InlineData(1e20, "100000000000000000000.0")]
    public void ToFixedUsesJavaScriptExponentFormAtOneSextillion(double value, string expected)
        => Assert.Equal(expected, EditingFormat.ToFixed1(value));

    [Theory]
    [InlineData("http://github.com/owner/repo")]
    [InlineData("https://example.com/")]
    [InlineData("https://github.com.evil.example/")]
    [InlineData("https://github.com@evil.example/")]
    [InlineData("https://github.com/\\evil.example/")]
    public async Task UpdateUrlsCannotLeaveHttpsGitHub(string value)
    {
        using var storage = new TestStorage();
        var store = new SettingsStore(storage.PathFor("settings.json"));
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(value));
        settings.Values["update.htmlURL"] = document.RootElement.Clone();
        await Assert.ThrowsAsync<JsonException>(() => store.SaveAsync(settings, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("https://github.com/")]
    [InlineData("https://github.com/voxconvo/voxclip/releases/tag/v0.1.0")]
    public async Task UpdateUrlsAcceptHttpsGitHub(string value)
    {
        using var storage = new TestStorage();
        var store = new SettingsStore(storage.PathFor("settings.json"));
        var settings = await store.LoadAsync(TestContext.Current.CancellationToken);
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(value));
        settings.Values["update.htmlURL"] = document.RootElement.Clone();
        await store.SaveAsync(settings, TestContext.Current.CancellationToken);
        await store.FlushAsync(TestContext.Current.CancellationToken);
        Assert.Equal(value, (await store.LoadAsync(TestContext.Current.CancellationToken)).Values["update.htmlURL"].GetString());
    }

    internal static double GainFromJoins(EditPlan plan, long sample)
    {
        if (sample < 0 || sample >= plan.OutputSamples) return 1;
        var lower = 0;
        var upper = plan.Joins.Count;
        while (lower < upper)
        {
            var middle = lower + (upper - lower) / 2;
            if (plan.Joins[middle].OutSample <= sample) lower = middle + 1;
            else upper = middle;
        }
        var gain = 1.0;
        if (lower > 0 && sample - plan.Joins[lower - 1].OutSample < plan.Joins[lower - 1].FadeInLen)
            gain = gain * (sample - plan.Joins[lower - 1].OutSample) / plan.Joins[lower - 1].FadeInLen;
        if (lower < plan.Joins.Count && plan.Joins[lower].OutSample - 1 - sample < plan.Joins[lower].FadeOutLen)
            gain = gain * (plan.Joins[lower].OutSample - 1 - sample) / plan.Joins[lower].FadeOutLen;
        return (float)gain;
    }
}
