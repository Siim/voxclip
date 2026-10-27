using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLabPatch;

/// <summary>Shared window-cases.json vectors (tools/fixtures/voice-lab/generate_window.py) and a v3 round trip.</summary>
public sealed class VoiceLabWindowTests
{
    static readonly string[] Categories = ["window", "handles", "trimHandles", "alignment", "trim", "relativeWords", "roomTone", "lendableSilence",
        "propertyCases", "multiSegmentCases"];
    /// <summary>The passage fixture. Its replacement is the template every recipe here starts from.</summary>
    static readonly Lazy<Project> Passage = new(() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip")));

    static JsonElement Document()
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/window-cases.json");
        Assert.Equal("voxclip-voice-lab-window-cases/4", document.RootElement.GetProperty("schema").GetString());
        return document.RootElement.Clone();
    }
    static JsonElement[] Cases(string key) => Document().GetProperty(key).EnumerateArray().ToArray();
    static string Text(JsonElement value, string name) => value.GetProperty(name).GetString()!;
    static double Number(JsonElement value, string name) => value.GetProperty(name).GetDouble();
    static long Integer(JsonElement value, string name) => value.GetProperty(name).GetInt64();
    static string[] Strings(JsonElement value) => value.EnumerateArray().Select(item => item.GetString()!).ToArray();
    static double[]? Numbers(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.EnumerateArray().Select(item => item.GetDouble()).ToArray();
    static TimedWord[] Items(JsonElement value) => value.EnumerateArray().Select(item => new TimedWord(Text(item, "id"), Text(item, "text"),
        Text(item, "kind") switch { "event" => WordKind.Event, "unlabeledSpeech" => WordKind.UnlabeledSpeech, _ => WordKind.Word },
        Number(item, "start"), Number(item, "end"), null, null, null, null, TimingSource.Native)).ToArray();
    static VoiceLabWord[] VoiceWords(JsonElement value) => value.EnumerateArray()
        .Select(word => new VoiceLabWord(Text(word, "text"), Number(word, "start"), Number(word, "end"), word.GetProperty("synthetic").GetBoolean())).ToArray();
    static AudioEnvelope Envelope(JsonElement value) => new(value.GetProperty("sampleRate").GetInt32(), 0.01,
        value.GetProperty("runs").EnumerateArray().SelectMany(run => Enumerable.Repeat(run[0].GetSingle(), run[1].GetInt32())).ToArray());
    static VoiceLabSeamKind Kind(string value) => value switch
    {
        "gap" => VoiceLabSeamKind.Gap, "hard" => VoiceLabSeamKind.Hard, "synthToSynth" => VoiceLabSeamKind.SynthToSynth, _ => VoiceLabSeamKind.None
    };
    static string Name(VoiceLabSeamKind kind) => kind switch
    {
        VoiceLabSeamKind.Gap => "gap", VoiceLabSeamKind.Hard => "hard", VoiceLabSeamKind.SynthToSynth => "synthToSynth", _ => "none"
    };
    static VoiceLabSeam Seam(JsonElement value) => new(Kind(Text(value, "kind")), Integer(value, "fadeSamples"),
        Integer(value, "sourceHandleSamples"), Integer(value, "assetHandleFrames"));
    static VoiceLabSeamPlacement Placement(JsonElement value) => new(Kind(Text(value, "kind")), Number(value, "time"), Integer(value, "sample"),
        Integer(value, "fadeSamples"));
    static VoiceLabWindow Window(JsonElement value) => new(Text(value, "firstWordId"), Text(value, "lastWordId"),
        Strings(value.GetProperty("leftBridgeWordIds")), Strings(value.GetProperty("rightBridgeWordIds")), Number(value, "start"), Number(value, "end"),
        Integer(value, "startSample"), Integer(value, "endSample"), Placement(value.GetProperty("leftSeam")), Placement(value.GetProperty("rightSeam")));
    static VoiceLabRoomTone Tone(JsonElement value) => new(Integer(value, "sourceStartSample"), Integer(value, "sourceEndSample"), Number(value, "gainDb"));
    static string Code(VoiceLabGeometryErrorCode code) => char.ToLowerInvariant(code.ToString()[0]) + code.ToString()[1..];

    /// <summary>Runs one vector: either the typed error it names or a value checked by compare.</summary>
    static void Run<T>(JsonElement test, Func<T> body, Action<T, string> compare)
    {
        var name = Text(test, "name");
        var expected = test.GetProperty("expected");
        if (!expected.TryGetProperty("error", out var error))
        {
            compare(body(), name);
            return;
        }
        var failure = Assert.Throws<VoiceLabGeometryException>(() => (object?)body());
        Assert.True(Code(failure.Code) == error.GetString(), $"{name}: {failure.Code}");
        Assert.True(failure.WordId == (expected.TryGetProperty("wordId", out var id) ? id.GetString() : null), name);
        Assert.True(failure.Incoming == (expected.TryGetProperty("incoming", out var incoming) ? (bool?)incoming.GetBoolean() : null), name);
        Assert.True(failure.Needed == (expected.TryGetProperty("needed", out var needed) ? (long?)needed.GetInt64() : null), name);
        Assert.True(failure.Available == (expected.TryGetProperty("available", out var available) ? (long?)available.GetInt64() : null), name);
        Assert.True(failure.SegmentId == (expected.TryGetProperty("segmentId", out var segment) ? segment.GetString() : null), name);
    }
    static void ExpectWords(IReadOnlyList<VoiceLabWord> words, JsonElement value, string name)
    {
        var expected = value.EnumerateArray().ToArray();
        Assert.True(words.Count == expected.Length, name);
        for (var index = 0; index < words.Count; index++)
        {
            Assert.True(string.Equals(words[index].Text, Text(expected[index], "text"), StringComparison.Ordinal), name);
            Assert.True(words[index].Start == Number(expected[index], "start") && words[index].End == Number(expected[index], "end") && words[index].Synthetic,
                $"{name} {words[index].Text}");
        }
    }

    [Fact]
    public void EveryVectorIsConsumed()
    {
        var document = Document();
        Assert.Equal(Categories.Concat(["schema", "constants", "caseCount", "lendableSilenceFuzz", "propertyFuzz", "multiSegmentFuzz"]).Order(StringComparer.Ordinal),
            document.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal));
        Assert.Equal(document.GetProperty("caseCount").GetInt32(), Categories.Sum(key => Cases(key).Length));
        var constants = document.GetProperty("constants");
        Assert.Equal(VoiceLabPatchConstants.SEAM_MIN_GAP, Number(constants, "SEAM_MIN_GAP"));
        Assert.Equal(VoiceLabPatchConstants.SEAM_SEARCH_WORDS, constants.GetProperty("SEAM_SEARCH_WORDS").GetInt32());
        Assert.Equal(VoiceLabPatchConstants.SEAM_FADE, Number(constants, "SEAM_FADE"));
        Assert.Equal(VoiceLabPatchConstants.HARD_SEAM_FADE, Number(constants, "HARD_SEAM_FADE"));
        Assert.Equal(VoiceLabPatchConstants.TTS_TRIM_LEAD, Number(constants, "TTS_TRIM_LEAD"));
        Assert.Equal(VoiceLabPatchConstants.TTS_TRIM_TAIL, Number(constants, "TTS_TRIM_TAIL"));
        Assert.Equal(VoiceLabPatchConstants.PAUSE_SLACK_KEEP, Number(constants, "PAUSE_SLACK_KEEP"));
        Assert.Equal(VoiceLabPatchConstants.VOICED_FRAME, Number(constants, "VOICED_FRAME"));
        Assert.Equal(VoiceLabPatchConstants.VOICED_FRAME_LEVEL, Number(constants, "VOICED_FRAME_LEVEL"));
        Assert.Equal(VoiceLabPatchConstants.ROOM_TONE_MIN_RUN, Number(constants, "ROOM_TONE_MIN_RUN"));
        Assert.Equal(VoiceLabPatchConstants.RMS_FRAME, Number(constants, "RMS_FRAME"));
    }

