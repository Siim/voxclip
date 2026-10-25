using System.Globalization;
using System.Diagnostics;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinEditing.EditingFixtureTests;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

[Collection("EditingPerformance")]
public sealed class EditingInvariantTests
{
    [Theory]
    [InlineData(1000)]
    [InlineData(16000)]
    [InlineData(44100)]
    [InlineData(48000)]
    public void RandomPlansPreserveSampleGridInvariants(int rate)
    {
        var random = new Random(638 + rate);
        for (var iteration = 0; iteration < 75; iteration++)
        {
            var duration = 1 + random.NextDouble() * 12;
            var segments = Enumerable.Range(0, 30).Select(index =>
            {
                var start = random.NextDouble() * (duration + 2) - 1;
                var kind = (EditSegmentKind)random.Next(3);
                return new EditSegment(index.ToString(CultureInfo.InvariantCulture), kind, WordKind.Word, "speech", start,
                    start + random.NextDouble() * 0.6, kind == EditSegmentKind.Range || random.Next(2) == 0);
            }).ToArray();
            foreach (var index in Enumerable.Range(0, segments.Length))
                Assert.Equal(LiteralCutRange(segments, index, duration), EditingEngine.CutRange(segments, index, duration));
            var plan = EditingEngine.BuildEditPlan(segments, duration, rate);
            Assert.Equal(plan.TotalSamples, plan.OutputSamples + plan.Cuts.Sum(cut => cut.EndSample - cut.StartSample));
            Assert.Equal(plan.OutputSamples, plan.Kept.Sum(part => part.EndSample - part.StartSample));
            Assert.All(plan.Cuts.Concat(plan.Kept), part => Assert.True(part.StartSample >= 0 && part.EndSample > part.StartSample && part.EndSample <= plan.TotalSamples));
            for (var index = 1; index < plan.Cuts.Count; index++) Assert.True(plan.Cuts[index - 1].EndSample < plan.Cuts[index].StartSample);
            long offset = 0;
            foreach (var part in plan.Kept)
            {
                Assert.Equal(part.StartSample / (double)rate, plan.SourceTime(offset / (double)rate));
                offset += part.EndSample - part.StartSample;
            }
            var previous = -1.0;
            for (var probe = 0; probe < 200; probe++)
            {
                var sample = plan.TotalSamples * probe / 200;
                var source = sample / (double)rate;
                var edited = plan.MapTime(source);
                Assert.True(edited >= previous);
                previous = edited;
                if (plan.CutContaining(source) is null) Assert.Equal(source, plan.SourceTime(edited));
                if (plan.OutputSamples > 0)
                {
                    var output = random.NextInt64(plan.OutputSamples) / (double)rate;
                    Assert.Equal(output, plan.MapTime(plan.SourceTime(output)));
                }
            }
            Assert.Equal(plan.TotalSamples / (double)rate, plan.SourceTime(plan.Duration));
        }
    }

    [Fact]
    public void ExplicitKindsIdentityAndRoundingDoNotDependOnIds()
    {
        EditSegment[] segments = [new("pause-fake", EditSegmentKind.Word, WordKind.Word, "word", 1, 2, true),
            new("arbitrary", EditSegmentKind.Range, null, null, 4.5, 5.5, true)];
        Assert.Equal(new TimeRange(0.9, 2.1), EditingEngine.CutRange(segments, 0, 10));
        Assert.Equal(new TimeRange(4.5, 5.5), EditingEngine.CutRange(segments, 1, 10));
        Assert.Throws<ArgumentException>(() => EditingEngine.BuildEditPlan([segments[1] with { Cut = false }], 10, 1));
        Assert.Equal(0, EditingEngine.BuildEditPlan([], 0.49999999999999994, 1).TotalSamples);
        Assert.Equal(1, EditingEngine.BuildEditPlan([], 0.5, 1).TotalSamples);
        var equal = new EditSegment("same", EditSegmentKind.Word, WordKind.Word, "word", 1, 2, true);
        Assert.Equal(new TimeRange(0.9, 2), EditingEngine.CutRange([equal, equal with { }], 0, 10));
        Assert.Equal(new TimeRange(1, 2), EditingEngine.CutRange([equal, equal with { }], 1, 10));
    }

