using System.Text;
using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLabPatch;

public sealed class VoiceLabWindowAllTests
{
    static readonly Lazy<Project> Passage = new(() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip")));

    static JsonElement Document()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/window-all-cases.json");
        return document.RootElement.Clone();
    }

    public static TheoryData<string> Cases
    {
        get
        {
            TheoryData<string> cases = [];
            foreach (var test in Document().GetProperty("cases").EnumerateArray()) cases.Add(Text(test, "name"));
            return cases;
        }
    }

    [Fact]
    public void EveryVectorIsConsumed()
    {
        var document = Document();
        Assert.Equal(new[] { "caseCount", "cases", "schema" }, document.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal));
        ExactText("voxclip-voice-lab-window-all-cases/1", Text(document, "schema"));
        var cases = document.GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(32, document.GetProperty("caseCount").GetInt32());
        Assert.Equal(32, cases.Length);
        Assert.Equal(32, Cases.Count);
        Assert.Equal(32, cases.Select(test => Text(test, "name")).Distinct(StringComparer.Ordinal).Count());
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void SharedPlaceAllVector(string name)
    {
        var test = Document().GetProperty("cases").EnumerateArray().Single(test => Text(test, "name") == name);
        var input = test.GetProperty("input");
        var project = Take(input, test.GetProperty("roomTone"));
        var before = JsonSerializer.SerializeToUtf8Bytes(project);
        var hunks = input.GetProperty("hunks").EnumerateArray().Select(Hunk).ToArray();
        var scope = input.GetProperty("clipId").ValueKind == JsonValueKind.Null ? VoiceLabOutputScope.Full : VoiceLabOutputScope.Clip(Text(input, "clipId"));
        var rawEnvelope = input.GetProperty("envelope");
        var envelope = new AudioEnvelope(rawEnvelope.GetProperty("sampleRate").GetInt32(), 0.01,
            rawEnvelope.GetProperty("runs").EnumerateArray().SelectMany(run => Enumerable.Repeat(run[0].GetSingle(), run[1].GetInt32())).ToArray());
        var results = VoiceLabWindowPlanner.PlaceAll(project, scope, envelope, hunks);
        Assert.Equal(before, JsonSerializer.SerializeToUtf8Bytes(project));
        var expected = test.GetProperty("expected").EnumerateArray().ToArray();
        Assert.True(results.Count == expected.Length, name);
        var rendered = project with
        {
            Edits = project.Edits with { CutWordIds = [.. project.Edits.CutWordIds, .. hunks.Where(hunk => hunk.Kind == VoiceLabDiffHunkKind.Cut).SelectMany(hunk => hunk.SourceWordIds)] },
        };
        long? lastEnd = null;
        for (int position = 0; position < results.Count; position++)
        {
            var raw = expected[position];
            var indices = raw.GetProperty("indices").EnumerateArray().Select(index => index.GetInt32()).ToArray();
            if (Text(raw, "status") == "placed")
            {
                var placed = Assert.IsType<PlacedOrRefused.Placed>(results[position]);
                Assert.Equal(indices, placed.Indices);
                ExactHunk(Hunk(raw.GetProperty("hunk")), placed.Hunk);
                ExactWindow(raw.GetProperty("window"), placed.Window);
                Assert.True(lastEnd is null || lastEnd < placed.Window.StartSample, name);
                lastEnd = placed.Window.EndSample;
                rendered = AddWindow(rendered, "all-" + indices[0], placed.Window, null, true, false);
                VoiceLabProject.Validate(rendered);
                _ = VoiceLabRenderContract.Prepare(rendered, scope, VoiceLabLabelPosition.TopLeft);
            }
            else
            {
                var refused = Assert.IsType<PlacedOrRefused.Refused>(results[position]);
                Assert.Equal(new[] { refused.Index }, indices);
                Assert.Same(hunks[refused.Index], refused.Hunk);
                ExactHunk(Hunk(raw.GetProperty("hunk")), refused.Hunk);
                var reason = raw.GetProperty("reason");
                if (Text(reason, "error") == "collidesWithChange")
                {
                    var collision = Assert.IsType<VoiceLabWindowRefusal.CollidesWithChange>(refused.Reason);
                    Assert.Equal(reason.GetProperty("index").GetInt32(), collision.Index);
                    ExactText("Too close to the change before it to voice separately. Edit them together or leave one out.", collision.Copy!);
                }
                else
                {
                    var error = Assert.IsType<VoiceLabWindowRefusal.Geometry>(refused.Reason).Error;
                    ExactText(Text(reason, "error"), char.ToLowerInvariant(error.Code.ToString()[0]) + error.Code.ToString()[1..]);
                    Assert.Equal(Optional(reason, "wordId", value => value.GetString()), error.WordId);
                    Assert.Equal(Optional(reason, "segmentId", value => value.GetString()), error.SegmentId);
                    Assert.Equal(Optional<bool?>(reason, "incoming", value => value.GetBoolean()), error.Incoming);
                    Assert.Equal(Optional<bool?>(reason, "takeEdgeIsStart", value => value.GetBoolean()), error.TakeEdgeIsStart);
                    Assert.Equal(Optional<long?>(reason, "needed", value => value.GetInt64()), error.Needed);
                    Assert.Equal(Optional<long?>(reason, "available", value => value.GetInt64()), error.Available);
                    Assert.Null(refused.Reason.Copy);
                }
            }
        }
    }

