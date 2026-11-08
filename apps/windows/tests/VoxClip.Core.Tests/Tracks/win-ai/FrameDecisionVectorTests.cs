using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The frame decisions of ADR-R48 ("Claude sees the picture"), twin of the Mac <c>FrameDecisionVectorTests</c>: every case of
/// shared/fixtures/clip-frames/decision-cases.json, which tools/fixtures/clip-frames/generate_frame_decisions.py writes. Inputs are
/// read and answers written in the Mac's JSON shape, compared with numbers within 1e-12.</summary>
[Trait("Track", "win-ai")]
public sealed class FrameDecisionVectorTests
{
    private const string Path = "fixtures/clip-frames/decision-cases.json";
    private static readonly Lazy<JsonObject> Vectors = new(() => JsonNode.Parse(FixtureLoader.ReadText(Path))!.AsObject());
    private static IEnumerable<JsonObject> Rows(string key) => Vectors.Value[key]!.AsArray().Select(row => row!.AsObject());
    private static string Id(JsonObject row) => row["id"]!.GetValue<string>();
    private static double? Baseline(JsonObject row) => row["pitchBaseline"]?.GetValue<double>();
    private static FrameObservation Frame(JsonNode? node) => FrameJson.ReadObservation(node) ?? throw new InvalidDataException("not an observation: " + node?.ToJsonString());
    private static FrameObservation[] Frames(JsonNode? node) => node!.AsArray().Select(Frame).ToArray();
    private static ClipEffectRect Rect(JsonNode? node) => FrameJson.ReadRect(node) ?? throw new InvalidDataException("not a rect");

    internal static TimedWord[] Words(JsonNode? node) => node!.AsArray().Select(item => new TimedWord(item!["id"]!.GetValue<string>(),
        item["text"]!.GetValue<string>(), item["kind"]!.GetValue<string>() == "event" ? WordKind.Event : WordKind.Word,
        item["start"]!.GetValue<double>(), item["end"]!.GetValue<double>(), null, null, null, null, TimingSource.Native)).ToArray();

    private static FrameClip Clip(TimedWord[] words, JsonObject row) =>
        FrameClip.Make(words, row["first"]!.GetValue<int>(), row["last"]!.GetValue<int>(),
            row["cut"]!.AsArray().Select(id => id!.GetValue<string>()).ToHashSet()) ?? throw new InvalidDataException("no clip");