    [Theory]
    [InlineData(double.NaN, 48000)]
    [InlineData(double.PositiveInfinity, 48000)]
    [InlineData(-1, 48000)]
    [InlineData(1, 0)]
    [InlineData(1, double.NaN)]
    [InlineData(1, double.PositiveInfinity)]
    [InlineData(double.MaxValue, 48000)]
    public void InvalidPlanningParametersAreRejected(double duration, double rate)
        => Assert.Throws<ArgumentException>(() => EditingEngine.BuildEditPlan([], duration, rate));

    [Fact]
    public void NonFiniteProbesCollapseToZeroAndOverflowProbesClamp()
    {
        var plan = EditingEngine.BuildEditPlan([new("head", EditSegmentKind.Range, null, null, 0, 1, true)], 3, 48000);
        foreach (var probe in new[] { double.NaN, double.NegativeInfinity, double.PositiveInfinity })
        {
            Assert.Equal(0, plan.MapTime(probe));
            Assert.Equal(1, plan.SourceTime(probe));
            Assert.Null(plan.CutContaining(probe));
        }
        Assert.Equal(plan.Duration, plan.MapTime(double.MaxValue));
        Assert.Equal(3, plan.SourceTime(double.MaxValue));
    }

    [Fact]
    public void ImportOwnsFinalIdsProvenanceAndDecodedPauseThreshold()
    {
        RawWord[] raw = [new("o\u0303", 0.2, 0.4, 0.8, "speaker", WordKind.Word), new("(laughs)", 1.5, 1.7, null, null, WordKind.Event)];
        var result = EditingImport.Pipeline(raw, null, TimingSource.Native, true);
        Assert.Equal(1, result.PauseThresholdSeconds);
        Assert.Equal("w1", result.Words[0].Id);
        Assert.Equal("õ", result.Words[0].Text);
        Assert.Equal(0.2, result.Words[0].RawStart);
        Assert.Equal(0.4, result.Words[0].RawEnd);
        Assert.Equal("speaker", result.Words[0].Speaker);
        Assert.Single(result.Pauses);
        Assert.Equal(0.8, EditingImport.Pipeline(raw, new AudioEnvelope(16000, 0.01, []), TimingSource.Dtw, false).PauseThresholdSeconds);
        Assert.Equal("o\u0303", raw[0].Text);
    }

    [Fact]
    public void EnvelopeAccumulatesChannelsInDoubleAndStoresFloatFrames()
    {
        var envelope = EditingAlgorithms.Analyze([new float[] { 1, 2, 9 }, new float[] { 3, 4, 9 }], 200);
        Assert.Equal(0.01, envelope.FrameSeconds);
        Assert.Equal((float)Math.Sqrt(7.5), Assert.Single(envelope.Rms));
        Assert.Empty(EditingAlgorithms.Analyze([], 48000).Rms);
        Assert.Throws<ArgumentOutOfRangeException>(() => EditingAlgorithms.Analyze([], 0));
    }