    static string Text(JsonElement value, string key) => value.GetProperty(key).GetString()!;
    static double Number(JsonElement value, string key) => value.GetProperty(key).GetDouble();
    static long Integer(JsonElement value, string key) => value.GetProperty(key).GetInt64();
    static string[] Strings(JsonElement value) => value.EnumerateArray().Select(item => item.GetString()!).ToArray();
    static TResult? Optional<TResult>(JsonElement value, string key, Func<JsonElement, TResult> read)
        => value.TryGetProperty(key, out var item) && item.ValueKind != JsonValueKind.Null ? read(item) : default;
    static void ExactText(string expected, string actual) => Assert.Equal(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(actual));
    static void ExactDouble(double expected, double actual) => Assert.Equal(BitConverter.DoubleToInt64Bits(expected), BitConverter.DoubleToInt64Bits(actual));
    static VoiceLabSeamKind Kind(string value) => value switch { "gap" => VoiceLabSeamKind.Gap, "hard" => VoiceLabSeamKind.Hard, _ => VoiceLabSeamKind.None };
    static VoiceLabSeamPlacement Placement(JsonElement value) => new(Kind(Text(value, "kind")), Number(value, "time"), Integer(value, "sample"), Integer(value, "fadeSamples"));
    static VoiceLabWindow Window(JsonElement value) => new(Text(value, "firstWordId"), Text(value, "lastWordId"), Strings(value.GetProperty("leftBridgeWordIds")),
        Strings(value.GetProperty("rightBridgeWordIds")), Number(value, "start"), Number(value, "end"), Integer(value, "startSample"), Integer(value, "endSample"),
        Placement(value.GetProperty("leftSeam")), Placement(value.GetProperty("rightSeam")));
    static VoiceLabDiffHunk Hunk(JsonElement value) => new(Text(value, "kind") switch
        { "cut" => VoiceLabDiffHunkKind.Cut, "textOnly" => VoiceLabDiffHunkKind.TextOnly, _ => VoiceLabDiffHunkKind.Voice },
        Strings(value.GetProperty("sourceWordIds")), Strings(value.GetProperty("newTokens")), Strings(value.GetProperty("correctedTexts")),
        Strings(value.GetProperty("absorbedItemIds")), Strings(value.GetProperty("bridgeWordIds")), value.GetProperty("sourceStartIndex").GetInt32(),
        value.GetProperty("sourceEndIndex").GetInt32(), Optional<double?>(value, "anchorSeconds", item => item.GetDouble()));

    static void ExactHunk(VoiceLabDiffHunk expected, VoiceLabDiffHunk actual)
    {
        Assert.Equal(expected.Kind, actual.Kind);
        Assert.Equal(expected.SourceWordIds, actual.SourceWordIds);
        Assert.Equal(expected.NewTokens, actual.NewTokens);
        Assert.Equal(expected.CorrectedTexts, actual.CorrectedTexts);
        Assert.Equal(expected.AbsorbedItemIds, actual.AbsorbedItemIds);
        Assert.Equal(expected.BridgeWordIds, actual.BridgeWordIds);
        Assert.Equal(expected.SourceStartIndex, actual.SourceStartIndex);
        Assert.Equal(expected.SourceEndIndex, actual.SourceEndIndex);
        Assert.Equal(expected.AnchorSeconds is null, actual.AnchorSeconds is null);
        if (expected.AnchorSeconds is { } anchor) ExactDouble(anchor, actual.AnchorSeconds!.Value);
    }

    static void ExactWindow(JsonElement raw, VoiceLabWindow actual)
    {
        var expected = Window(raw);
        ExactText(expected.FirstWordId, actual.FirstWordId);
        ExactText(expected.LastWordId, actual.LastWordId);
        Assert.Equal(expected.LeftBridgeWordIds, actual.LeftBridgeWordIds);
        Assert.Equal(expected.RightBridgeWordIds, actual.RightBridgeWordIds);
        ExactDouble(expected.Start, actual.Start);
        ExactDouble(expected.End, actual.End);
        Assert.Equal(expected.StartSample, actual.StartSample);
        Assert.Equal(expected.EndSample, actual.EndSample);
        foreach (var (expectedSeam, actualSeam) in new[] { (expected.LeftSeam, actual.LeftSeam), (expected.RightSeam, actual.RightSeam) })
        {
            Assert.Equal(expectedSeam.Kind, actualSeam.Kind);
            ExactDouble(expectedSeam.Time, actualSeam.Time);
            Assert.Equal(expectedSeam.Sample, actualSeam.Sample);
            Assert.Equal(expectedSeam.FadeSamples, actualSeam.FadeSamples);
        }
    }

