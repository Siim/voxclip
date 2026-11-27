using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.ExportChecks;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Shared;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.ExportChecks;

/// <summary>What the export check expects to hear (ADR-R49), from the same timeline the renderer plays. Twin of the Mac
/// <c>ExportCheckExpectationTests</c>.</summary>
public sealed class ExportCheckExpectationTests
{
    [Fact]
    public void SharedRecordingPlansReportOnlyRecordingChangesAsRecordingSeams()
    {
        var fixture = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/plan-cases.json"))!;
        var rate = fixture["sampleRate"]!.GetValue<double>();
        foreach (var row in fixture["cases"]!.AsArray())
        {
            var document = JsonNode.Parse(FixtureLoader.ReadText("fixtures/recordings/" + row!["project"]!.GetValue<string>()))!;
            var edits = row["edits"]!.DeepClone();
            var clip = row["clip"];
            edits["clips"] = clip is null ? new JsonArray() : new JsonArray(clip.DeepClone());
            edits["activeClipId"] = clip?["id"]?.DeepClone();
            document["edits"] = edits;
            var project = ProjectSerialization.Deserialize(document.ToJsonString());
            var state = EditingEngine.FromProject(project)!;
            var plan = EditingEngine.BuildPlan(state, project.Media.Source.DurationSeconds, rate);
            var edit = ExportCheckExpectation.Make(new RenderTimeline.Legacy(plan), new(1), [], state, plan.Duration);
            Assert.Equal(row["recordingSeams"]!.AsArray().Select(value => value!.GetValue<long>() / rate), edit.RecordingSeams.Select(seam => seam.At));
            Assert.All(edit.RecordingSeams, seam => { Assert.Contains(seam.At, edit.Cuts); Assert.NotEqual(seam.From, seam.To); });
            Assert.Equal(row["captions"]!.AsArray().Select(word => word![1]!.GetValue<string>()), edit.Words.Select(word => word.Text));
        }
    }

    [Fact]
    public void WrongPictureAndAQuieterRecordingAreSeparateWarnings()
    {
        ExportCheckRecordingSeam seam = new(21.4, "0007", "0010");
        ExportCheckInput input = new([], [], new(0, 30), new(0, 30), 1.0 / 30, new(ExportLoudness.Off, -15, -2), new(320, 180))
        { Recordings = [new(seam, PictureMatches: false, BeforeLufs: -16, AfterLufs: -20)] };
        var report = ExportCheck.Run(input);
        Assert.False(report.Passed);
        var picture = report[ExportCheckKind.Sync]!.ToJson()["items"]![0]!;
        Assert.Equal("pictureSource", picture["kind"]!.GetValue<string>());
        Assert.Equal("0010", picture["recordingSeam"]!["to"]!.GetValue<string>());
        var level = Assert.Single(report[ExportCheckKind.Loudness]!.Items);
        Assert.Equal("0010 is quieter than 0007 at 0:21. Listen there.", level.Reason);
        Assert.True(ExportCheck.Run(input with { Recordings = [new(seam, true, -16, -19)] }).Passed);
    }

    [Fact]
    public void StorySeamPassesUnlessTheNextPartLosesItsFirstWord()
    {
        var project = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/story-clips/story-project.voxclip"));
        var timeline = RenderCallerInputs.Timeline(project, project.Edits.ActiveClipId);
        var edit = ExportCheckExpectation.Make(timeline, new ClipSpeedTiming(1), [], EditingEngine.FromProject(project), timeline.Duration);
        var seam = Assert.Single(edit.Cuts);
        var next = edit.Words.ToList().FindIndex(word => word.Start >= seam);
        Assert.InRange(next, 1, edit.Words.Count - 2);
        var heard = edit.Words.Select(word => new ExportCheckHeard(word.Text, word.Start, word.End)).ToList();
        var input = new ExportCheckInput(edit.Words, heard, new(0, edit.Duration), new(0, edit.Duration), 1.0 / 30, null, new(320, 180)) { Cuts = edit.Cuts };
        Assert.True(ExportCheck.Run(input).Passed);
        heard.RemoveAt(next);
        var result = Assert.IsType<ExportCheckResult>(ExportCheck.Run(input)[ExportCheckKind.Words]);
        Assert.Equal(ExportCheckStatus.Warning, result.Status);
        Assert.Contains(result.Items, item => item.Kind == ExportCheckItemKind.CutOff && item.Expected == edit.Words[next].Text);
    }

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
