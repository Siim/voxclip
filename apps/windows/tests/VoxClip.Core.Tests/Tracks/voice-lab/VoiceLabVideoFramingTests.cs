using System.Text.Json;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Changed-duration video (ADR-R38) on Windows: shared framing vectors, the pre-pay/post-pay agreement for a
/// phrase that fits only with a video cut, and the render contract accepting Cut and Match video recipes.</summary>
public sealed class VoiceLabVideoFramingTests
{
    [Fact]
    public void SharedFramingVectorsReplayExactly()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/video-framing-cases.json");
        var root = document.RootElement;
        Assert.Equal(["schema", "sampleRate", "matchZoom", "cutPunchIn", "frameCaseCount", "frameCases", "cropCaseCount", "cropCases"],
            root.EnumerateObject().Select(property => property.Name));
        Assert.Equal("voxclip-video-framing/1", root.GetProperty("schema").GetString());
        Assert.Equal(VoiceLabVideoDurationOptions.MatchZoom, root.GetProperty("matchZoom").GetDouble());
        Assert.Equal(VoiceLabNaturalPacing.CUT_PUNCH_IN, root.GetProperty("cutPunchIn").GetDouble());
        var rate = root.GetProperty("sampleRate").GetDouble();
        var frameCases = root.GetProperty("frameCases").EnumerateArray().ToArray();
        Assert.Equal(root.GetProperty("frameCaseCount").GetInt32(), frameCases.Length);
        Assert.Equal(5, frameCases.Length);
        foreach (var row in frameCases)
        {
            var id = row.GetProperty("id").GetString()!;
            var pieces = new List<VoiceLabOutputPiece>();
            var videos = new Dictionary<VoiceLabOutputPiece, VoiceLabVideoRecipe>(ReferenceEqualityComparer.Instance);
            var cuts = new Dictionary<string, IReadOnlyList<VoiceLabVideoCut>>();
            foreach (var (item, index) in row.GetProperty("pieces").EnumerateArray().Select((item, index) => (item, index)))
            {
                var synth = item.GetProperty("kind").GetString() == "synth";
                var piece = new VoiceLabOutputPiece(synth ? VoiceLabOutputPieceKind.Synth : VoiceLabOutputPieceKind.Source,
                    item.GetProperty("sourceStartSample").GetInt64(), item.GetProperty("sourceEndSample").GetInt64(),
                    item.GetProperty("outputStartSample").GetInt64(), item.GetProperty("outputEndSample").GetInt64(),
                    synth ? "segment-" + index : null, null, null);
                pieces.Add(piece);
                if (!synth) continue;
                var video = item.GetProperty("video");
                var mode = video.GetProperty("mode").GetString() == "cut" ? VoiceLabVideoMode.Cut : VoiceLabVideoMode.ZoomCover;
                VoiceLabVideoCut[]? spans = video.GetProperty("cuts").ValueKind == JsonValueKind.Null ? null :
                    video.GetProperty("cuts").EnumerateArray().Select(cut => new VoiceLabVideoCut(cut[0].GetInt64(), cut[1].GetInt64())).ToArray();
                double? Number(string name) => video.GetProperty(name).ValueKind == JsonValueKind.Null ? null : video.GetProperty(name).GetDouble();
                videos[piece] = new(mode, piece.SourceStartSample, piece.SourceEndSample, piece.OutputEndSample - piece.OutputStartSample,
                    Number("retimeFactor"), Number("zoom"), Number("faceX"), Number("faceY"), null, null, null, null, null, null, null) { Cuts = spans };
                if (spans is not null) cuts[piece.SegmentId!] = spans;
            }
            var plan = new VoiceLabOutputPlan(rate, row.GetProperty("totalSourceSamples").GetInt64(), pieces, [], VoiceLabOutputScope.Full) { VideoCuts = cuts };
            var framing = VoiceLabVideoFraming.Build(plan, piece => videos.GetValueOrDefault(piece));
            var expected = row.GetProperty("spans").EnumerateArray().Select(span => new VoiceLabVideoSpan(span[0].GetInt64(), span[1].GetInt64(),
                span[2].GetInt64(), span[3].GetInt64(), span[4].GetDouble(), span[5].GetDouble(), span[6].GetDouble())).ToArray();
            Assert.True(expected.SequenceEqual(framing.Spans), id);
            var fps = row.GetProperty("fps").GetDouble();
            foreach (var frame in row.GetProperty("frames").EnumerateArray())
            {
                var edited = frame[0].GetInt64() / fps;
                var span = framing.At(edited);
                Assert.True(frame[1].GetDouble() == plan.SourceTime(edited), $"{id} frame {frame[0]}: source {plan.SourceTime(edited)}");
                Assert.True(frame[2].GetDouble() == span.Zoom && frame[3].GetDouble() == span.AnchorX && frame[4].GetDouble() == span.AnchorY,
                    $"{id} frame {frame[0]}: zoom {span.Zoom}");
            }
        }
        var cropCases = root.GetProperty("cropCases").EnumerateArray().ToArray();
        Assert.Equal(root.GetProperty("cropCaseCount").GetInt32(), cropCases.Length);
        foreach (var row in cropCases)
        {
            var source = new PixelSize(row.GetProperty("source")[0].GetInt32(), row.GetProperty("source")[1].GetInt32());
            var output = new PixelSize(row.GetProperty("output")[0].GetInt32(), row.GetProperty("output")[1].GetInt32());
            static RectD Rect(JsonElement value) => new(value[0].GetDouble(), value[1].GetDouble(), value[2].GetDouble(), value[3].GetDouble());
            var aspect = ExportPresets.CenterCrop(source, output);
            Assert.Equal(Rect(row.GetProperty("aspectCrop")), aspect);
            Assert.Equal(Rect(row.GetProperty("crop")), VoiceLabVideoFraming.FaceCrop(new(0, 0, source.Width, source.Height), aspect,
                row.GetProperty("zoom").GetDouble(), row.GetProperty("faceX").GetDouble(), row.GetProperty("faceY").GetDouble()));
        }
    }

    /// <summary>Lead review finding 2: a phrase priced as "fits with a video cut" must, once paid, offer a renderable Cut.
    /// The pre-pay estimate counts a phrase as fitting only through the choices the post-pay take offers.</summary>
    [Fact]
    public void PrePayCutFitAgreesWithThePaidTakesVideoChoices()
    {
        var source = new AudioEnvelope(48000, 0.01, Enumerable.Range(0, 240).Select(block =>
            block is >= 50 and < 56 or >= 190 and < 196 ? 0.001f : 1f).ToArray());
        var flat = new AudioEnvelope(48000, 0.01, Enumerable.Repeat(1f, 240).ToArray());
        VoiceLabWord[] words = [new("hello,", 0, 0.3, true), new("world", 0.5, 1, true)];
        var take = new VoiceLabFitTake(48000, 48000, 0, 1, words,
            new(48000, 0.01, Enumerable.Range(0, 100).Select(block => block is >= 30 and < 50 ? 0f : 1f).ToArray()));
        var profile = new VoiceLabPauseProfile(new([0.1, 0.7, 0.8]), new([]));
        foreach (var (envelope, cuts) in new[] { (source, true), (flat, false) })
        {
            var timing = VoiceLabPaceMatching.Match(1, Window(2.4), null, null, 48000, false, supportsPace: false, sourceEnvelope: envelope);
            var fit = VoiceLabNaturalPacing.Fit(Window(2.4), null, null, take, 48000, false, profile, [], envelope, []);
            var options = new VoiceLabVideoDurationOptions(fit, 48000, 48000);
            Assert.False(options.Allows(VoiceLabVideoMode.Source));
            Assert.False(options.Allows(VoiceLabVideoMode.Retimed));
            Assert.Equal(cuts, timing.FitsWithVideoCut);
            Assert.Equal(cuts, options.Allows(VoiceLabVideoMode.Cut));
            Assert.Equal(timing.Fits, options.Allows(VoiceLabVideoMode.Cut) || options.Allows(VoiceLabVideoMode.Retimed));
            if (!cuts) continue;
            var video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Cut, fit.Plan.WindowStartSample, fit.Plan.WindowEndSample,
                options.OutputSamples!.Value, null, VoiceLabNaturalPacing.CUT_PUNCH_IN, 0.5, 0.5, null, null, null, null, null, null, null) { Cuts = options.Cuts };
            Assert.True(VoiceLabRenderInput.SupportsVideoRecipe(video));
            Assert.True(VoiceLabNaturalPacing.ValidCuts(video, 48000));
        }
    }

    [Fact]
    public void RenderContractPreparesCutAndMatchVideoRecipesAndFramesThem()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "passage-render-v3.voxclip")));
        var segment = project.VoiceLab.Segments[0]; var first = segment.Candidates[0]; var recipe = first.Recipe!;
        var audio = recipe.Audio with { TrimEnd = .7, Stretch = 1 };
        recipe = recipe with { OutDuration = .6, Audio = audio, Chunks = [recipe.Chunks[0] with { AssembledEndFrame = 16800 }] };
        Project With(VoiceLabVideoRecipe video) => project with { VoiceLab = project.VoiceLab with { Segments = [segment with
        {
            OutDuration = .6, Audio = audio, Candidates = [first with { Recipe = recipe with { Video = video } }, segment.Candidates[1]]
        }] } };
        var cut = recipe.Video with { OutputSamples = 600, Zoom = VoiceLabNaturalPacing.CUT_PUNCH_IN, FaceX = .5, FaceY = .5, Cuts = [new(2800, 2900)] };
        var match = recipe.Video with { Mode = VoiceLabVideoMode.ZoomCover, OutputSamples = 600, RetimeFactor = 700 / 600.0,
            Zoom = VoiceLabVideoDurationOptions.MatchZoom, FaceX = .5, FaceY = .5 };
        cut = cut with { Mode = VoiceLabVideoMode.Cut };
        var cutProject = With(cut);
        VoiceLabProject.Validate(cutProject);
        var prepared = VoiceLabRenderContract.Prepare(cutProject, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        var input = VoiceLabRenderInput.Capture(cutProject, prepared, Path.GetTempPath());
        var synth = input.Framing.Spans.Where(span => span.SourceStartSample >= 2500 && span.SourceEndSample <= 3200).ToArray();
        Assert.Equal([new(2500, 2800, 2500, 2800, 1, .5, .5), new(2900, 3200, 2800, 3100, VoiceLabNaturalPacing.CUT_PUNCH_IN, .5, .5)], synth);
        Assert.Equal(2.9, prepared.OutputPlan.SourceTime(2.8));
        var matchProject = With(match);
        VoiceLabProject.Validate(matchProject);
        var matched = VoiceLabRenderInput.Capture(matchProject,
            VoiceLabRenderContract.Prepare(matchProject, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight), Path.GetTempPath());
        Assert.Contains(new VoiceLabVideoSpan(2500, 3200, 2500, 3100, VoiceLabVideoDurationOptions.MatchZoom, .5, .5), matched.Framing.Spans);
        Assert.All(matched.Framing.Spans.Where(span => span.SourceEndSample <= 2500 || span.SourceStartSample >= 3200), span => Assert.Equal(1, span.Zoom));
        // A cut whose punch-in or edges are wrong never reaches native work.
        var punched = With(cut with { Zoom = 1.12 });
        Assert.Equal(VoiceLabProjectErrorCode.InvalidRange,
            Assert.Throws<VoiceLabProjectException>(() => VoiceLabProject.Validate(punched)).Code);
    }

    private static VoiceLabWindow Window(double seconds) => new("first", "last", [], [], 0, seconds, 0, (long)(seconds * 48_000),
        new(VoiceLabSeamKind.Hard, 0, 0, 240), new(VoiceLabSeamKind.Hard, seconds, (long)(seconds * 48_000), 240));
}
