using System.Text.Json;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLabPatch;

/// <summary>Shared fit-cases.json vectors (tools/fixtures/voice-lab/generate_fit.py, run by generate.py): every named and property
/// case, each with the §8.9.2 properties checked again on the plan this Core returns. Words are [text, start, end], envelope runs
/// [level, count] and edits [kind, start, count].</summary>
public sealed class VoiceLabFitPlannerTests
{
    static readonly Lazy<JsonElement> Document = new(() =>
    {
        using var document = FixtureLoader.ReadJson("fixtures/voice-lab/fit-cases.json");
        return document.RootElement.Clone();
    });

    [Fact]
    public void EveryAcceptedPlanBuildsAUnityRenderRecipe()
    {
        var template = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/passage-render-v3.voxclip"));
        var accepted = 0;
        foreach (var test in Cases("cases").Concat(Cases("propertyCases")))
        {
            if (test.GetProperty("expected").TryGetProperty("error", out _)) continue;
            var input = test.GetProperty("input");
            var result = Plan(input);
            var fitted = result.Plan;
            var duration = fitted.WindowEnd - fitted.WindowStart;
            if (result is VoiceLabFitResult.ChangedDuration changed) duration = fitted.WindowEnd - fitted.WindowStart + changed.ResidualSeconds;
            var rate = Number(input, "sourceSampleRate");
            var assetRate = input.GetProperty("take").GetProperty("assetSampleRate").GetInt32();
            var placed = Window(input);
            var sourceOffset = Math.Max(0, placed.LeftSeam.FadeSamples / 2 - fitted.WindowStartSample);
            var sourceStartSample = fitted.WindowStartSample + sourceOffset;
            var sourceEndSample = fitted.WindowEndSample + sourceOffset;
            var sourceStart = sourceStartSample / rate; var sourceEnd = sourceEndSample / rate;
            var trimStartFrame = assetRate / 2;
            var trimStart = trimStartFrame / (double)assetRate;
            var trimEnd = (trimStartFrame + fitted.OutputFrames) / (double)assetRate;
            var asset = new VoiceLabAsset("asset-fitted", "audio", template.Id + "/asset-fitted.wav", string.Concat(Enumerable.Repeat("ab", 32)),
                trimEnd + 0.5, assetRate, DateTimeOffset.FromUnixTimeSeconds(1793000000));
            var segment = template.VoiceLab.Segments[0];
            var recipe = segment.Candidates[0].Recipe!;
            recipe = recipe with
            {
                Audio = new VoiceLabAudio(asset.Id, trimStart, trimEnd, 1, 0), OutDuration = duration, Words = fitted.Words, RoomTone = null,
                Qa = recipe.Qa with { TranscriptTokens = fitted.Words.Count, TranscriptExact = true },
                Chunks = [new VoiceLabChunk(sourceStartSample, sourceEndSample, "request-fitted", recipe.Seed, asset.Id, asset.Sha256,
                    trimStartFrame, trimStartFrame + fitted.OutputFrames)],
                Seams = new VoiceLabSeams(
                    VoiceLabHandles.Seam(placed.LeftSeam.Kind, placed.LeftSeam.FadeSamples, true, assetRate, rate, 1),
                    VoiceLabHandles.Seam(placed.RightSeam.Kind, placed.RightSeam.FadeSamples, false, assetRate, rate, 1)),
                Video = recipe.Video with { SourceStartSample = sourceStartSample, SourceEndSample = sourceEndSample,
                    OutputSamples = VoiceLabGeometry.Samples(duration, rate) },
            };
            var atEnd = placed.RightSeam.Kind == VoiceLabSeamKind.None;
            var shortFullTake = atEnd && sourceStartSample == 0 && sourceEnd <= 0.5;
            var firstSourceTime = atEnd && !shortFullTake ? Math.Max(0.5, sourceStart) : sourceStart;
            var sourceSpan = sourceEnd - firstSourceTime;
            var originalStart = firstSourceTime + sourceSpan / 3;
            var originalEnd = firstSourceTime + sourceSpan * 2 / 3;
            if (!shortFullTake)
            {
                long toneStart = atEnd ? 0 : sourceEndSample;
                recipe = recipe with { RoomTone = new VoiceLabRoomTone(toneStart, toneStart + VoiceLabGeometry.Samples(0.5, rate), 0) };
            }
            IReadOnlyList<VoiceLabVideoAsset> videos = [];
            if (result is VoiceLabFitResult.ChangedDuration)
            {
                recipe = recipe with { Video = recipe.Video with { Mode = VoiceLabVideoMode.Lipsync, AssetId = "video-fitted", Provider = "sync", Model = "lipsync-2",
                    RequestId = "request-fitted-video", SyncMode = "remap", WindowStartSample = sourceStartSample, WindowEndSample = sourceEndSample } };
                videos = [new VoiceLabVideoAsset("video-fitted", template.Id + "/video-fitted.mp4", asset.Sha256, duration + 1, 30, 640, 360)];
            }
            segment = segment with { Replace = new VoiceLabReplacement(sourceStart, sourceEnd, "word-fitted-source", "word-fitted-source"),
                Scope = shortFullTake ? VoiceLabSegmentScope.FullTake : VoiceLabSegmentScope.Passage, GroupId = shortFullTake ? "group-fitted" : null,
                Audio = recipe.Audio, OutDuration = duration, Words = fitted.Words,
                Candidates = [new VoiceLabCandidate(asset.Id, 0.9, null) { Recipe = recipe }] };
            var project = template with
            {
                Media = template.Media with { Source = template.Media.Source with { Audio = template.Media.Source.Audio! with { SampleRate = (int)rate },
                    DurationSeconds = placed.RightSeam.Kind == VoiceLabSeamKind.None ? sourceEnd : sourceEnd + 1 } },
                Transcript = template.Transcript! with { Words = [new TimedWord("word-fitted-source", "source", WordKind.Word, originalStart, originalEnd, null, null, null, null, TimingSource.Native)] },
                Edits = template.Edits with { Clips = [], ActiveClipId = null },
                VoiceLab = template.VoiceLab with { Assets = [asset], Segments = [segment], VideoAssets = videos,
                    CleanAudio = new VoiceLabCleanAudio(VoiceLabCleanAudioMode.Off, null, null) },
            };
            var error = Record.Exception(() =>
            {
                VoiceLabProject.Validate(project); VoiceLabRenderValidation.Validate(project);
                var output = VoiceLabOutputPlanner.Build(project, VoiceLabOutputScope.Full);
                var prepared = VoiceLabRenderContract.Prepare(project, VoiceLabOutputScope.Full, VoiceLabLabelPosition.TopRight);
                Assert.Equal(output.OutputSamples, prepared.OutputPlan.OutputSamples);
                Assert.Equal(output.Pieces, prepared.OutputPlan.Pieces);
                if (result is VoiceLabFitResult.Exact)
                {
                    Assert.Equal(VoiceLabVideoMode.Source, Assert.Single(prepared.SelectedSegmentRecipes).Recipe.Video.Mode);
                }
                else
                {
                    Assert.Equal(VoiceLabVideoMode.Lipsync, Assert.Single(prepared.SelectedSegmentRecipes).Recipe.Video.Mode);
                    Assert.Equal(VoiceLabProjectErrorCode.VideoModeUnsupported,
                        Assert.Throws<VoiceLabProjectException>(() => VoiceLabRenderInput.Capture(project, prepared, "not-opened")).Code);
                }
            });
            Assert.True(error is null, $"{Text(test, "name")}: fitted recipe refused: {error}");
            accepted++;
        }
        Assert.Equal(Cases("cases").Concat(Cases("propertyCases")).Count(test => !test.GetProperty("expected").TryGetProperty("error", out _)), accepted);
    }

