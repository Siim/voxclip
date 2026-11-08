using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Replays shared/fixtures/voice-lab/whole-clip-speed-cases.json (ADR-R46 "Your own pace", 2026-11-08), as the Swift
/// WholeClipSpeedReplayTests do: the picture's even speed-up for a shorter voice (to at most 1.2×), the Fit line, the record's
/// retime range, the sped edited cut recipe and its even mapping. Mac <c>WholeClipSpeedReplayTests</c>.</summary>
public sealed class WholeClipSpeedReplayTests
{
    private static readonly JsonObject Cases = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/whole-clip-speed-cases.json"))!.AsObject();
    private static JsonArray Rows(string name) => Cases[name]!.AsArray();
    private static List<VoiceLabVideoCut> Cuts(JsonNode? node) =>
        node!.AsArray().Select(cut => new VoiceLabVideoCut(cut![0]!.GetValue<long>(), cut[1]!.GetValue<long>())).ToList();

    [Fact]
    public void FormatAndConstantsAreTheMacs()
    {
        Assert.Equal("voxclip-whole-clip-speed/1", Cases["format"]!.GetValue<string>());
        Assert.Equal(["format", "constants", "pictureSpeed", "spedCopy", "validRetime", "spedCuts", "mapping"], Cases.Select(pair => pair.Key));
        Assert.Equal(WholeClipRevoice.MaximumPictureSpeed, Cases["constants"]!["maximumPictureSpeed"]!.GetValue<double>());
        Assert.Equal(WholeClipRevoice.FitTolerance, Cases["constants"]!["fitTolerance"]!.GetValue<double>());
    }

    [Fact]
    public void TheSpeedTheCopyAndTheRange()
    {
        Assert.Equal(11, Rows("pictureSpeed").Count);
        foreach (var row in Rows("pictureSpeed"))
            Assert.Equal(row!["speed"]!.GetValue<double>(),
                WholeClipRevoice.PictureSpeed(row["voiceSeconds"]!.GetValue<double>(), row["videoSeconds"]!.GetValue<double>()));
        Assert.Equal(5, Rows("spedCopy").Count);
        foreach (var row in Rows("spedCopy"))
            Assert.Equal(row!["copy"]!.GetValue<string>(), WholeClipRevoice.SpedCopy(row["speed"]!.GetValue<double>(), row["laidOut"]!.GetValue<bool>()));
        Assert.Equal(8, Rows("validRetime").Count);
        foreach (var row in Rows("validRetime"))
            Assert.Equal(row!["valid"]!.GetValue<bool>(), WholeClipRevoice.ValidRetime(row["value"]!.GetValue<double>()));
    }

    [Fact]
    public void TheSpedEditedCut()
    {
        Assert.Equal(11, Rows("spedCuts").Count);
        foreach (var row in Rows("spedCuts"))
        {
            var video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Cut, row!["sourceStartSample"]!.GetValue<long>(), row["sourceEndSample"]!.GetValue<long>(),
                row["outputSamples"]!.GetValue<long>(), row["retimeFactor"]?.GetValue<double>(), row["zoom"]!.GetValue<double>(), 0.5, 0.5,
                null, null, null, null, null, null, null, Cuts(row["cuts"]));
            Assert.True(row["valid"]!.GetValue<bool>() == VoiceLabNaturalPacing.ValidCuts(video, 48_000), row["id"]!.GetValue<string>());
        }
    }

    [Fact]
    public void TheEvenMapping()
    {
        Assert.Equal(2, Rows("mapping").Count);
        foreach (var row in Rows("mapping"))
        {
            var p = row!["piece"]!;
            long sourceStart = p["sourceStartSample"]!.GetValue<long>(), sourceEnd = p["sourceEndSample"]!.GetValue<long>();
            long outputStart = p["outputStartSample"]!.GetValue<long>(), outputEnd = p["outputEndSample"]!.GetValue<long>();
            var head = new VoiceLabOutputPiece(VoiceLabOutputPieceKind.Source, 0, sourceStart, 0, outputStart, null, null, null);
            var piece = new VoiceLabOutputPiece(VoiceLabOutputPieceKind.Synth, sourceStart, sourceEnd, outputStart, outputEnd, "s", "a", null);
            var plan = new VoiceLabOutputPlan(48_000, sourceEnd, [head, piece], [], VoiceLabOutputScope.Full)
            {
                VideoCuts = new Dictionary<string, IReadOnlyList<VoiceLabVideoCut>> { ["s"] = Cuts(row["cuts"]) },
            };
            foreach (var value in row["mapTime"]!.AsArray())
                Assert.Equal(value!["output"]!.GetValue<double>(), plan.MapTime(value["source"]!.GetValue<double>()));
            foreach (var value in row["sourceTime"]!.AsArray())
                Assert.Equal(value!["source"]!.GetValue<double>(), plan.SourceTime(value["edited"]!.GetValue<double>()));
        }
    }

    /// <summary>The framing plays a sped piece's kept source evenly: its spans tile the piece's output, each scaled by output ÷ kept.</summary>
    [Fact]
    public void ASpedCutPieceIsFramedEvenly()
    {
        var piece = new VoiceLabOutputPiece(VoiceLabOutputPieceKind.Synth, 0, 192_000, 0, 120_000, "s", "a", null);
        var plan = new VoiceLabOutputPlan(48_000, 192_000, [piece], [], VoiceLabOutputScope.Full);
        var video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Cut, 0, 192_000, 120_000, 1.2, VoiceLabNaturalPacing.EDITED_CUT_ZOOM, 0.5, 0.5,
            null, null, null, null, null, null, null, [new VoiceLabVideoCut(96_000, 144_000)]);
        var framing = VoiceLabVideoFraming.Build(plan, _ => video);
        Assert.Equal(2, framing.Spans.Count);
        Assert.Equal(new VoiceLabVideoSpan(0, 96_000, 0, 80_000, 1, 0.5, 0.5), framing.Spans[0]);
        Assert.Equal(new VoiceLabVideoSpan(144_000, 192_000, 80_000, 120_000, 1, 0.5, 0.5), framing.Spans[1]);
    }
}