    [Fact]
    public void UndoRedoSnapshotsKeepSourceTimesAndRestoreOnlyCuts()
    {
        var original = State([Word("a", "um", 0, 0.2), Word("b", "original", 2, 2.3)]);
        var history = new EditHistory(original, [], []);
        history = history.Apply(new EditOperation.CutFillers()).Apply(new EditOperation.TightenPauses()).Apply(new EditOperation.Correct("b", "  going to  "));
        var corrected = history.Present;
        Assert.Same(original.Transcript, corrected.Transcript);
        Assert.Single(corrected.CutWordIds);
        Assert.Single(corrected.CutPauseIds);
        history = history.Apply(new EditOperation.RestoreCuts());
        Assert.Empty(history.Present.CutWordIds);
        Assert.Empty(history.Present.CutPauseIds);
        Assert.Equal("going to", history.Present.Corrections["b"]);
        Assert.Same(corrected, history.Undo().Present);
        Assert.Same(history.Present, history.Undo().Redo().Present);
        Assert.Empty(history.Undo().Apply(new EditOperation.Toggle("b")).RedoStack);
        Assert.Same(original, new EditHistory(original, [], []).Undo().Present);
    }

    [Fact]
    public void MixedSelectionAndThresholdChangesUsePauseLookupNotPrefixes()
    {
        var state = State([Word("pause-word", "um", 0, 0.2), Word("next", "next", 1.1, 1.3)]);
        var pause = Assert.Single(state.Pauses).Id;
        state = EditingEngine.Reduce(state, new EditOperation.CutSelection(["pause-word", pause]));
        Assert.Single(state.CutWordIds);
        Assert.Single(state.CutPauseIds);
        state = EditingEngine.Reduce(state, new EditOperation.CutSelection(["pause-word", pause]));
        Assert.Empty(state.CutWordIds);
        Assert.Empty(state.CutPauseIds);
        state = EditingEngine.Reduce(state, new EditOperation.Toggle(pause));
        state = EditingEngine.Reduce(state, new EditOperation.SetPauseThreshold(1));
        Assert.Empty(state.Pauses);
        Assert.Empty(state.CutPauseIds);
    }

    [Fact]
    public void ClipsRemainRangeLayersThroughNudgesRenamesAndAiDeduplication()
    {
        var state = State([Word("a", "um", 0, 0.2), Word("b", "middle", 2, 2.2), Word("c", "end", 4, 4.2)]);
        state = EditingEngine.Reduce(state, new EditOperation.AddClip(new("manual", "b", "c", null, ClipOrigin.Manual, null, null, false)));
        Assert.True(Assert.Single(state.Clips).Selected);
        state = EditingEngine.Reduce(state, new EditOperation.AddAiClips("result", [new AiClip("duplicate", "", 5, "b", "c"), new AiClip("new", "", 8, "a", "b")]));
        Assert.Equal(2, state.Clips.Count);
        Assert.Equal(1, state.Clips[1].AiClipIndex);
        state = EditingEngine.Reduce(state, new EditOperation.SetActiveClip("manual"));
        state = EditingEngine.Reduce(state, new EditOperation.Toggle("b"));
        state = EditingEngine.Reduce(state, new EditOperation.CutFillers());
        Assert.DoesNotContain("a", state.CutWordIds);
        state = EditingEngine.Reduce(state, new EditOperation.UpdateClip("manual", 0, 1));
        state = EditingEngine.Reduce(state, new EditOperation.RenameClip("manual", "\ufeff New title \ufeff"));
        state = EditingEngine.Reduce(state, new EditOperation.SetClipSelected("manual", false));
        Assert.Equal("a", state.Clips[0].StartWordId);
        Assert.Equal("New title", state.Clips[0].Title);
        Assert.False(state.Clips[0].Selected);
        Assert.Single(state.CutWordIds);
        state = EditingEngine.Reduce(state, new EditOperation.RemoveClip("manual"));
        Assert.Null(state.ActiveClipId);
        Assert.Contains("b", state.CutWordIds);
    }