    static JsonElement[] Cases(string key) => Document.Value.GetProperty(key).EnumerateArray().ToArray();
    static JsonElement Case(string name) => Cases("cases").Single(test => Text(test, "name") == name);
    static string Text(JsonElement value, string name) => value.GetProperty(name).GetString()!;
    static double Number(JsonElement value, string name) => value.GetProperty(name).GetDouble();
    static long Integer(JsonElement value, string name) => value.GetProperty(name).GetInt64();
    static string[] Strings(JsonElement value) => value.EnumerateArray().Select(item => item.GetString()!).ToArray();
    static double? Silence(JsonElement input, string name)
        => input.GetProperty(name).ValueKind == JsonValueKind.Null ? null : input.GetProperty(name).GetDouble();
    static (long, long) Pair(JsonElement value, string name) => (value.GetProperty(name)[0].GetInt64(), value.GetProperty(name)[1].GetInt64());
    static VoiceLabSeamKind Kind(string value) => value switch
    {
        "gap" => VoiceLabSeamKind.Gap, "hard" => VoiceLabSeamKind.Hard, "synthToSynth" => VoiceLabSeamKind.SynthToSynth, _ => VoiceLabSeamKind.None
    };
    static string Name(VoiceLabFitEditKind kind) => kind == VoiceLabFitEditKind.Insert ? "insert" : "remove";
    static string Code(VoiceLabGeometryErrorCode code) => char.ToLowerInvariant(code.ToString()[0]) + code.ToString()[1..];