    static Project Take(JsonElement input, JsonElement tone)
    {
        var project = Passage.Value;
        var edits = input.GetProperty("edits");
        project = project with
        {
            Media = project.Media with { Source = project.Media.Source with
            {
                DurationSeconds = Number(input, "durationSeconds"),
                Audio = project.Media.Source.Audio! with { SampleRate = input.GetProperty("sampleRate").GetInt32() },
            } },
            Transcript = project.Transcript! with { Words = input.GetProperty("words").EnumerateArray().Select(word => new TimedWord(Text(word, "id"), Text(word, "text"),
                Text(word, "kind") switch { "event" => WordKind.Event, "unlabeledSpeech" => WordKind.UnlabeledSpeech, _ => WordKind.Word },
                Number(word, "start"), Number(word, "end"), null, null, null, null, TimingSource.Native)).ToArray() },
            Edits = project.Edits with
            {
                CutWordIds = Strings(edits.GetProperty("cutWordIds")), CutPauseIds = Strings(edits.GetProperty("cutPauseIds")),
                PauseThresholdSeconds = Number(edits, "pauseThresholdSeconds"), PauseKeepSeconds = Number(edits, "pauseKeepSeconds"),
                Corrections = edits.TryGetProperty("corrections", out var corrections)
                    ? corrections.EnumerateObject().ToDictionary(pair => pair.Name, pair => pair.Value.GetString()!, StringComparer.Ordinal) : new Dictionary<string, string>(),
                Clips = edits.GetProperty("clips").EnumerateArray().Select(clip => new ClipRange(Text(clip, "id"), Text(clip, "startWordId"), Text(clip, "endWordId"),
                    null, ClipOrigin.Manual, null, null, true)).ToArray(), ActiveClipId = null,
            },
            VoiceLab = project.VoiceLab with { Segments = [], Assets = [] },
        };
        VoiceLabRoomTone? roomTone = tone.ValueKind == JsonValueKind.Null ? null
            : new VoiceLabRoomTone(Integer(tone, "sourceStartSample"), Integer(tone, "sourceEndSample"), Number(tone, "gainDb"));
        foreach (var segment in input.GetProperty("segments").EnumerateArray())
            project = AddWindow(project, Text(segment, "id"), Window(segment.GetProperty("window")), roomTone, segment.GetProperty("enabled").GetBoolean(), true);
        return project;
    }

    static Project AddWindow(Project project, string id, VoiceLabWindow window, VoiceLabRoomTone? roomTone, bool enabled, bool existing)
    {
        double rate = project.Media.Source.Audio!.SampleRate;
        double duration = (window.EndSample - window.StartSample) / rate;
        long frames = (long)EditingMath.Round((window.EndSample - window.StartSample) * 24000 / rate);
        double trimEnd = (12000 + frames) / 24000d;
        var asset = new VoiceLabAsset("asset-" + id, "audio", project.Id + "/asset-" + id + ".wav", string.Concat(Enumerable.Repeat("ab", 32)),
            trimEnd + 0.5, 24000, DateTimeOffset.FromUnixTimeSeconds(1793000000));
        var audio = new VoiceLabAudio(asset.Id, 0.5, trimEnd, 1, 0);
        var template = Passage.Value.VoiceLab.Segments[0];
        var recipe = template.Candidates[0].Recipe! with
        {
            Audio = audio, OutDuration = duration, Words = existing ? [new VoiceLabWord("patch", 0, duration, true)] : null,
            Chunks = [new VoiceLabChunk(window.StartSample, window.EndSample, "request-" + id, template.Candidates[0].Recipe!.Seed, asset.Id, asset.Sha256, 12000, 12000 + frames)],
            RoomTone = roomTone,
            Seams = new VoiceLabSeams(VoiceLabHandles.Seam(window.LeftSeam.Kind, window.LeftSeam.FadeSamples, true, 24000, rate, 1),
                VoiceLabHandles.Seam(window.RightSeam.Kind, window.RightSeam.FadeSamples, false, 24000, rate, 1)),
            Video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Source, window.StartSample, window.EndSample, (long)EditingMath.Round(duration * rate),
                null, null, null, null, null, null, null, null, null, null, null),
            Qa = existing ? template.Candidates[0].Recipe!.Qa with { TranscriptTokens = 1 } : template.Candidates[0].Recipe!.Qa,
        };
        var segment = template with
        {
            Id = id, Kind = existing ? VoiceLabSegmentKind.Tts : VoiceLabSegmentKind.VoiceChanger, Enabled = enabled,
            Replace = new VoiceLabReplacement(window.Start, window.End, window.FirstWordId, window.LastWordId), OutDuration = duration,
            Text = existing ? new VoiceLabText("we ship uh the clipper.", "patch") : null, Audio = audio, Words = recipe.Words,
            Candidates = [new VoiceLabCandidate(asset.Id, 0.9, null) { Recipe = recipe }], SelectedCandidateIndex = 0,
        };
        return project with { VoiceLab = project.VoiceLab with { Assets = [.. project.VoiceLab.Assets ?? [], asset], Segments = [.. project.VoiceLab.Segments, segment] } };
    }
}