    [Fact]
    public void TheFileHasItsSchemaKeysAndCount()
    {
        var root = Vectors.Value;
        string[] sections = ["eyes", "looks", "openings", "covers", "crops", "screens", "blurSpans", "summaries", "imageTokens", "samplings", "openingTimes", "decimals"];
        Assert.Equal(new[] { "schema", "description", "constants", "caseCount", "counts", "transcripts" }.Concat(sections).Append("analysis"), root.Select(pair => pair.Key));
        Assert.Equal("voxclip-frame-decision-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(136, root["caseCount"]!.GetValue<int>());
        Assert.Equal(sections, root["counts"]!.AsObject().Select(pair => pair.Key));
        Assert.Equal(new[] { 11, 11, 22, 11, 11, 12, 7, 6, 6, 9, 6, 24 }, sections.Select(key => root[key]!.AsArray().Count));
        Assert.All(sections, key => Assert.Equal(root[key]!.AsArray().Count, root["counts"]![key]!.GetValue<int>()));
        Assert.Equal(136, sections.Sum(key => root[key]!.AsArray().Count));
        Assert.Equal(new[] { "thirty-sentences", "run-on", "mixed", "empty" }, root["transcripts"]!.AsObject().Select(pair => pair.Key));
    }

    [Fact]
    public void TheConstantsAreTheCores()
    {
        var constants = Vectors.Value["constants"]!.AsObject();
        var expected = new Dictionary<string, double>
        {
            ["closedBelow"] = EyeAspect.ClosedBelow, ["goodQuality"] = FrameFace.GoodQuality, ["yawLimit"] = FrameFace.YawLimit,
            ["pitchLimit"] = FrameFace.PitchLimit, ["startTolerance"] = OpeningFrame.StartTolerance, ["qualityMargin"] = OpeningFrame.QualityMargin,
            ["openingSpan"] = FrameSampling.OpeningSpan, ["openingStep"] = FrameSampling.OpeningStep, ["deadZone"] = FaceFollowCrop.DeadZone,
            ["maximumSpeed"] = FaceFollowCrop.MaximumSpeed, ["medianWindow"] = FaceFollowCrop.MedianWindow, ["blinkWindow"] = CoverFrame.BlinkWindow,
            ["qualityWeight"] = CoverFrame.QualityWeight, ["centredWeight"] = CoverFrame.CentredWeight, ["eyesWeight"] = CoverFrame.EyesWeight,
            ["facingWeight"] = CoverFrame.FacingWeight, ["minimumBoxes"] = FrameScreens.MinimumBoxes, ["minimumCoverage"] = FrameScreens.MinimumCoverage,
            ["minimumArea"] = FrameScreens.MinimumArea, ["clusterBoxes"] = FrameScreens.ClusterBoxes, ["minimumOverlap"] = FrameBlurSpans.MinimumOverlap,
            ["blurMaxGap"] = ClipFrameCandidates.BlurMaxGap, ["blurPad"] = ClipFrameCandidates.BlurPad, ["maximumCovers"] = ClipFrameCandidates.MaximumCovers,
            ["maximumSentences"] = FrameSampling.MaximumSentences, ["maximumSentenceWords"] = FrameSampling.MaximumSentenceWords,
            ["pixelsPerToken"] = FrameSheet.PixelsPerToken,
        };
        Assert.Equal(expected.Keys, constants.Select(pair => pair.Key));
        foreach (var (key, value) in expected) Assert.True(value == constants[key]!.GetValue<double>(), key);
    }

    [Fact]
    public void EyesReplay()
    {
        foreach (var row in Rows("eyes"))
        {
            var expect = row["expect"];
            if (row["kind"]!.GetValue<string>() == "ratio")
            {
                var points = row["points"]!.AsArray().Select(point => (point![0]!.GetValue<double>(), point[1]!.GetValue<double>())).ToArray();
                var ratio = EyeAspect.Ratio(points);
                Assert.True(expect is null ? ratio is null : ratio == expect.GetValue<double>(), Id(row));
            }
            else
            {
                var state = EyeAspect.State(row["left"]?.GetValue<double>(), row["right"]?.GetValue<double>());
                Assert.True(expect!.GetValue<string>() == FrameJson.EyesName(state), Id(row));
            }
        }
    }

    [Fact]
    public void LooksReplay()
    {
        foreach (var row in Rows("looks"))
        {
            var frame = Frame(row["frame"]);
            var expect = row["expect"]!;
            Assert.True(expect["clearLook"]!.GetValue<bool>() == frame.IsClearLook(Baseline(row)), Id(row));
            Assert.True(expect["facing"]?.GetValue<bool>() == frame.Face?.FacesCamera(Baseline(row)), Id(row));
        }
    }

    [Fact]
    public void OpeningsReplay()
    {
        foreach (var row in Rows("openings"))
        {
            var clip = Clip(Words(row["words"]), row);
            var expect = row["expect"]!;
            var shape = new JsonObject
            {
                ["start"] = clip.Start, ["end"] = clip.End, ["leadInFloor"] = clip.LeadInFloor, ["kept"] = new JsonArray([.. clip.Kept.Select(index => (JsonNode)index)]),
            };
            AssertJson(expect["clip"], shape, Id(row) + " clip");
            var choice = OpeningFrame.Choose(clip, Frames(row["scan"]), Baseline(row));
            AssertJson(expect["choice"], choice is null ? null : FrameJson.Write(choice), Id(row));
        }
    }

    [Fact]
    public void CoversReplay()
    {
        foreach (var row in Rows("covers"))
        {
            var frames = Frames(row["frames"]);
            var baseline = Baseline(row);
            var expect = row["expect"]!;
            var scores = new JsonArray([.. frames.Select(frame => CoverFrame.Score(frame, frames, baseline) is { } score ? JsonValue.Create(score) : null)]);
            AssertJson(expect["scores"], scores, Id(row) + " scores");
            AssertJson(expect["pick"], CoverFrame.Pick(frames, baseline) is { } pick ? FrameJson.Write(pick) : null, Id(row) + " pick");
            var sheet = frames.Select((frame, index) => new FrameSheetFrame(index + 1, frame, [], 320, 180)).ToArray();
            AssertJson(expect["candidates"], FrameJson.Array(ClipFrameCandidates.Cover(sheet, baseline).Select(FrameJson.Write)), Id(row) + " candidates");
        }
    }

    [Fact]
    public void CropsReplay()
    {
        foreach (var row in Rows("crops"))
        {
            var samples = row["samples"]!.AsArray().Select(sample =>
                new FaceFollowSample(sample!["time"]!.GetValue<double>(), sample["face"] is { } face ? Rect(face) : null)).ToArray();
            var plan = FaceFollowCrop.Plan(samples, row["sourceAspect"]!.GetValue<double>(), row["targetAspect"]!.GetValue<double>());
            AssertJson(row["expect"], plan is null ? null : FrameJson.Write(plan), Id(row));
        }
    }

    [Fact]
    public void ScreensReplay()
    {
        foreach (var row in Rows("screens"))
        {
            var screens = FrameScreens.Detect(row["rectangles"]!.AsArray().Select(Rect).ToArray(), row["texts"]!.AsArray().Select(Rect).ToArray());
            AssertJson(row["expect"], FrameJson.Array(screens.Select(FrameJson.Write)), Id(row));
        }
    }

    [Fact]
    public void BlurSpansReplay()
    {
        foreach (var row in Rows("blurSpans"))
        {
            var frames = Frames(row["frames"]);
            var spans = FrameBlurSpans.Merge(frames, row["maxGap"]!.GetValue<double>(), row["pad"]!.GetValue<double>());
            AssertJson(row["expect"]!["spans"], FrameJson.Array(spans.Select(FrameJson.Write)), Id(row) + " spans");
            var candidates = ClipFrameCandidates.Blur(frames, row["clipStart"]!.GetValue<double>(), row["clipEnd"]!.GetValue<double>());
            AssertJson(row["expect"]!["candidates"], FrameJson.Array(candidates.Select(FrameJson.Write)), Id(row) + " candidates");
        }
    }

    [Fact]
    public void SummariesReplay()
    {
        foreach (var row in Rows("summaries"))
        {
            var sheet = new FrameSheet(Frames(row["frames"]).Select((frame, index) => new FrameSheetFrame(index + 1, frame, [1, 2, 3], 320, 180)));
            Assert.Equal(row["expect"]!["summary"]!.GetValue<string>(), sheet.Summary(Baseline(row)));
            Assert.True(row["expect"]!["summaryTokens"]!.GetValue<int>() == sheet.EstimatedSummaryTokens(Baseline(row)), Id(row));
            Assert.True(sheet.Frames.Count <= FrameSheet.MaximumFrames, Id(row));
        }
        foreach (var row in Rows("imageTokens"))
            Assert.Equal(row["expect"]!.GetValue<int>(), FrameSheet.ImageTokens(row["width"]!.GetValue<int>(), row["height"]!.GetValue<int>()));
    }

    [Fact]
    public void SamplingsReplay()
    {
        var transcripts = Vectors.Value["transcripts"]!.AsObject();
        foreach (var (name, transcript) in transcripts)
            AssertJson(transcript!["video"], FrameJson.Array(FrameSampling.VideoSamples(Words(transcript["words"])).Select(FrameJson.Write)), name + " video");
        foreach (var row in Rows("samplings"))
        {
            var transcript = transcripts[row["transcript"]!.GetValue<string>()]!;
            var clip = Clip(Words(transcript["words"]), row);
            var limit = row["limit"]!.GetValue<int>();
            var video = FrameSampling.VideoSamples(clip.Words);
            AssertJson(row["expect"]!["sentences"], FrameJson.Array(FrameSampling.SentenceSamples(clip, limit).Select(FrameJson.Write)), Id(row) + " sentences");
            AssertJson(row["expect"]!["clip"], FrameJson.Array(FrameSampling.ClipSamples(video, clip, limit).Select(FrameJson.Write)), Id(row) + " clip");
        }
        foreach (var row in Rows("openingTimes"))
            AssertJson(row["expect"], new JsonArray([.. FrameSampling.OpeningTimes(row["start"]!.GetValue<double>()).Select(time => (JsonNode)time)]), "opening times");
    }

    /// <summary>Numbers in the summary and the frames block: the Mac's two decimals, not printf's, "F2"'s or "0.00"'s.</summary>
    [Fact]
    public void DecimalsAreTheMacs()
    {
        foreach (var row in Rows("decimals"))
        {
            var value = row["value"]!.GetValue<double>();
            Assert.True(row["expect"]!.GetValue<string>() == FrameSheetFrame.Fixed(value), $"{value:R} -> {FrameSheetFrame.Fixed(value)}");
            Assert.Equal(FrameSheetFrame.Fixed(value), VoxClip.Core.Domain.Autopilot.ClipAutopilotFrames.Seconds(value));
        }
        Assert.Equal("0.250", FrameAnalysisFile.Pass(0.25));
        Assert.Equal("0.033", FrameAnalysisFile.Pass(1.0 / 30));
    }

    /// <summary>The Mac's analysis-v2.json reads into C# and writes back with the same keys and values; so does a clip's analysis.</summary>
    [Fact]
    public void AnAnalysisFileRoundTripsWithTheMacsKeysAndValues()
    {
        var sample = Vectors.Value["analysis"]!.AsObject();
        Assert.Equal(new[] { "fileName", "file", "frameAnalysis", "pitchBaseline" }, sample.Select(pair => pair.Key));
        Assert.Equal(FrameAnalysisFile.FileName, sample["fileName"]!.GetValue<string>());
        Assert.Equal(FrameAnalysisFile.SchemaId, sample["file"]!["schema"]!.GetValue<string>());
        var text = sample["file"]!.ToJsonString();
        var frames = FrameAnalysisFile.Read(text);
        Assert.Equal(sample["file"]!["frames"]!.AsObject().Count, frames.Count);
        var written = JsonNode.Parse(FrameAnalysisFile.Write(frames));
        AssertJson(sample["file"], written, "analysis-v2.json");
        Assert.Equal(FrameAnalysisFile.Write(frames), FrameAnalysisFile.Write(FrameAnalysisFile.Read(FrameAnalysisFile.Write(frames))));
        // The stored eyes are kept as read, as the Mac's decoder keeps them.
        Assert.Equal(FrameEyes.Closed, frames["0.250:4750"].Face!.Eyes);
        var stored = FrameJson.ReadFace(JsonNode.Parse("""{"rect":{"x":0.4,"y":0.3,"width":0.2,"height":0.4},"leftEyeAspect":0.1,"rightEyeAspect":0.1,"eyes":"open"}"""));
        Assert.Equal(FrameEyes.Open, stored!.Eyes);
        Assert.Null(frames["0.250:15250"].Face);
        Assert.Equal("0.250:1250", FrameAnalysisFile.Key(FrameAnalysisFile.Pass(0.25), 1.25));

        var analysis = FrameJson.ReadAnalysis(sample["frameAnalysis"]) ?? throw new InvalidDataException("no analysis");
        AssertJson(sample["frameAnalysis"], FrameJson.Write(analysis), "frameAnalysis");
        Assert.Equal(FrameAnalysis.CurrentVersion, analysis.Version);
        Assert.Equal(sample["pitchBaseline"]!.GetValue<double>(), analysis.PitchBaseline);

        // Another version's file, or one unreadable observation, reads as nothing (the Mac's decoder refuses the whole file).
        var other = sample["file"]!.DeepClone().AsObject();
        other["schema"] = "voxclip-frames/1";
        Assert.Empty(FrameAnalysisFile.Read(other.ToJsonString()));
        var broken = sample["file"]!.DeepClone().AsObject();
        broken["frames"]!["0.250:1250"]!.AsObject().Remove("textRects");
        Assert.Empty(FrameAnalysisFile.Read(broken.ToJsonString()));
        Assert.Empty(FrameAnalysisFile.Read("not json"));
    }

    /// <summary>The plan request's frames (shared/fixtures/autopilot/plan-frames-cases.json) come out of the decisions: its summary,
    /// its blur candidates and its cover order from the observations the decision vectors measure.</summary>
    [Fact]
    public void ThePlanRequestFramesComeFromTheDecisions()
    {
        var plan = JsonNode.Parse(FixtureLoader.ReadText("fixtures/autopilot/plan-frames-cases.json"))!["frames"]!;
        var frames = Frames(Rows("summaries").Single(row => Id(row) == "the-plan-request-summary")["frames"]);
        var sheet = new FrameSheet(frames.Select((frame, index) => new FrameSheetFrame(index + 1, frame, [], 320, 180)));
        Assert.Equal(plan["summary"]!.GetValue<string>(), sheet.Summary(null));
        var blur = ClipFrameCandidates.Blur(frames, 0, 15);
        Assert.Equal(plan["blur"]!.AsArray().Select(item => (item!["id"]!.GetValue<string>(), item["start"]!.GetValue<double>(), item["end"]!.GetValue<double>(), item["frames"]!.GetValue<int>())),
            blur.Select(candidate => (candidate.Id, candidate.Start, candidate.End, candidate.Frames)));
        foreach (var (candidate, item) in blur.Zip(plan["blur"]!.AsArray()))
        {
            var box = item!["rect"]!.AsArray().Select(value => value!.GetValue<double>()).ToArray();
            Assert.True(Math.Abs(candidate.Rect.X - box[0]) < 1e-9 && Math.Abs(candidate.Rect.Y - box[1]) < 1e-9 && Math.Abs(candidate.Rect.Width - box[2]) < 1e-9 && Math.Abs(candidate.Rect.Height - box[3]) < 1e-9, candidate.Id);
        }
        Assert.Equal(plan["cover"]!.AsArray().Select(item => (item!["id"]!.GetValue<string>(), item["frame"]!.GetValue<int>(), item["time"]!.GetValue<double>())),
            ClipFrameCandidates.Cover(sheet.Frames, null).Select(candidate => (candidate.Id, candidate.Frame, candidate.Time)));
    }

    /// <summary>Equal JSON: the same keys (in any order), arrays of the same length, equal strings and booleans, numbers within 1e-12.</summary>
    internal static void AssertJson(JsonNode? expected, JsonNode? actual, string where)
    {
        if (expected is null || actual is null)
        {
            Assert.True(expected is null && actual is null, $"{where}: {expected?.ToJsonString() ?? "null"} != {actual?.ToJsonString() ?? "null"}");
            return;
        }
        switch (expected)
        {
            case JsonObject expectedObject:
                var actualObject = Assert.IsType<JsonObject>(actual);
                Assert.True(expectedObject.Select(pair => pair.Key).Order(StringComparer.Ordinal).SequenceEqual(actualObject.Select(pair => pair.Key).Order(StringComparer.Ordinal)),
                    $"{where}: keys {expected.ToJsonString()} != {actual.ToJsonString()}");
                foreach (var (key, value) in expectedObject) AssertJson(value, actualObject[key], $"{where}.{key}");
                break;
            case JsonArray expectedArray:
                var actualArray = Assert.IsType<JsonArray>(actual);
                Assert.True(expectedArray.Count == actualArray.Count, $"{where}: {expectedArray.Count} items != {actualArray.Count}: {actual.ToJsonString()}");
                for (var index = 0; index < expectedArray.Count; index++) AssertJson(expectedArray[index], actualArray[index], $"{where}[{index}]");
                break;
            default:
                var kind = expected.GetValueKind();
                Assert.True(kind == actual.GetValueKind(), $"{where}: {expected.ToJsonString()} != {actual.ToJsonString()}");
                if (kind == JsonValueKind.Number)
                    Assert.True(Math.Abs(FrameJson.AsDouble(expected.AsValue())!.Value - FrameJson.AsDouble(actual.AsValue())!.Value) <= 1e-12, $"{where}: {expected.ToJsonString()} != {actual.ToJsonString()}");
                else
                    Assert.True(expected.ToJsonString() == actual.ToJsonString(), $"{where}: {expected.ToJsonString()} != {actual.ToJsonString()}");
                break;
        }
    }
}

/// <summary>Replays shared/fixtures/clip-frames/face-facing-cases.json (ADR-R48 "Face pose"), twin of the Mac
/// <c>FaceFacingVectorTests</c>: the recording's typical pitch and facing the camera against it.</summary>
[Trait("Track", "win-ai")]
public sealed class FaceFacingVectorTests
{
    private static readonly Lazy<JsonObject> Cases = new(() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/clip-frames/face-facing-cases.json"))!.AsObject());
    private static readonly ClipEffectRect Centred = new(0.4, 0.3, 0.2, 0.4);

    [Fact]
    public void TheFileHasItsFormatKeysCountsAndLimits()
    {
        var cases = Cases.Value;
        Assert.Equal(new[] { "format", "description", "yawLimit", "pitchLimit", "baseline", "facing" }, cases.Select(pair => pair.Key));
        Assert.Equal("voxclip-face-facing-cases/1", cases["format"]!.GetValue<string>());
        Assert.Equal(FrameFace.YawLimit, cases["yawLimit"]!.GetValue<double>());
        Assert.Equal(FrameFace.PitchLimit, cases["pitchLimit"]!.GetValue<double>());
        Assert.Equal(6, cases["baseline"]!.AsArray().Count);
        Assert.Equal(14, cases["facing"]!.AsArray().Count);
    }

    [Fact]
    public void BaselinesReplay()
    {
        foreach (var row in Cases.Value["baseline"]!.AsArray())
        {
            var frames = row!["pitches"]!.AsArray().Select((pitch, index) =>
                new FrameObservation(index) { FaceCount = 1, Face = new FrameFace(Centred, yaw: 0, pitch: pitch?.GetValue<double>()) });
            Assert.True(row["expect"]?.GetValue<double>() == FrameFace.PitchBaseline(frames), row["id"]!.GetValue<string>());
        }
    }

    [Fact]
    public void FacingReplays()
    {
        foreach (var row in Cases.Value["facing"]!.AsArray())
        {
            var face = new FrameFace(Centred, yaw: row!["yaw"]?.GetValue<double>(), pitch: row["pitch"]?.GetValue<double>());
            Assert.True(row["expect"]?.GetValue<bool>() == face.FacesCamera(row["pitchBaseline"]?.GetValue<double>()), row["id"]!.GetValue<string>());
        }
    }
}