    /// <summary>The placed window: each seam's fade follows its kind, and the times default to the samples on the source grid.</summary>
    static VoiceLabWindow Window(JsonElement input)
    {
        var rate = Number(input, "sourceSampleRate");
        var value = input.GetProperty("window");
        var startSample = Integer(value, "startSample");
        var endSample = Integer(value, "endSample");
        var start = value.TryGetProperty("start", out var startTime) ? startTime.GetDouble() : startSample / rate;
        var end = value.TryGetProperty("end", out var endTime) ? endTime.GetDouble() : endSample / rate;
        VoiceLabSeamPlacement Seam(string name, long sample, double time)
        {
            var kind = Kind(name);
            var fade = kind switch
            {
                VoiceLabSeamKind.Gap => VoiceLabGeometry.Samples(VoiceLabPatchConstants.SEAM_FADE, rate),
                VoiceLabSeamKind.Hard => VoiceLabGeometry.Samples(VoiceLabPatchConstants.HARD_SEAM_FADE, rate),
                _ => 0
            };
            return new(kind, time, sample, fade);
        }
        return new("w0", "w0", [], [], start, end, startSample, endSample, Seam(Text(value, "leftKind"), startSample, start),
            Seam(Text(value, "rightKind"), endSample, end));
    }

    /// <summary>The take. Provider words arrive unmarked, so every replay shows that the planner marks its words synthetic.</summary>
    static VoiceLabFitTake Take(JsonElement input)
    {
        var value = input.GetProperty("take");
        var envelope = value.GetProperty("envelope");
        var levels = envelope.GetProperty("runs").EnumerateArray()
            .SelectMany(run => Enumerable.Repeat((float)run[0].GetDouble(), run[1].GetInt32())).ToArray();
        var words = value.GetProperty("words").EnumerateArray()
            .Select(word => new VoiceLabWord(word[0].GetString()!, word[1].GetDouble(), word[2].GetDouble(), false)).ToArray();
        return new(Integer(value, "assetFrames"), value.GetProperty("assetSampleRate").GetInt32(), Number(value, "trimStart"),
            Number(value, "trimEnd"), words, new AudioEnvelope(envelope.GetProperty("sampleRate").GetInt32(), VoiceLabPatchConstants.RMS_FRAME, levels));
    }

    static VoiceLabFitResult Plan(JsonElement input) => VoiceLabFitPlanner.Plan(Window(input), Silence(input, "incomingSilence"),
        Silence(input, "outgoingSilence"), Take(input), Strings(input.GetProperty("tokens")), Number(input, "sourceSampleRate"));