    /// <summary>Replays window-shaped cases through Place. Every accepted window must validate and prepare in the case's scope,
    /// beside the take's replacements. A case that carries roomTone selects that room tone and builds a one-word passage
    /// recipe; one without room tone builds a voice-changer recipe, the minimal recipe that needs none.</summary>
    static (int Accepted, int Passages, int Rendered) ReplayWindows(IEnumerable<JsonElement> tests, bool requireLend = false)
    {
        var accepted = 0;
        var passages = 0;
        var rendered = 0;
        foreach (var test in tests)
        {
            var input = test.GetProperty("input");
            var expected = test.GetProperty("expected");
            var tone = test.GetProperty("roomTone");
            var project = Take(input, tone);
            var scope = Scope(input);
            var envelope = Envelope(input.GetProperty("envelope"));
            var rate = Number(input, "sampleRate");
            Run(test, () => input.TryGetProperty("afterWordId", out var after)
                ? VoiceLabWindowPlanner.Place(project, scope, envelope, after.GetString()!)
                : VoiceLabWindowPlanner.Place(project, scope, envelope, Text(input, "firstWordId"), Text(input, "lastWordId")), (window, name) =>
            {
                Assert.True(window.FirstWordId == Text(expected, "firstWordId") && window.LastWordId == Text(expected, "lastWordId"), name);
                Assert.True(window.LeftBridgeWordIds.SequenceEqual(Strings(expected.GetProperty("leftBridgeWordIds"))), name);
                Assert.True(window.RightBridgeWordIds.SequenceEqual(Strings(expected.GetProperty("rightBridgeWordIds"))), name);
                Assert.True(window.Start == Number(expected, "start") && window.End == Number(expected, "end"), name);
                Assert.True(window.StartSample == Integer(expected, "startSample") && window.EndSample == Integer(expected, "endSample"), name);
                foreach (var (placement, raw) in new[] { (window.LeftSeam, expected.GetProperty("leftSeam")), (window.RightSeam, expected.GetProperty("rightSeam")) })
                {
                    Assert.True(placement == Placement(raw), name);
                    Assert.True(EditingMath.Round(placement.Time * rate) == placement.Sample, name);
                }
                accepted++;
                try
                {
                    var silence = VoiceLabWindowPlanner.LendableSilence(project, scope, window);
                    if (requireLend) Assert.True(test.TryGetProperty("lendableSilence", out _), name);
                    if (test.TryGetProperty("lendableSilence", out var lent))
                    {
                        static double? Seconds(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetDouble();
                        Assert.True(silence.Incoming == Seconds(lent.GetProperty("incoming")), name);
                        Assert.True(silence.Outgoing == Seconds(lent.GetProperty("outgoing")), name);
                    }
                    if (tone.ValueKind != JsonValueKind.Object)
                        Assemble(project, window, null, null, 0.5, null, scope);
                    else
                    {
                        var selected = VoiceLabRoomToneSelection.Select(project.Transcript!.Words, envelope, rate,
                            VoiceLabGeometry.Samples(Number(input, "durationSeconds"), rate));
                        Assert.True(selected == Tone(tone), name);
                        var outDuration = (window.EndSample - window.StartSample) / rate;
                        Assemble(project, window, selected, [new VoiceLabWord("patch", 0, outDuration, true)], 0.5, "patch", scope);
                        passages++;
                    }
                    rendered++;
                }
                catch (Exception error) when (error is VoiceLabProjectException or VoiceLabGeometryException)
                {
                    Assert.Fail($"{name} does not render: {error.Message}");
                }
            });
        }
        return (accepted, passages, rendered);
    }

    [Fact]
    public void WindowVectors()
    {
        var (accepted, passages, rendered) = ReplayWindows(Cases("window"));
        Assert.True(passages > 0 && passages < accepted && rendered == accepted, $"{rendered} of {accepted} rendered");
    }

    /// <summary>The committed sample of the property fuzz: every case replays, and every accepted window validates and prepares.</summary>
    [Fact]
    public void PropertyCases()
    {
        var document = Document();
        var fuzz = document.GetProperty("propertyFuzz");
        Assert.True(fuzz.GetProperty("cases").GetInt32() >= 20000 && fuzz.GetProperty("renderFailures").GetInt32() == 0);
        var tests = document.GetProperty("propertyCases").EnumerateArray().ToArray();
        var (accepted, passages, rendered) = ReplayWindows(tests, requireLend: true);
        Assert.Equal(300, tests.Length);
        Assert.True(accepted > 0 && passages == accepted && rendered == accepted, $"{rendered} of {accepted} rendered");
    }

    /// <summary>The committed sample of the multi-segment fuzz: each take already holds one or two replacements that Place put
    /// there, and every accepted window validates and prepares beside them.</summary>
    [Fact]
    public void MultiSegmentCases()
    {
        var document = Document();
        var fuzz = document.GetProperty("multiSegmentFuzz");
        Assert.True(fuzz.GetProperty("cases").GetInt32() >= 20000 && fuzz.GetProperty("renderFailures").GetInt32() == 0);
        var tests = document.GetProperty("multiSegmentCases").EnumerateArray().ToArray();
        var (accepted, passages, rendered) = ReplayWindows(tests, requireLend: true);
        Assert.Equal(150, tests.Length);
        Assert.True(accepted > 0 && passages == accepted && rendered == accepted, $"{rendered} of {accepted} rendered");
        Assert.Contains(tests, test => test.GetProperty("input").GetProperty("segments").EnumerateArray().Any(segment => segment.GetProperty("enabled").GetBoolean()));
    }

    /// <summary>§8.9.2 lendable silence: each case's window places, validates and prepares, and each gap seam lends the kept
    /// source beside it up to the stop the case names. The fuzz widened every accepted window by what its gap seams lend, less
    /// PAUSE_SLACK_KEEP, and every widened window still rendered.</summary>
    [Fact]
    public void LendableSilenceVectors()
    {
        var document = Document();
        var fuzz = document.GetProperty("lendableSilenceFuzz");
        Assert.True(fuzz.GetProperty("windows").GetInt32() >= 20000 && fuzz.GetProperty("lendingSeams").GetInt32() > 0);
        var tests = document.GetProperty("lendableSilence").EnumerateArray().ToArray();
        var (accepted, _, rendered) = ReplayWindows(tests);
        Assert.True(accepted == tests.Length && rendered == accepted, $"{rendered} of {accepted} rendered");
        foreach (var test in tests)
        {
            var input = test.GetProperty("input");
            var expected = test.GetProperty("lendableSilence");
            var name = Text(test, "name");
            var (incoming, outgoing) = VoiceLabWindowPlanner.LendableSilence(Take(input, test.GetProperty("roomTone")), Scope(input),
                Window(test.GetProperty("expected")));
            Assert.True(incoming == Lent(expected.GetProperty("incoming")) && outgoing == Lent(expected.GetProperty("outgoing")), name);
        }
        static double? Lent(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetDouble();
    }

    [Fact]
    public void HandleVectors()
    {
        foreach (var test in Cases("handles"))
        {
            var input = test.GetProperty("input");
            var expected = test.GetProperty("expected");
            var kind = Kind(Text(input, "kind"));
            var fade = Integer(input, "fadeSamples");
            var incoming = input.GetProperty("incoming").GetBoolean();
            var assetRate = input.GetProperty("assetSampleRate").GetInt32();
            var sourceRate = Number(input, "sourceSampleRate");
            var stretch = Number(input, "stretch");
            Run(test, () => (VoiceLabHandles.Minimum(fade, incoming, assetRate, sourceRate, stretch), VoiceLabHandles.Seam(kind, fade, incoming, assetRate, sourceRate, stretch)),
                (result, name) =>
                {
                    Assert.True(result.Item1.AssetFrames == Integer(expected, "assetFrames") && result.Item1.SourceSamples == Integer(expected, "sourceSamples"), name);
                    Assert.True(result.Item2 == Seam(expected.GetProperty("seam")), name);
                });
        }
    }

    [Fact]
    public void TrimHandleVectors()
    {
        foreach (var test in Cases("trimHandles"))
        {
            var input = test.GetProperty("input");
            var seams = input.GetProperty("seams");
            Run(test, () =>
            {
                VoiceLabHandles.CheckTrim(new VoiceLabSeams(Seam(seams.GetProperty("in")), Seam(seams.GetProperty("out"))), Number(input, "trimStart"),
                    Number(input, "trimEnd"), Number(input, "assetDurationSeconds"), input.GetProperty("assetSampleRate").GetInt32());
                return true;
            }, (_, name) => Assert.True(test.GetProperty("expected").GetProperty("ok").GetBoolean(), name));
        }
    }

    [Fact]
    public void AlignmentVectors()
    {
        foreach (var test in Cases("alignment"))
        {
            var input = test.GetProperty("input");
            var characters = input.GetProperty("characters");
            Run(test, () => VoiceLabAlignment.Words(characters.ValueKind == JsonValueKind.Null ? null : Strings(characters),
                Numbers(input.GetProperty("starts")), Numbers(input.GetProperty("ends")), Text(input, "expectedText")),
                (words, name) => ExpectWords(words, test.GetProperty("expected").GetProperty("words"), name));
        }
    }

    [Fact]
    public void TrimVectors()
    {
        foreach (var test in Cases("trim"))
        {
            var input = test.GetProperty("input");
            var expected = test.GetProperty("expected");
            var duration = Number(input, "assetDuration");
            Run(test, () => input.TryGetProperty("envelope", out var envelope)
                ? VoiceLabAlignment.Trim(Envelope(envelope), duration)
                : VoiceLabAlignment.Trim(VoiceWords(input.GetProperty("words")), duration),
                (trim, name) => Assert.True(trim.Start == Number(expected, "start") && trim.End == Number(expected, "end"), name));
        }
    }

    [Fact]
    public void RelativeWordVectors()
    {
        foreach (var test in Cases("relativeWords"))
        {
            var input = test.GetProperty("input");
            Run(test, () => VoiceLabAlignment.RelativeWords(VoiceWords(input.GetProperty("words")), Number(input, "trimStart"), Number(input, "stretch"),
                Number(input, "outDuration"), Number(input, "sourceSampleRate")),
                (words, name) => ExpectWords(words, test.GetProperty("expected").GetProperty("words"), name));
        }
    }

    [Fact]
    public void RoomToneVectors()
    {
        foreach (var test in Cases("roomTone"))
        {
            var input = test.GetProperty("input");
            var expected = test.GetProperty("expected");
            Run(test, () => VoiceLabRoomToneSelection.Select(Items(input.GetProperty("words")), Envelope(input.GetProperty("envelope")),
                Number(input, "sampleRate"), Integer(input, "totalSamples")),
                (tone, name) => Assert.True(tone == new VoiceLabRoomTone(Integer(expected, "sourceStartSample"), Integer(expected, "sourceEndSample"),
                    Number(expected, "gainDb")), name));
        }
    }

    [Fact]
    public void PlacedWindowsFeedFitPlannerAndRenderValidator()
    {
        var kinds = new HashSet<VoiceLabSeamKind>();
        foreach (var test in Cases("lendableSilence"))
        {
            var input = test.GetProperty("input");
            var tone = test.GetProperty("roomTone");
            var project = Take(input, tone);
            var scope = Scope(input);
            var rate = Number(input, "sampleRate");
            var placed = VoiceLabWindowPlanner.Place(project, scope, Envelope(input.GetProperty("envelope")),
                Text(input, "firstWordId"), Text(input, "lastWordId"));
            kinds.UnionWith([placed.LeftSeam.Kind, placed.RightSeam.Kind]);
            var silence = VoiceLabWindowPlanner.LendableSilence(project, scope, placed);
            var take = new VoiceLabFitTake(12000, 24000, 0.02, 0.41,
                [new VoiceLabWord("patch", 0.05, 0.35, true)], new AudioEnvelope(24000, 0.01, Enumerable.Repeat(0.1f, 50).ToArray()));
            var result = VoiceLabFitPlanner.Plan(placed, silence.Incoming, silence.Outgoing, take, ["patch"], rate);
            var plan = result.Plan;
            var duration = plan.WindowEnd - plan.WindowStart;
            if (result is VoiceLabFitResult.ChangedDuration changed) duration = plan.WindowEnd - plan.WindowStart + changed.ResidualSeconds;
            var window = placed with { Start = plan.WindowStart, End = plan.WindowEnd,
                StartSample = plan.WindowStartSample, EndSample = plan.WindowEndSample };
            var words = tone.ValueKind == JsonValueKind.Null ? null : plan.Words;
            var (segment, asset) = PassageSegment(project, "segment-fitted", window, tone.ValueKind == JsonValueKind.Null ? null : Tone(tone), words, 0.5,
                words is null ? null : "patch", plan, duration);
            var built = project with { VoiceLab = project.VoiceLab with
                { Segments = [..project.VoiceLab.Segments, segment], Assets = [..project.VoiceLab.Assets!, asset] } };
            VoiceLabProject.Validate(built);
            var recipe = segment.Candidates[0].Recipe!;
            var broken = segment with { Candidates = [segment.Candidates[0] with
                { Recipe = recipe with { Audio = recipe.Audio with { TrimEnd = recipe.Audio.TrimEnd + 1d / 24000 } } }] };
            var invalid = built with { VoiceLab = built.VoiceLab with { Segments = [..project.VoiceLab.Segments, broken] } };
            Error(VoiceLabProjectErrorCode.InvalidRange, () => VoiceLabRenderValidation.Validate(invalid));
        }
        Assert.True(kinds.SetEquals([VoiceLabSeamKind.None, VoiceLabSeamKind.Gap, VoiceLabSeamKind.Hard]));
    }

    static void Error(VoiceLabProjectErrorCode code, Action action) => Assert.Equal(code, Assert.Throws<VoiceLabProjectException>(action).Code);
    static Project WithRecipe(Project project, VoiceLabRenderRecipe recipe)
    {
        var segment = project.VoiceLab.Segments[0];
        return project with { VoiceLab = project.VoiceLab with { Segments = [segment with { Candidates = [segment.Candidates[0] with { Recipe = recipe }] }] } };
    }

    /// <summary>A five-word patch aligned by the §8.8 loop and placed on the window's output clock, then assembled.</summary>
    static (Project Project, VoiceLabRenderRecipe Recipe, VoiceLabPreparedRender Prepared) PrepareRecipe(Project project, VoiceLabWindow window,
        VoiceLabRoomTone tone, string id = "segment-window")
    {
        double rate = project.Media.Source.Audio!.SampleRate;
        const string patch = "new words uh the clipper.";
        var characters = new List<string>();
        var starts = new List<double>();
        var ends = new List<double>();
        var clock = 0.25;
        foreach (var character in patch)
        {
            characters.Add(character.ToString());
            starts.Add(clock);
            clock += character == ' ' ? 0.02 : 0.09;
            ends.Add(clock);
        }
        var aligned = VoiceLabAlignment.Words(characters, starts, ends, patch);
        Assert.Equal(new[] { "new", "words", "uh", "the", "clipper." }, aligned.Select(word => word.Text));
        var outDuration = (window.EndSample - window.StartSample) / rate;
        var trimStart = VoiceLabAlignment.Trim(aligned, 4).Start;
        var relative = VoiceLabAlignment.RelativeWords(aligned, trimStart, 1, outDuration, rate);
        return Assemble(project, window, tone, relative, trimStart, patch, VoiceLabOutputScope.Full, id);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void MillisecondWindowsFitThroughRenderPreparation(bool atEnd, bool changed)
    {
        const double rate = 44100;
        var project = Passage.Value;
        var words = new List<TimedWord>
        {
            new("w0", "zero", WordKind.Word, 0.7, 1, null, null, null, null, TimingSource.Native),
            new("w1", "one", WordKind.Word, 1.1, 1.4, null, null, null, null, TimingSource.Native),
            new("w2", "two", WordKind.Word, 1.5, 2.1, null, null, null, null, TimingSource.Native),
            new("w3", "before", WordKind.Word, 2.2, 2.5, null, null, null, null, TimingSource.Native),
            new("w4", "old", WordKind.Word, 2.586, 2.75, null, null, null, null, TimingSource.Native),
            new("w5", "words", WordKind.Word, 2.8, 3.113, null, null, null, null, TimingSource.Native),
        };
        if (!atEnd) words.AddRange([
            new("w6", "after", WordKind.Word, 3.2, 3.5, null, null, null, null, TimingSource.Native),
            new("w7", "seven", WordKind.Word, 3.6, 3.8, null, null, null, null, TimingSource.Native),
            new("w8", "eight", WordKind.Word, 3.9, 4.1, null, null, null, null, TimingSource.Native),
            new("w9", "nine", WordKind.Word, 4.2, 4.5, null, null, null, null, TimingSource.Native)]);
        project = project with
        {
            Media = project.Media with { Source = project.Media.Source with { Audio = project.Media.Source.Audio! with { SampleRate = (int)rate }, DurationSeconds = atEnd ? 3.143 : 4.6 } },
            Transcript = project.Transcript! with { Words = words },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Clips = [], ActiveClipId = null },
            VoiceLab = project.VoiceLab with { Segments = [], Assets = [], CleanAudio = new VoiceLabCleanAudio(VoiceLabCleanAudioMode.Off, null, null) },
        };
        var levels = Enumerable.Repeat(0.001f, 60).Concat(Enumerable.Repeat(0.1f, atEnd ? 255 : 400)).ToArray();
        var sourceEnvelope = new AudioEnvelope((int)rate, 0.01, levels);
        var placed = VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, sourceEnvelope, "w4", "w5");
        Assert.Equal(2.556, placed.Start); Assert.Equal(3.143, placed.End);
        Assert.Equal(VoiceLabSeamKind.Hard, placed.LeftSeam.Kind);
        Assert.Equal(atEnd ? VoiceLabSeamKind.None : VoiceLabSeamKind.Hard, placed.RightSeam.Kind);
        var silence = VoiceLabWindowPlanner.LendableSilence(project, VoiceLabOutputScope.Full, placed);
        var take = new VoiceLabFitTake(16800, 24000, 0.02, changed ? 0.62 : 0.52,
            [new VoiceLabWord("patch", 0.05, changed ? 0.56 : 0.45, true)], new AudioEnvelope(24000, 0.01, Enumerable.Repeat(0.1f, 70).ToArray()));
        var result = VoiceLabFitPlanner.Plan(placed, silence.Incoming, silence.Outgoing, take, ["patch"], rate);
        Assert.Equal(changed, result is VoiceLabFitResult.ChangedDuration);
        var fitted = result.Plan;
        var residual = result is VoiceLabFitResult.ChangedDuration partial ? partial.ResidualSeconds : 0;
        var duration = fitted.WindowEnd - fitted.WindowStart + residual;
        var window = placed with { Start = fitted.WindowStart, End = fitted.WindowEnd, StartSample = fitted.WindowStartSample, EndSample = fitted.WindowEndSample };
        var total = VoiceLabGeometry.Samples(project.Media.Source.DurationSeconds, rate);
        var tone = VoiceLabRoomToneSelection.Select(words, sourceEnvelope, rate, total);
        var (segment, asset) = PassageSegment(project, "segment-ms", window, tone, fitted.Words, 0.5, "patch", fitted, duration);
        if (changed)
        {
            var recipe = segment.Candidates[0].Recipe!;
            var factor = (fitted.WindowEndSample - fitted.WindowStartSample) / (double)recipe.Video.OutputSamples;
            recipe = recipe with { Video = recipe.Video with { Mode = VoiceLabVideoMode.ZoomCover, RetimeFactor = factor, Zoom = 1.12, FaceX = 0.5, FaceY = 0.5 } };
            segment = segment with { Candidates = [segment.Candidates[0] with { Recipe = recipe }] };
        }
        project = project with { VoiceLab = project.VoiceLab with { Segments = [segment], Assets = [asset] } };
        VoiceLabProject.Validate(project); VoiceLabRenderValidation.Validate(project);
        var output = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
        var synth = Assert.Single(output.Pieces, piece => piece.Kind == VoiceLabOutputPieceKind.Synth);
        var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
        if (changed)
        {
            Assert.Equal(VoiceLabVideoMode.ZoomCover, Assert.Single(prepared.SelectedSegmentRecipes).Recipe.Video.Mode);
            Assert.Equal(VoiceLabProjectErrorCode.VideoModeUnsupported,
                Assert.Throws<VoiceLabProjectException>(() => VoiceLabRenderInput.Capture(project, prepared, "not-opened")).Code);
        }
        else
        {
            Assert.Equal(synth.SourceEndSample - synth.SourceStartSample, synth.OutputEndSample - synth.OutputStartSample);
            Assert.Equal(VoiceLabVideoMode.Source, Assert.Single(prepared.SelectedSegmentRecipes).Recipe.Video.Mode);
        }
    }

    /// <summary>The selected recipe a candidate would carry for window, built only from the geometry above, as segment id with
    /// its own asset. The asset holds trimStart seconds before the passage and 0.5 s after it. Without words the segment is
    /// a voice changer, which carries no text, words or room tone.</summary>
    static (VoiceLabSegment Segment, VoiceLabAsset Asset) PassageSegment(Project project, string id, VoiceLabWindow window, VoiceLabRoomTone? tone,
        IReadOnlyList<VoiceLabWord>? words, double trimStart, string? patch, VoiceLabFitPlan? fit = null, double? duration = null)
    {
        double rate = project.Media.Source.Audio!.SampleRate;
        var outDuration = duration ?? (window.EndSample - window.StartSample) / rate;
        var frames = fit?.OutputFrames ?? (long)EditingMath.Round((window.EndSample - window.StartSample) * 24000 / rate);
        var trimEnd = (VoiceLabGeometry.Samples(trimStart, 24000) + frames) / 24000d;
        var assetDuration = trimEnd + 0.5;
        var seams = new VoiceLabSeams(
            VoiceLabHandles.Seam(window.LeftSeam.Kind, window.LeftSeam.FadeSamples, true, 24000, rate, 1),
            VoiceLabHandles.Seam(window.RightSeam.Kind, window.RightSeam.FadeSamples, false, 24000, rate, 1));
        VoiceLabHandles.CheckTrim(seams, trimStart, trimEnd, assetDuration, 24000);

        var asset = new VoiceLabAsset("asset-" + id, "audio", project.Id + "/asset-" + id + ".wav", string.Concat(Enumerable.Repeat("ab", 32)),
            assetDuration, 24000, DateTimeOffset.FromUnixTimeSeconds(1793000000));
        var segment = Passage.Value.VoiceLab.Segments[0];
        var recipe = segment.Candidates[0].Recipe!;
        var audio = new VoiceLabAudio(asset.Id, trimStart, trimEnd, 1, 0);
        recipe = recipe with
        {
            Audio = audio,
            Words = words,
            OutDuration = outDuration,
            Chunks = [new VoiceLabChunk(window.StartSample, window.EndSample, "request-" + id, recipe.Seed, asset.Id, asset.Sha256,
                VoiceLabGeometry.Samples(trimStart, 24000), VoiceLabGeometry.Samples(trimEnd, 24000))],
            RoomTone = tone,
            Seams = seams,
            Video = new VoiceLabVideoRecipe(VoiceLabVideoMode.Source, window.StartSample, window.EndSample, VoiceLabGeometry.Samples(outDuration, rate),
                null, null, null, null, null, null, null, null, null, null, null),
            Qa = words is null ? recipe.Qa : recipe.Qa with { TranscriptTokens = words.Count },
        };
        segment = segment with
        {
            Id = id,
            Kind = words is null ? VoiceLabSegmentKind.VoiceChanger : VoiceLabSegmentKind.Tts,
            Replace = new VoiceLabReplacement(window.Start, window.End, window.FirstWordId, window.LastWordId),
            Text = patch is null ? null : new VoiceLabText("we ship uh the clipper.", patch),
            Audio = audio,
            OutDuration = outDuration,
            Words = words,
            Candidates = [new VoiceLabCandidate(asset.Id, 0.9, null) { Recipe = recipe }],
            SelectedCandidateIndex = 0,
        };
        return (segment, asset);
    }

    /// <summary>Adds the recipe for window to the project's replacements as segment id, then validates and prepares the project
    /// in scope.</summary>
    static (Project Project, VoiceLabRenderRecipe Recipe, VoiceLabPreparedRender Prepared) Assemble(Project project, VoiceLabWindow window,
        VoiceLabRoomTone? tone, IReadOnlyList<VoiceLabWord>? words, double trimStart, string? patch, VoiceLabOutputScope scope, string id = "segment-window")
    {
        var (segment, asset) = PassageSegment(project, id, window, tone, words, trimStart, patch);
        project = project with
        {
            VoiceLab = project.VoiceLab with { Assets = [.. project.VoiceLab.Assets ?? [], asset], Segments = [.. project.VoiceLab.Segments, segment] },
        };
        VoiceLabProject.Validate(project);
        return (project, segment.Candidates[0].Recipe!, VoiceLabRenderContract.Prepare(project, scope, VoiceLabLabelPosition.TopLeft));
    }

    /// <summary>10 ms frames at speech level wherever an item overlaps them, room level elsewhere.</summary>
    static float[] Levels(IReadOnlyList<TimedWord> words, long frames) => Enumerable.Range(0, (int)frames)
        .Select(index => words.Any(word => word.Start * 100 < index + 1 && word.End * 100 > index) ? 0.25f : 0.0078125f).ToArray();

    /// <summary>The passage fixture's take at sampleRate, without its replacement and assets.</summary>
    static Project Fixture(int sampleRate)
    {
        var project = Passage.Value;
        var media = project.Media.Source;
        return project with
        {
            Media = project.Media with { Source = media with { Audio = media.Audio! with { SampleRate = sampleRate } } },
            VoiceLab = project.VoiceLab with { Assets = [], Segments = [] },
        };
    }

    /// <summary>A vector's take: the passage fixture with the vector's items, duration, sample rate, edits and replacements.
    /// Each replacement is a one-word passage recipe built from its window with the vector's room tone.</summary>
    static Project Take(JsonElement input, JsonElement tone)
    {
        var project = Fixture(input.GetProperty("sampleRate").GetInt32());
        var edits = input.GetProperty("edits");
        project = project with
        {
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = Number(input, "durationSeconds") } },
            Transcript = project.Transcript! with { Words = Items(input.GetProperty("words")) },
            Edits = project.Edits with
            {
                CutWordIds = Strings(edits.GetProperty("cutWordIds")),
                CutPauseIds = Strings(edits.GetProperty("cutPauseIds")),
                PauseThresholdSeconds = Number(edits, "pauseThresholdSeconds"),
                PauseKeepSeconds = Number(edits, "pauseKeepSeconds"),
                Clips = edits.GetProperty("clips").EnumerateArray().Select(clip => new ClipRange(Text(clip, "id"), Text(clip, "startWordId"),
                    Text(clip, "endWordId"), null, ClipOrigin.Manual, null, null, true)).ToArray(),
                ActiveClipId = null,
            },
        };
        foreach (var raw in input.GetProperty("segments").EnumerateArray())
        {
            var placed = Window(raw.GetProperty("window"));
            var outDuration = (placed.EndSample - placed.StartSample) / Number(input, "sampleRate");
            var (segment, asset) = PassageSegment(project, Text(raw, "id"), placed, Tone(tone), [new VoiceLabWord("patch", 0, outDuration, true)], 0.5, "patch");
            project = project with
            {
                VoiceLab = project.VoiceLab with
                {
                    Assets = [.. project.VoiceLab.Assets ?? [], asset],
                    Segments = [.. project.VoiceLab.Segments, segment with { Enabled = raw.GetProperty("enabled").GetBoolean() }],
                },
            };
        }
        return project;
    }

    /// <summary>The render scope a vector names: its clipId, or the full take.</summary>
    static VoiceLabOutputScope Scope(JsonElement input) => input.GetProperty("clipId").ValueKind == JsonValueKind.Null
        ? VoiceLabOutputScope.Full : VoiceLabOutputScope.Clip(Text(input, "clipId"));

    /// <summary>A passage recipe built only from the geometry above validates and prepares; one short handle is refused.</summary>
    [Fact]
    public void BuiltRecipeValidatesAndPrepares()
    {
        var project = Fixture(48000);
        const double rate = 48000;
        var duration = project.Media.Source.DurationSeconds;
        var total = VoiceLabGeometry.Samples(duration, rate);
        var words = project.Transcript!.Words;
        var levels = Levels(words, total / 480);
        levels[230] = 0.0009765625f;
        levels[480] = 0.0009765625f;
        for (var index = 600; index < 650; index++) levels[index] = 0.00048828125f;
        var envelope = new AudioEnvelope(48000, 0.01, levels);
        // The fixture's own replacement covers w4..w5: a window over it is refused, not stored beside it.
        var original = Passage.Value with { Media = project.Media };
        var overlap = Assert.Throws<VoiceLabGeometryException>(() => VoiceLabWindowPlanner.Place(original, VoiceLabOutputScope.Full, envelope, "w4", "w5"));
        Assert.Equal((VoiceLabGeometryErrorCode.OverlapsReplacement, "vl-passage"), (overlap.Code, overlap.SegmentId));
        var window = VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, envelope, "w4", "w5");
        Assert.Equal(230 * 480 + 240, window.StartSample);
        Assert.Equal(480 * 480 + 240, window.EndSample);
        Assert.Empty(window.LeftBridgeWordIds);
        Assert.Equal(new[] { "w6", "w7", "w8" }, window.RightBridgeWordIds);
        Assert.Equal("w8", window.LastWordId);
        var tone = VoiceLabRoomToneSelection.Select(words, envelope, rate, total);
        Assert.Equal(new VoiceLabRoomTone(600 * 480, 650 * 480, 0), tone);
        var (built, recipe, prepared) = PrepareRecipe(project, window, tone);
        var seams = recipe.Seams;
        Assert.Equal(new VoiceLabSeam(VoiceLabSeamKind.Gap, 960, 480, 240), seams.In);
        Assert.Single(prepared.SelectedSegmentRecipes);
        Assert.Equal(total, prepared.OutputPlan.OutputSamples);
        var broken = WithRecipe(built, recipe with { Seams = seams with { In = seams.In with { AssetHandleFrames = seams.In.AssetHandleFrames - 1 } } });
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabProject.Validate(broken));
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabRenderContract.Prepare(broken, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft));
        broken = WithRecipe(built, recipe with { Seams = seams with { Out = seams.Out with { SourceHandleSamples = seams.Out.SourceHandleSamples - 1 } } });
        Error(VoiceLabProjectErrorCode.InvalidFadeHandles, () => VoiceLabProject.Validate(broken));
    }

    /// <summary>Re-voicing the sentences before and after an accepted replacement. Each new window keeps its fade clear of the
    /// replacement's own, and the project holding all three validates and prepares.</summary>
    [Fact]
    public void NeighbourRecipesValidateAndPrepare()
    {
        var project = Fixture(48000);
        const double rate = 48000;
        var total = VoiceLabGeometry.Samples(project.Media.Source.DurationSeconds, rate);
        var words = project.Transcript!.Words;
        var levels = Levels(words, total / 480);
        levels[230] = 0.0009765625f;
        levels[480] = 0.0009765625f;
        for (var index = 600; index < 650; index++) levels[index] = 0.00048828125f;
        var envelope = new AudioEnvelope(48000, 0.01, levels);
        var tone = VoiceLabRoomToneSelection.Select(words, envelope, rate, total);
        var accepted = VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, envelope, "w4", "w5");
        var withAccepted = PrepareRecipe(project, accepted, tone, "segment-accepted").Project;
        var after = VoiceLabWindowPlanner.Place(withAccepted, VoiceLabOutputScope.Full, envelope, "w9", "w9");
        Assert.True(after.LeftSeam.Kind == VoiceLabSeamKind.Gap && after.StartSample >= accepted.EndSample + 960);
        var withAfter = PrepareRecipe(withAccepted, after, tone, "segment-after").Project;
        var before = VoiceLabWindowPlanner.Place(withAfter, VoiceLabOutputScope.Full, envelope, "w3", "w3");
        Assert.True(before.RightSeam.Kind == VoiceLabSeamKind.Gap && before.EndSample + 960 <= accepted.StartSample);
        var prepared = PrepareRecipe(withAfter, before, tone, "segment-before").Prepared;
        Assert.Equal(new[] { "segment-before", "segment-accepted", "segment-after" }, prepared.SelectedSegmentRecipes.Select(item => item.SegmentId));
        // Placed again on its own words, the accepted passage now overlaps itself.
        var overlap = Assert.Throws<VoiceLabGeometryException>(() => VoiceLabWindowPlanner.Place(withAfter, VoiceLabOutputScope.Full, envelope, "w6", "w7"));
        Assert.Equal((VoiceLabGeometryErrorCode.OverlapsReplacement, "segment-accepted"), (overlap.Code, overlap.SegmentId));
    }

    /// <summary>An edit after acceptance: cutting the pause after w8 removes the kept source after the accepted replacement's
    /// seam, so its fade now crosses the cut, and prepare still renders it. Re-voicing w1 is judged on its own and renders
    /// beside it.</summary>
    [Fact]
    public void CutAfterAcceptanceRecipeValidatesAndPrepares()
    {
        var project = Fixture(48000);
        const double rate = 48000;
        var total = VoiceLabGeometry.Samples(project.Media.Source.DurationSeconds, rate);
        var words = project.Transcript!.Words;
        var levels = Levels(words, total / 480);
        levels[230] = 0.0009765625f;
        levels[480] = 0.0009765625f;
        for (var index = 600; index < 650; index++) levels[index] = 0.00048828125f;
        var envelope = new AudioEnvelope(48000, 0.01, levels);
        var tone = VoiceLabRoomToneSelection.Select(words, envelope, rate, total);
        var accepted = VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, envelope, "w4", "w5");
        var withAccepted = PrepareRecipe(project, accepted, tone, "segment-accepted").Project;
        withAccepted = withAccepted with { Edits = withAccepted.Edits with { CutPauseIds = ["pause-after-w8"] } };
        var alone = VoiceLabRenderContract.Prepare(withAccepted, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopLeft).OutputPlan.Pieces;
        Assert.Equal(new[] { 0, accepted.StartSample, 256800L }, alone.Select(piece => piece.SourceStartSample));
        var first = VoiceLabWindowPlanner.Place(withAccepted, VoiceLabOutputScope.Full, envelope, "w1", "w1");
        Assert.Equal((0L, 98160L), (first.StartSample, first.EndSample));
        var pieces = PrepareRecipe(withAccepted, first, tone, "segment-first").Prepared.OutputPlan.Pieces;
        Assert.Equal(new[] { VoiceLabOutputPieceKind.Synth, VoiceLabOutputPieceKind.Source, VoiceLabOutputPieceKind.Synth, VoiceLabOutputPieceKind.Source },
            pieces.Select(piece => piece.Kind));
        Assert.Equal(new[] { 0, 98160, accepted.StartSample, 256800L }, pieces.Select(piece => piece.SourceStartSample));
    }

    /// <summary>A whole take whose duration is off the 44.1 kHz grid: both seams are None, at 0 and exactly at durationSeconds.</summary>
    [Fact]
    public void TakeEdgeRecipeValidatesAndPrepares()
    {
        const double rate = 44100;
        const double duration = 1237.0 / 600.0;
        var total = VoiceLabGeometry.Samples(duration, rate);
        Assert.True(total == 90920 && total / rate > duration);
        TimedWord Word(string id, string text, double start, double end) => new(id, text, WordKind.Word, start, end, null, null, null, null, TimingSource.Native);
        var project = Fixture(44100);
        project = project with
        {
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = duration } },
            Transcript = project.Transcript! with { Words = [Word("w1", "we", 0, 0.6), Word("w2", "ship", 1.2, 1.5), Word("w3", "it", 1.6, duration)] },
            Edits = project.Edits with { Clips = [], ActiveClipId = null },
        };
        var words = project.Transcript!.Words;
        var envelope = new AudioEnvelope(44100, 0.01, Levels(words, total / 441));
        var window = VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, envelope, "w1", "w3");
        Assert.Equal(new VoiceLabSeamPlacement(VoiceLabSeamKind.None, 0, 0, 0), window.LeftSeam);
        Assert.Equal(new VoiceLabSeamPlacement(VoiceLabSeamKind.None, duration, total, 0), window.RightSeam);
        var tone = VoiceLabRoomToneSelection.Select(words, envelope, rate, total);
        var prepared = PrepareRecipe(project, window, tone).Prepared;
        Assert.Single(prepared.OutputPlan.Pieces);
        Assert.Equal(total, prepared.OutputPlan.OutputSamples);
    }

    /// <summary>A cut word next to the window. Its quietest frame would fade into the cut's reach, so the seam takes the next
    /// frame, and the kept source between the cut and the seam still holds half the fade.</summary>
    [Fact]
    public void CutNeighbourRecipeValidatesAndPrepares()
    {
        var project = Fixture(48000);
        project = project with { Edits = project.Edits with { CutWordIds = ["w3"] } };
        const double rate = 48000;
        var duration = project.Media.Source.DurationSeconds;
        var total = VoiceLabGeometry.Samples(duration, rate);
        var words = project.Transcript!.Words;
        var levels = Levels(words, total / 480);
        levels[160] = 0.00048828125f;
        levels[161] = 0.0009765625f;
        levels[480] = 0.0009765625f;
        for (var index = 600; index < 650; index++) levels[index] = 0.00048828125f;
        var envelope = new AudioEnvelope(48000, 0.01, levels);
        var window = VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, envelope, "w4", "w5");
        // w3's cut reaches 0.1 s past 1.5 s, to sample 76800; frame 160's fade would start 240 samples inside it.
        Assert.Equal(161 * 480 + 240, window.StartSample);
        var tone = VoiceLabRoomToneSelection.Select(words, envelope, rate, total);
        var pieces = PrepareRecipe(project, window, tone).Prepared.OutputPlan.Pieces;
        var synth = pieces.ToList().FindIndex(piece => piece.Kind == VoiceLabOutputPieceKind.Synth);
        Assert.Equal((76800L, window.StartSample), (pieces[synth - 1].SourceStartSample, pieces[synth - 1].SourceEndSample));
    }

    /// <summary>The core use: a cut filler at 0.0 s before a rewrite of the first sentence. The window absorbs the filler and
    /// starts at the take start, so no fade crosses the cut and the synth is the first output piece.</summary>
    [Fact]
    public void CutFillerAtTakeStartRecipeValidatesAndPrepares()
    {
        var project = Fixture(48000);
        project = project with
        {
            Transcript = project.Transcript! with
            {
                Words = [new TimedWord("um", "um", WordKind.Word, 0, 0.25, null, null, null, null, TimingSource.Native), .. project.Transcript!.Words],
            },
            Edits = project.Edits with { CutWordIds = ["um"] },
        };
        const double rate = 48000;
        var total = VoiceLabGeometry.Samples(project.Media.Source.DurationSeconds, rate);
        var words = project.Transcript!.Words;
        var envelope = new AudioEnvelope(48000, 0.01, Levels(words, total / 480));
        var window = VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, envelope, "w1", "w2");
        Assert.Equal(new VoiceLabSeamPlacement(VoiceLabSeamKind.None, 0, 0, 0), window.LeftSeam);
        Assert.Equal("um", window.FirstWordId);
        Assert.Empty(window.LeftBridgeWordIds);
        Assert.Equal(new[] { "w3" }, window.RightBridgeWordIds);
        var tone = VoiceLabRoomToneSelection.Select(words, envelope, rate, total);
        var first = PrepareRecipe(project, window, tone).Prepared.OutputPlan.Pieces[0];
        Assert.Equal((VoiceLabOutputPieceKind.Synth, 0L, window.EndSample), (first.Kind, first.SourceStartSample, first.SourceEndSample));
    }

    /// <summary>A .NET string can hold a lone surrogate, which the shared vectors cannot carry. It is a mismatch in a provider
    /// character and in the patch text, found by decoding rather than by Normalize throwing.</summary>
    [Fact]
    public void LoneSurrogatesAreAMismatch()
    {
        var high = ((char)0xd800).ToString();
        var low = ((char)0xdc00).ToString();
        void Mismatch(string[] characters, string expected)
        {
            var times = Enumerable.Range(0, characters.Length).Select(index => 0.1 + 0.05 * index).ToArray();
            var failure = Assert.Throws<VoiceLabGeometryException>(() => VoiceLabAlignment.Words(characters, times, times.Select(time => time + 0.05).ToArray(), expected));
            Assert.Equal(VoiceLabGeometryErrorCode.AlignmentMismatch, failure.Code);
        }
        Mismatch(["a", "b", high], "ab");
        Mismatch(["a", "b"], "ab" + high);
        Mismatch(["a", low, "b"], "a" + low + "b");
        Mismatch(["a", high + "b"], "a" + high + "b");
        Assert.Equal(2, VoiceLabAlignment.Words(["a", "b", " ", char.ConvertFromUtf32(0x1f600)], [0.1, 0.2, 0.3, 0.3], [0.2, 0.3, 0.3, 0.4],
            "ab " + char.ConvertFromUtf32(0x1f600)).Count);
    }

    [Fact]
    public void InsertionAndInvalidInputAreTyped()
    {
        TimedWord Word(string id, double start, double end) => new(id, id, WordKind.Word, start, end, null, null, null, null, TimingSource.Native);
        TimedWord[] words = [Word("w1", 0.2, 0.5), Word("w2", 0.7, 0.9)];
        var project = Fixture(1000);
        project = project with
        {
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 1 } },
            Transcript = project.Transcript! with { Words = words },
        };
        var envelope = new AudioEnvelope(1000, 0.01, Enumerable.Repeat(0.01f, 100).ToArray());
        void Expect(VoiceLabGeometryErrorCode code, Action action) => Assert.Equal(code, Assert.Throws<VoiceLabGeometryException>(action).Code);
        Expect(VoiceLabGeometryErrorCode.InsertionUnsupported, () => VoiceLabWindowPlanner.Place(project, VoiceLabOutputScope.Full, envelope, "w1"));
        Project[] invalid =
        [
            project with { Transcript = project.Transcript! with { Words = [.. words, Word("w1", 0.95, 0.99)] } },
            project with { Edits = project.Edits with { PauseThresholdSeconds = 0 } },
            project with { Edits = project.Edits with { PauseKeepSeconds = 1.5 } },
            // The project transcript rule: starts in order and every item longer than zero.
            project with { Transcript = project.Transcript! with { Words = [.. words, Word("w3", 0.6, 0.99)] } },
            project with { Transcript = project.Transcript! with { Words = [.. words, Word("w3", 0.95, 0.95)] } },
        ];
        foreach (var take in invalid)
            Expect(VoiceLabGeometryErrorCode.InvalidInput, () => VoiceLabWindowPlanner.Place(take, VoiceLabOutputScope.Full, envelope, "w2", "w2"));
        // An unknown clip, and the fixture's clip, whose words this take does not have.
        foreach (var scope in new[] { VoiceLabOutputScope.Clip("missing"), VoiceLabOutputScope.Clip("clip-main") })
            Expect(VoiceLabGeometryErrorCode.InvalidInput, () => VoiceLabWindowPlanner.Place(project, scope, envelope, "w2", "w2"));
        Expect(VoiceLabGeometryErrorCode.InvalidInput, () => VoiceLabRoomToneSelection.Select(words, new AudioEnvelope(1000, 0.01, []), 1000, 1000));
        Expect(VoiceLabGeometryErrorCode.InvalidInput, () => VoiceLabHandles.Minimum(20, true, 24000, 1000, double.NaN));
        Expect(VoiceLabGeometryErrorCode.InvalidInput, () => VoiceLabHandles.Seam((VoiceLabSeamKind)99, 20, true, 24000, 1000, 1));
        Expect(VoiceLabGeometryErrorCode.AlignmentUnavailable, () => VoiceLabAlignment.RelativeWords([], 0, 1, 1, 1000));
        Assert.Equal("õ", EditingAlgorithms.NormalizeForMatch("Õ,"));
    }
}
