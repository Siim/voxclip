using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.ExportChecks;

/// <summary>What the export check expects to hear (ADR-R49), from the same timeline the renderer plays. Twin of the Mac
/// <c>ExportCheckExpectationTests</c>.</summary>
public sealed class ExportCheckExpectationTests
{
    /// <summary>"So um, today we ship uh the clipper. Thanks" with a Rewrite of "we ship" as "new words" (segment vl-passage).</summary>
    static Project Passage() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));

    [Fact]
    public void ARewrittenPhraseIsExpectedWithItsNewWordsWhereTheEditPlacedThem()
    {
        var plan = VoiceLabRenderContract.Prepare(Passage(), VoiceLabOutputScope.Clip("clip-main"), VoiceLabLabelPosition.TopRight).OutputPlan;
        Assert.True(plan.RequiresSyntheticRendering, "the Rewrite renders on the Voice Lab path");
        var edit = ExportCheckExpectation.Make(new RenderTimeline.VoiceLab(plan), new ClipSpeedTiming(1), [], null, plan.Duration);
        Assert.Equal(["today", "new", "words", "uh", "the", "clipper."], edit.Words.Select(word => word.Text));
        // The source words it replaced are not expected; the new ones are, in the phrase, at the plan's placed times.
        var phrase = Assert.Single(edit.Phrases);
        Assert.Equal("vl-passage", phrase.Id);
        var placed = edit.Words.Where(word => word.Phrase == "vl-passage").ToArray();
        Assert.Equal(["new", "words"], placed.Select(word => word.Text));
        var piece = plan.Pieces.First(item => item.SegmentId == "vl-passage");
        var pieceStart = piece.OutputStartSample / plan.SampleRate;
        Assert.True(Math.Abs(placed[0].Start - (pieceStart + 0.1)) < 1e-4, "the TTS word time inside the piece");
        Assert.Equal(pieceStart, phrase.Start);
        // The kept filler is optional; the seams before and after the phrase are cuts.
        Assert.Equal(["uh"], edit.Words.Where(word => word.Optional).Select(word => word.Text));
        Assert.Contains(edit.Cuts, cut => Math.Abs(cut - pieceStart) < 1e-9);
        Assert.Contains(edit.Cuts, cut => Math.Abs(cut - piece.OutputEndSample / plan.SampleRate) < 1e-9);
    }

    [Fact]
    public void SourceWordsAreExpectedThroughThePlanAtTheClipSpeed()
    {
        var project = Passage();
        var state = EditingEngine.FromProject(project)! with
        {
            CutWordIds = new HashSet<string>(StringComparer.Ordinal) { "w5" },
            Clips = [new ClipRange("scope", "w1", "w8", null, ClipOrigin.Manual, null, null, true)],
            ActiveClipId = "scope",
        };
        var duration = project.Media.Source.DurationSeconds;
        var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, duration), duration, project.Media.Source.Audio?.SampleRate ?? 48_000, state.PauseKeepSeconds);
        var timeline = new RenderTimeline.Legacy(plan);
        var plain = ExportCheckExpectation.Make(timeline, new ClipSpeedTiming(1), [], state, plan.Duration);
        Assert.Equal(["So", "um,", "today", "we", "uh", "the", "clipper."], plain.Words.Select(word => word.Text));
        Assert.Equal(["um,", "uh"], plain.Words.Where(word => word.Optional).Select(word => word.Text));
        Assert.Empty(plain.Phrases);
        // One join, where "ship" was cut: between "we" and "uh".
        Assert.Equal(plan.Kept.Count - 1, plain.Cuts.Count);
        var cut = Assert.Single(plain.Cuts);
        var we = plain.Words.First(word => word.Text == "we");
        var uh = plain.Words.First(word => word.Text == "uh");
        Assert.True(cut > we.End && cut < uh.Start, $"{cut} between {we.End} and {uh.Start}");
        // At 2× every output time halves.
        var fast = ExportCheckExpectation.Make(timeline, new ClipSpeedTiming(2), [], state, plan.Duration / 2);
        Assert.All(plain.Words.Zip(fast.Words), pair =>
        {
            Assert.True(Math.Abs(pair.First.Start / 2 - pair.Second.Start) < 1e-12);
            Assert.True(Math.Abs(pair.First.End / 2 - pair.Second.End) < 1e-12);
        });
        Assert.True(Math.Abs(plain.Cuts[0] / 2 - fast.Cuts[0]) < 1e-12);
        // A bleeped word is not heard, so it is not expected.
        var bleep = new ClipEffect("fx-bleep-1", "scope", "bleep", 2.6, 2.75) { WordIds = ["w4"] };
        var bleeped = ExportCheckExpectation.Make(timeline, new ClipSpeedTiming(1), [bleep], state, plan.Duration);
        Assert.Equal(["So", "um,", "today", "uh", "the", "clipper."], bleeped.Words.Select(word => word.Text));
        // Without a transcript only the cuts are expected.
        Assert.Empty(ExportCheckExpectation.Make(timeline, new ClipSpeedTiming(1), [], null, plan.Duration).Words);
    }
}