    /// <summary>Replays one vector: its typed refusal, or its plan field by field. Named vectors also carry the window times and word
    /// times; property cases leave them to the formulas CheckProperties applies to every plan.</summary>
    static void Replay(JsonElement test)
    {
        var name = Text(test, "name");
        var input = test.GetProperty("input");
        var expected = test.GetProperty("expected");
        VoiceLabFitResult result;
        try
        {
            result = Plan(input);
        }
        catch (VoiceLabGeometryException failure)
        {
            Assert.True(expected.TryGetProperty("error", out var error) && Code(failure.Code) == error.GetString(), $"{name}: {failure.Code}");
            return;
        }
        Assert.False(expected.TryGetProperty("error", out var refusal), $"{name}: expected {refusal}");
        var plan = result.Plan;
        Assert.Equal($"{name}: {Text(expected, "result")}", $"{name}: {(result is VoiceLabFitResult.Exact ? "exact" : "changedDuration")}");
        if (result is VoiceLabFitResult.ChangedDuration changed)
            Assert.True(Number(expected, "naturalOut") == changed.NaturalOut && Number(expected, "residualSeconds") == changed.ResidualSeconds,
                name);
        var edits = expected.GetProperty("edits").EnumerateArray().Select(row => (row[0].GetString()!, row[1].GetInt64(), row[2].GetInt64()));
        Assert.True(edits.SequenceEqual(plan.Edits.Select(edit => (Name(edit.Kind), edit.Start, edit.Count))), name);
        Assert.True(Pair(expected, "incoming") == (plan.Incoming.PadFrames, plan.Incoming.BorrowedSamples), name);
        Assert.True(Pair(expected, "outgoing") == (plan.Outgoing.PadFrames, plan.Outgoing.BorrowedSamples), name);
        Assert.True(Pair(expected, "trims") == (plan.TrimStartFrame, plan.TrimEndFrame), name);
        Assert.True(Pair(expected, "window") == (plan.WindowStartSample, plan.WindowEndSample), name);
        Assert.True(Integer(expected, "outputFrames") == plan.OutputFrames, name);
        if (expected.TryGetProperty("words", out var words))
        {
            Assert.True(words.EnumerateArray().Select(word => (word[0].GetDouble(), word[1].GetDouble()))
                .SequenceEqual(plan.Words.Select(word => (word.Start, word.End))), name);
            Assert.True(Number(expected, "windowStart") == plan.WindowStart && Number(expected, "windowEnd") == plan.WindowEnd, name);
        }
        CheckProperties(result, input, name);
    }