    [Fact]
    public void TextCopyPreservesCaseMultiWordCorrectionsAndOnlySpeech()
    {
        var state = State([Word("a", "Straße", 0, 0.2), Word("b", "original", 1, 1.2), Word("event", "(laughs)", 2, 2.2, WordKind.Event)]);
        state = EditingEngine.Reduce(state, new EditOperation.Correct("b", "\ufeff going to o\u0303 \ufeff"));
        Assert.Equal("Straße going to õ", EditingEngine.TranscriptText(state));
        var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, 3), 3, 48000);
        Assert.Equal(["Straße", "going to õ"], EditingEngine.CaptionWords(state, plan).Select(word => word.Text));
        state = EditingEngine.Reduce(state, new EditOperation.Correct("b", "original"));
        Assert.Empty(state.Corrections);
        Assert.Equal("i", EditingAlgorithms.AlignTranscriptWords([new RawWord("İ", 0, 1, null, null, WordKind.Word)], "i")[0].Text);
    }

    [Fact]
    public void LongTranscriptPlanningStaysLinearAfterSortingAndJoinGainsAllocateNothing()
    {
        var segments = Enumerable.Range(0, 10_000).Select(index => new EditSegment("w" + index, EditSegmentKind.Word, WordKind.Word, "word", index * 0.3, index * 0.3 + 0.1, index % 5 == 0)).ToArray();
        var plan = EditingEngine.BuildEditPlan(segments, 3000, 48000);
        for (var iteration = 0; iteration < 20; iteration++) plan = EditingEngine.BuildEditPlan(segments, 3000, 48000);
        var timings = new double[31];
        for (var iteration = 0; iteration < timings.Length; iteration++)
        {
            var started = Stopwatch.GetTimestamp();
            plan = EditingEngine.BuildEditPlan(segments, 3000, 48000);
            timings[iteration] = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
        }
        Array.Sort(timings);
        var median = timings[timings.Length / 2];
        var percentile95 = timings[(int)(timings.Length * 0.95)];
        TestContext.Current.TestOutputHelper?.WriteLine("10,000 words / 2,000 cuts: median {0:F2} ms, p95 {1:F2} ms", median, percentile95);
        Assert.True(median < 10, $"Plan rebuild median {median:F2} ms exceeds architecture §14's 10 ms budget.");
        Assert.Equal(2000, plan.Cuts.Count);
        Assert.Equal(2000, plan.Kept.Count);
        var warmup = plan.JoinGain(100);
        var before = GC.GetAllocatedBytesForCurrentThread();
        var total = warmup;
        for (var sample = 0; sample < 10_000; sample++) total += plan.JoinGain(sample);
        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        Assert.Equal(0, allocated);
        Assert.True(total > 0);
    }

    private static TimeRange LiteralCutRange(IReadOnlyList<EditSegment> segments, int index, double duration)
    {
        var segment = segments[index];
        if (segment.Kind == EditSegmentKind.Range) return new(segment.Start, segment.End);
        var speech = segments.Select((word, position) => (word, position)).Where(pair => pair.word.Kind == EditSegmentKind.Word).OrderBy(pair => pair.word.Start).ThenBy(pair => pair.position).ToArray();
        if (segment.Kind == EditSegmentKind.Pause)
        {
            EditSegment? before = null;
            EditSegment? after = null;
            foreach (var pair in speech)
            {
                if (pair.word.End <= segment.Start + 1e-6 && (before is null || pair.word.End > before.End)) before = pair.word;
                if (after is null && pair.word.Start >= segment.End - 1e-6) after = pair.word;
            }
            return new(segment.Start + (before is { Cut: false } ? 0.15 : 0), segment.End - (after is { Cut: false } ? 0.15 : 0));
        }
        var position = Array.FindIndex(speech, pair => pair.position == index);
        var earlierEnd = 0.0;
        for (var previous = 0; previous < position; previous++) earlierEnd = Math.Max(earlierEnd, speech[previous].word.End);
        if (earlierEnd >= segment.End) return new(segment.Start, segment.End);
        var nextStart = position + 1 < speech.Length ? speech[position + 1].word.Start : duration;
        return new(segment.Start - Math.Min(0.1, Math.Max(0, segment.Start - earlierEnd) / 2), segment.End + Math.Min(0.1, Math.Max(0, nextStart - segment.End) / 2));
    }
}
