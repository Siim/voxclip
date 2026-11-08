using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Replays shared/fixtures/voice-lab/whole-clip-fit-cases.json (ADR-R46 update 2026-11-08), as the Swift
/// WholeClipFitReplayTests do: the fit on the clip as edited (a shorter voice laid out, never a longer wording), check before
/// paying, the picture's cuts, the clip's own cuts in a window, the pause bound and the edited cut recipe's form. The user's
/// clip is replayed as numbers: its verdict and the old one. Mac <c>WholeClipFitReplayTests</c>.</summary>
public sealed class WholeClipFitReplayTests
{
    private static readonly JsonObject Cases = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/whole-clip-fit-cases.json"))!.AsObject();
    private static JsonArray Rows(string name) => Cases[name]!.AsArray();
    private static List<VoiceLabVideoCut> Cuts(JsonNode? node) =>
        node!.AsArray().Select(cut => new VoiceLabVideoCut(cut!["startSample"]!.GetValue<long>(), cut["endSample"]!.GetValue<long>())).ToList();

    [Fact]
    public void FormatAndConstantsAreTheMacs()
    {
        Assert.Equal("voxclip-whole-clip-fit/1", Cases["format"]!.GetValue<string>());
        Assert.Equal(["format", "constants", "usersClip", "fit", "rewordFits", "layoutCuts", "editedCuts", "pauseBound"], Cases.Select(pair => pair.Key));
        var constants = Cases["constants"]!;
        Assert.Equal(WholeClipRevoice.FitTolerance, constants["fitTolerance"]!.GetValue<double>());
        Assert.Equal(WholeClipRevoice.MaximumRewordRounds, constants["maximumRewordRounds"]!.GetValue<int>());
        Assert.Equal(VoiceLabNaturalPacing.EDITED_CUT_ZOOM, constants["editedCutZoom"]!.GetValue<double>());
        Assert.Equal(VoiceLabNaturalPacing.MAXIMUM_EDITED_CUTS, constants["maximumEditedCuts"]!.GetValue<int>());
        Assert.Equal(VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, constants["pauseFloorPunct"]!.GetValue<double>());
        Assert.Equal(VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE, constants["pauseFloorPhrase"]!.GetValue<double>());
    }

    private static void Expect(JsonNode expected, WholeClipRevoice.Fit fit, double voice, double video)
    {
        switch (expected["kind"]!.GetValue<string>())
        {
            case "matched":
                var matched = Assert.IsType<WholeClipRevoice.Fit.Matched>(fit);
                Assert.Equal(expected["factor"]!.GetValue<double>(), matched.Factor);
                Assert.Equal(expected["copy"]!.GetValue<string>(), WholeClipRevoice.MatchedCopy(matched.Factor));
                break;
            case "laidOut":
                var laid = Assert.IsType<WholeClipRevoice.Fit.LaidOut>(fit);
                Assert.Equal(expected["factor"]!.GetValue<double>(), laid.Factor);
                Assert.Equal(expected["copy"]!.GetValue<string>(), WholeClipRevoice.LaidOutCopy(laid.Factor));
                break;
            case "reword":
                Assert.Equal(new WholeClipRevoice.Fit.Reword(expected["targetWords"]!.GetValue<int>()), fit);
                break;
            default:
                Assert.Equal(new WholeClipRevoice.Fit.CannotFit(voice, video), fit);
                break;
        }
    }

    [Fact]
    public void TheFitOnTheClipAsEdited()
    {
        Assert.Equal(20, Rows("fit").Count);
        foreach (var row in Rows("fit"))
        {
            var voice = row!["voiceSeconds"]!.GetValue<double>(); var video = row["videoSeconds"]!.GetValue<double>();
            Expect(row["expected"]!, WholeClipRevoice.FitVoice(voice, video, row["words"]!.GetValue<int>(), row["round"]!.GetValue<int>()), voice, video);
        }
    }

    /// <summary>The user's MVP44 clip: a 27 s voice for 0:31.4 as edited is laid out, where the run used to ask for a longer wording.</summary>
    [Fact]
    public void TheUsersClipIsLaidOutNotPadded()
    {
        var clip = Cases["usersClip"]!;
        var voice = clip["voiceSeconds"]!.GetValue<double>();
        var edited = clip["shown"]!["editedSeconds"]!.GetValue<double>();
        Expect(clip["expected"]!, WholeClipRevoice.FitVoice(voice, edited, clip["scriptWords"]!.GetValue<int>(), 0), voice, edited);
        Assert.IsType<WholeClipRevoice.Fit.LaidOut>(WholeClipRevoice.FitVoice(voice, clip["shown"]!["sourceWindowSeconds"]!.GetValue<double>(), 49, 0));
        Assert.False(clip["before"]!["shorter"]!.GetValue<bool>());
        Assert.Equal(66, clip["words"]!.AsArray().Count);
    }