    /// <summary>§8.9.2 on one plan, derived from the plan and the input alone, as generate_fit.py checks them: no edit or join
    /// touches a word span or a voiced frame, each edit is centred in its run within the run's limits, the output adds up and
    /// fills the window (or changes length with the sign of ρ), the seams keep their limits, and every word keeps its aligned
    /// frames.</summary>
    static void CheckProperties(VoiceLabFitResult result, JsonElement input, string name)
    {
        var plan = result.Plan;
        var take = Take(input);
        var tokens = Strings(input.GetProperty("tokens"));
        var rate = Number(input, "sourceSampleRate");
        double assetRate = take.AssetSampleRate;
        var size = VoiceLabGeometry.FrameSize(assetRate);
        var fade = VoiceLabGeometry.Samples(VoiceLabPatchConstants.SEAM_FADE, assetRate);
        var unvoiced = take.Envelope.Rms.Select(level => (double)level < VoiceLabPatchConstants.VOICED_FRAME_LEVEL).ToArray();
        var spans = take.Words.Select(word => (Start: (long)Math.Floor(word.Start * assetRate), End: (long)Math.Ceiling(word.End * assetRate)))
            .ToArray();
        var t0 = VoiceLabGeometry.Samples(take.TrimStart, assetRate);
        var t1 = VoiceLabGeometry.Samples(take.TrimEnd, assetRate);
        var window = input.GetProperty("window");
        var leftKind = Text(window, "leftKind");
        var rightKind = Text(window, "rightKind");
        var incomingSilence = Silence(input, "incomingSilence");
        var outgoingSilence = Silence(input, "outgoingSilence");
        var edgeIn = leftKind == "none"
            ? Math.Max(0, VoiceLabGeometry.Samples(incomingSilence ?? 0, assetRate) - (spans[0].Start - t0)) : 0;
        var edgeOut = rightKind == "none"
            ? Math.Max(0, VoiceLabGeometry.Samples(outgoingSilence ?? 0, assetRate) - (t1 - spans[^1].End)) : 0;
        var natural = edgeIn + edgeOut + t1 - t0;
        var n0 = Integer(window, "endSample") - Integer(window, "startSample");
        var rho = natural - (long)EditingMath.Round(n0 * assetRate / rate);

        // The never-touch-voice invariant and the output's length.
        var cursor = plan.TrimStartFrame;
        var frames = plan.Incoming.PadFrames + plan.TrimEndFrame - plan.TrimStartFrame + plan.Outgoing.PadFrames;
        foreach (var edit in plan.Edits)
        {
            var lo = edit.Start - fade / 2;
            var hi = edit.Start + edit.Count + fade - fade / 2;
            Assert.True(edit.Count > 0 && cursor <= lo && hi <= plan.TrimEndFrame, $"{name}: edit at {edit.Start}");
            var touchesWord = spans.Any(span => span.Start < hi && lo < span.End);
            Assert.False(touchesWord, $"{name}: edit at {edit.Start} touches a word");
            for (var block = lo / size; block < (hi + size - 1) / size; block++)
                Assert.True(block < unvoiced.LongLength && unvoiced[block], $"{name}: edit at {edit.Start} touches voice");
            cursor = hi;
            frames += edit.Kind == VoiceLabFitEditKind.Insert ? edit.Count : -edit.Count;
            Assert.True(edit.Kind == (rho > 0 ? VoiceLabFitEditKind.Remove : VoiceLabFitEditKind.Insert), name);
            // The run that holds the edit, its centre and its limits.
            var word = Enumerable.Range(0, spans.Length - 1).LastOrDefault(index => spans[index].End <= edit.Start, -1);
            Assert.True(word >= 0, $"{name}: edit before the first word");
            var first = edit.Start / size;
            var last = (edit.Start + edit.Count + size - 1) / size;
            while (first * size - size >= spans[word].End && unvoiced[first - 1]) first--;
            while (last * size + size <= spans[word + 1].Start && last < unvoiced.LongLength && unvoiced[last]) last++;
            var length = (last - first) * size;
            Assert.True(edit.Start - first * size == (length - edit.Count) / 2 && edit.Count + fade <= length, name);
            if (edit.Kind == VoiceLabFitEditKind.Remove)
            {
                var floor = VoiceLabFitPlanner.IsPunctuation(tokens[word]) ? VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT : VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE;
                Assert.True(length - edit.Count >= VoiceLabGeometry.Samples(floor, assetRate), name);
            }
            else Assert.True(edit.Count <= VoiceLabGeometry.Samples(VoiceLabPatchConstants.PAUSE_GROWTH_MAX, assetRate), name);
        }
        Assert.True(frames == plan.OutputFrames, name);
        var windowFrames = (long)EditingMath.Round((plan.WindowEndSample - plan.WindowStartSample) * assetRate / rate);
        switch (result)
        {
            case VoiceLabFitResult.Exact:
                Assert.True(plan.OutputFrames == windowFrames, name);
                break;
            case VoiceLabFitResult.ChangedDuration changed:
                var residual = plan.OutputFrames - windowFrames;
                Assert.True(residual != 0 && (residual > 0) == (rho > 0), name);
                Assert.True(changed.ResidualSeconds == residual / assetRate && changed.NaturalOut == natural / assetRate, name);
                break;
        }

        // Seams: borrowing keeps PAUSE_SLACK_KEEP and happens only at gaps; pads stay within their limits beyond the edge pad.
        var keep = VoiceLabGeometry.Samples(VoiceLabPatchConstants.PAUSE_SLACK_KEEP, rate);
        foreach (var (seam, kind, silence, edge) in new[] { (plan.Incoming, leftKind, incomingSilence, edgeIn), (plan.Outgoing, rightKind, outgoingSilence, edgeOut) })
        {
            var lend = kind == "gap" ? Math.Max(0, VoiceLabGeometry.Samples(silence ?? 0, rate) - keep) : 0;
            var cap = VoiceLabGeometry.Samples(kind == "hard" ? VoiceLabPatchConstants.HARD_SEAM_PAD_MAX : VoiceLabPatchConstants.SEAM_PAD_MAX, assetRate);
            Assert.True(seam.BorrowedSamples >= 0 && seam.BorrowedSamples <= lend, name);
            Assert.True(seam.PadFrames >= 0 && seam.PadFrames - edge <= cap, name);
            Assert.True(kind != "hard" || seam.PadFrames >= edge, name);
        }
        Assert.True(plan.WindowStart == plan.WindowStartSample / rate, name);
        Assert.True(plan.WindowEnd == plan.WindowEndSample / rate, name);

        // Every word keeps its aligned frames and moves by the incoming pad and the edits before it. Its times stop at the
        // output's duration as the recipe states it, so the §10.5 render validator's word rule holds.
        var duration = plan.WindowEnd - plan.WindowStart;
        if (result is VoiceLabFitResult.ChangedDuration { ResidualSeconds: var residualSeconds })
            duration = plan.WindowEnd - plan.WindowStart + residualSeconds;
        var outSamples = VoiceLabGeometry.Samples(duration, rate);
        if (result is VoiceLabFitResult.Exact) Assert.True(outSamples == plan.WindowEndSample - plan.WindowStartSample, name);
        Assert.True(plan.Words.Count == take.Words.Count, name);
        double previous = 0;
        for (var index = 0; index < take.Words.Count; index++)
        {
            var span = spans[index];
            var shift = plan.Edits.Where(edit => edit.Start < span.Start).Sum(edit => edit.Kind == VoiceLabFitEditKind.Insert ? edit.Count : -edit.Count);
            var offsetFrames = plan.Incoming.PadFrames - plan.TrimStartFrame + shift;
            var offset = offsetFrames / assetRate;
            var word = take.Words[index];
            var moved = new VoiceLabWord(word.Text, Math.Min(word.Start + offset, duration), Math.Min(word.End + offset, duration), true);
            Assert.True(plan.Words[index] == moved, name);
            Assert.True(span.Start + offsetFrames >= 0 && span.End + offsetFrames <= plan.OutputFrames, name);
            Assert.True(moved.End <= duration && VoiceLabGeometry.Samples(moved.End, rate) <= outSamples, name);
            Assert.True(moved.Start >= previous && moved.End > moved.Start, name);
            Assert.True(VoiceLabGeometry.Samples(moved.End, rate) > VoiceLabGeometry.Samples(moved.Start, rate), name);
            previous = moved.End;
        }
    }

    [Fact]
    public void ConstantsMatchSection83AndTheVectors()
    {
        Assert.Equal("voxclip-voice-lab-fit-cases/1", Text(Document.Value, "schema"));
        var constants = new Dictionary<string, double>(StringComparer.Ordinal)
        {
            ["SEAM_FADE"] = VoiceLabPatchConstants.SEAM_FADE, ["HARD_SEAM_FADE"] = VoiceLabPatchConstants.HARD_SEAM_FADE,
            ["TTS_TRIM_LEAD"] = VoiceLabPatchConstants.TTS_TRIM_LEAD, ["TTS_TRIM_TAIL"] = VoiceLabPatchConstants.TTS_TRIM_TAIL,
            ["PAUSE_SLACK_KEEP"] = VoiceLabPatchConstants.PAUSE_SLACK_KEEP, ["SEAM_PAD_MAX"] = VoiceLabPatchConstants.SEAM_PAD_MAX,
            ["HARD_SEAM_PAD_MAX"] = VoiceLabPatchConstants.HARD_SEAM_PAD_MAX, ["PAUSE_FLOOR_PHRASE"] = VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE,
            ["PAUSE_FLOOR_PUNCT"] = VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, ["PAUSE_GROWTH_MAX"] = VoiceLabPatchConstants.PAUSE_GROWTH_MAX,
            ["LENGTH_AIM_MIN"] = VoiceLabPatchConstants.LENGTH_AIM_MIN, ["LENGTH_AIM_MAX"] = VoiceLabPatchConstants.LENGTH_AIM_MAX,
            ["VOICED_FRAME"] = VoiceLabPatchConstants.VOICED_FRAME, ["VOICED_FRAME_LEVEL"] = VoiceLabPatchConstants.VOICED_FRAME_LEVEL,
            ["RMS_FRAME"] = VoiceLabPatchConstants.RMS_FRAME,
        };
        var document = Document.Value.GetProperty("constants").EnumerateObject().ToDictionary(item => item.Name, item => item.Value.GetDouble(),
            StringComparer.Ordinal);
        Assert.Equal(constants.OrderBy(item => item.Key, StringComparer.Ordinal), document.OrderBy(item => item.Key, StringComparer.Ordinal));
        // The §8.3 values themselves, so the generator and the Core cannot drift together.
        Assert.Equal(new[] { 0.3, 0.060, 0.060, 0.150, 0.25, 0.92, 0.97 }, new[]
        {
            VoiceLabPatchConstants.SEAM_PAD_MAX, VoiceLabPatchConstants.HARD_SEAM_PAD_MAX, VoiceLabPatchConstants.PAUSE_FLOOR_PHRASE,
            VoiceLabPatchConstants.PAUSE_FLOOR_PUNCT, VoiceLabPatchConstants.PAUSE_GROWTH_MAX, VoiceLabPatchConstants.LENGTH_AIM_MIN,
            VoiceLabPatchConstants.LENGTH_AIM_MAX
        });
    }