    [Fact]
    public void CheckBeforePaying()
    {
        Assert.Equal(11, Rows("rewordFits").Count);
        foreach (var row in Rows("rewordFits"))
        {
            double voice = row!["voiceSeconds"]!.GetValue<double>(), estimate = row["estimateSeconds"]!.GetValue<double>();
            double next = row["newEstimateSeconds"]!.GetValue<double>(), video = row["videoSeconds"]!.GetValue<double>();
            Assert.Equal(row["predicted"]?.GetValue<double>(), WholeClipRevoice.PredictedSeconds(voice, estimate, next));
            Assert.Equal(row["fits"]!.GetValue<bool>(), WholeClipRevoice.RewordFits(voice, estimate, next, video));
        }
    }

    [Fact]
    public void ThePicturesCuts()
    {
        Assert.Equal(16, Rows("layoutCuts").Count);
        foreach (var row in Rows("layoutCuts"))
        {
            var found = WholeClipRevoice.LayoutCuts(Cuts(row!["cuts"]), row["startSample"]!.GetValue<long>(), row["endSample"]!.GetValue<long>(),
                row["removedSamples"]!.GetValue<long>());
            if (row["expected"] is not { } expected) { Assert.True(found is null, row["id"]!.GetValue<string>()); continue; }
            Assert.Equal(Cuts(expected), found);
        }
    }

    [Fact]
    public void TheClipsOwnCutsInAWindow()
    {
        Assert.Equal(7, Rows("editedCuts").Count);
        foreach (var row in Rows("editedCuts"))
        {
            var pieces = row!["pieces"]!.AsArray().Select((piece, index) => new VoiceLabOutputPiece(VoiceLabOutputPieceKind.Source,
                piece!["sourceStartSample"]!.GetValue<long>(), piece["sourceEndSample"]!.GetValue<long>(), index, index + 1, null, null, null)).ToList();
            var plan = new VoiceLabOutputPlan(48_000, 1_000_000, pieces, [], VoiceLabOutputScope.Full);
            Assert.Equal(Cuts(row["expected"]), WholeClipRevoice.EditedCuts(plan, row["startSample"]!.GetValue<long>(), row["endSample"]!.GetValue<long>()));
        }
    }

    [Fact]
    public void ThePauseBound()
    {
        foreach (var row in Rows("pauseBound"))
            Assert.Equal(row!["bound"]!.GetValue<double>(), WholeClipRevoice.LayoutPauseBound(row["pauseThresholdSeconds"]!.GetValue<double>()));
    }

    /// <summary>The edited picture's recipe form: many cuts at zoom 1 with no edge guard; a punched-in cut keeps one or two.</summary>
    [Fact]
    public void AnEditedCutRecipeValidatesAtZoomOne()
    {
        var cuts = Enumerable.Range(0, 6).Select(index => new VoiceLabVideoCut(index * 10_000L + 2_000, index * 10_000L + 6_000)).ToList();
        var video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Cut, 0, 60_000, 36_000, null, VoiceLabNaturalPacing.EDITED_CUT_ZOOM, 0.5, 0.5,
            null, null, null, null, null, null, null) { Cuts = cuts };
        Assert.True(VoiceLabNaturalPacing.ValidCuts(video, 48_000));
        Assert.False(VoiceLabNaturalPacing.ValidCuts(video with { Zoom = VoiceLabNaturalPacing.CUT_PUNCH_IN }, 48_000));
        Assert.False(VoiceLabNaturalPacing.ValidCuts(video with { OutputSamples = 36_001 }, 48_000));
        Assert.True(VoiceLabNaturalPacing.ValidCuts(video with { OutputSamples = 40_000, Cuts = [new(0, 20_000)] }, 48_000));
        Assert.False(VoiceLabNaturalPacing.ValidCuts(video with { OutputSamples = 40_000, Cuts = [new(2_000, 12_000), new(8_000, 18_000)] }, 48_000));
    }
}