    [Fact]
    public void DocumentCountsEveryCase()
    {
        var cases = Cases("cases");
        var properties = Cases("propertyCases");
        Assert.Equal(cases.Length + properties.Length, Document.Value.GetProperty("caseCount").GetInt32());
        Assert.Equal(cases.Length, Document.Value.GetProperty("categories").EnumerateObject().Sum(category => category.Value.GetInt32()));
        var fuzz = Document.Value.GetProperty("propertyFuzz");
        Assert.Equal(20_261_027, fuzz.GetProperty("seed").GetInt32());
        Assert.Equal(2000, fuzz.GetProperty("cases").GetInt32());
        Assert.Equal(2000, properties.Length);
        Assert.Equal(cases.Length, cases.Select(test => Text(test, "name")).Distinct(StringComparer.Ordinal).Count());
    }

    [Fact]
    public void NamedVectors()
    {
        foreach (var test in Cases("cases")) Replay(test);
    }

    [Fact]
    public void PropertyCases()
    {
        foreach (var test in Cases("propertyCases")) Replay(test);
    }

    /// <summary>Inputs the JSON vectors cannot carry: non-finite numbers, a seam sample off the window and a seam a window never has.</summary>
    [Fact]
    public void NonFiniteAndInconsistentInputsAreInvalid()
    {
        var input = Case("pause-punctuation-first").GetProperty("input");
        var good = Take(input);
        var placed = Window(input);
        var tokens = Strings(input.GetProperty("tokens"));
        string? Refusal(VoiceLabWindow? window = null, double? incoming = 0.6, VoiceLabFitTake? take = null, double rate = 48000)
        {
            try
            {
                _ = VoiceLabFitPlanner.Plan(window ?? placed, incoming, 0.6, take ?? good, tokens, rate);
                return null;
            }
            catch (VoiceLabGeometryException failure) { return Code(failure.Code); }
        }
        VoiceLabFitTake WithLevel(float level)
        {
            var levels = good.Envelope.Rms.ToArray();
            levels[3] = level;
            return good with { Envelope = good.Envelope with { Rms = levels } };
        }
        Assert.Null(Refusal());
        Assert.Equal("invalidInput", Refusal(rate: double.NaN));
        Assert.Equal("invalidInput", Refusal(rate: double.PositiveInfinity));
        Assert.Equal("invalidInput", Refusal(incoming: double.NaN));
        Assert.Equal("invalidInput", Refusal(incoming: double.PositiveInfinity));
        Assert.Equal("invalidInput", Refusal(placed with { LeftSeam = placed.LeftSeam with { Sample = placed.LeftSeam.Sample + 1 } }));
        Assert.Equal("invalidInput", Refusal(placed with { Start = double.NaN }));
        Assert.Equal("invalidInput", Refusal(take: good with { TrimEnd = double.NaN }));
        Assert.Equal("invalidInput", Refusal(take: WithLevel(float.NaN)));
        Assert.Equal("invalidInput", Refusal(take: WithLevel(-1)));
        Assert.Equal("invalidInput", Refusal(take: good with { AssetSampleRate = 0 }));
        var words = good.Words.ToArray();
        words[1] = words[1] with { Start = double.NaN };
        Assert.Equal("invalidWordTiming", Refusal(take: good with { Words = words }));
    }

    [Fact]
    public void EveryWordIsSyntheticWithItsProviderText()
    {
        var input = Case("punctuation-categories").GetProperty("input");
        var plan = Plan(input).Plan;
        Assert.Equal(Take(input).Words.Select(word => word.Text), plan.Words.Select(word => word.Text));
        Assert.All(plan.Words, word => Assert.True(word.Synthetic));
    }
}
