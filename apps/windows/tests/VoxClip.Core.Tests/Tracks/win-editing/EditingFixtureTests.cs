using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;
using VoxClip.Tests.Support;
using Xunit;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class EditingFixtureTests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals
    };

    public static IEnumerable<TheoryDataRow<string>> Fixtures()
    {
        var root = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "editing");
        foreach (var path in Directory.GetFiles(root, "*.json", SearchOption.AllDirectories).Order(StringComparer.Ordinal))
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var relative = Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/');
            var row = new TheoryDataRow<string>(relative);
            if (document.RootElement.GetProperty("kind").GetString() == "caption-text") row.Skip = "Informative VoxConvo caption transform; editing §11.1 requires this skip.";
            yield return row;
        }
    }

    [Theory]
    [MemberData(nameof(Fixtures))]
    public async Task EveryEditingFixtureConforms(string relative)
    {
        using var document = FixtureLoader.ReadJson(Path.Combine("fixtures", "editing", relative));
        var fixture = document.RootElement;
        Assert.Equal("voxclip-editing-fixture/1", fixture.GetProperty("schema").GetString());
        Assert.Equal(relative[..^5], fixture.GetProperty("id").GetString());
        var input = fixture.GetProperty("input");
        var expected = fixture.GetProperty("expected");
        var tolerance = expected.TryGetProperty("tolerance", out var value) ? Number(value) : 1e-9;
        object actual = fixture.GetProperty("kind").GetString() switch
        {
            "edit-plan" => Plan(input, expected),
            "join-fades" => Fades(input, expected),
            "edit-session" => Session(input),
            "pause-detection" => new { pauses = EditingAlgorithms.DetectPauses(Words(input), input.GetProperty("hasDecodedAudio").GetBoolean() ? 0.8 : 1.0) },
            "pause-label" => new { labels = input.GetProperty("durations").EnumerateArray().Select(duration => "pause " + EditingFormat.ToFixed1(Number(duration)) + "s").ToArray() },
            "filler-detection" => new { matches = input.GetProperty("words").EnumerateArray().Select(word => EditingAlgorithms.IsFillerText(word.GetString()!)).ToArray() },
            "transcript-alignment" => new { words = EditingAlgorithms.AlignTranscriptWords(RawWords(input.GetProperty("words")), input.GetProperty("finalText").GetString()!).Select(word => new { word = word.Text, start = word.Start, end = word.End }).ToArray() },
            "estimated-words" => new { words = EditingAlgorithms.EstimateTranscriptWords(input.GetProperty("text").GetString()!, Number(input.GetProperty("start")), Number(input.GetProperty("end"))).Select(word => new { word = word.Text, start = word.Start, end = word.End, conf = word.Conf }).ToArray() },
            "clip-range" => ClipRanges(input),
            "word-boundaries" => new { words = EditingAlgorithms.RefineWordBoundaries(Words(input), Audio(input.GetProperty("audio")), Number(input.GetProperty("audio").GetProperty("seconds"))) },
            "word-tightening" => new { words = EditingImport.TightenIntoSound(Words(input), Audio(input.GetProperty("audio")), Timing(input.GetProperty("timing").GetString()!), Number(input.GetProperty("audio").GetProperty("seconds"))) },
            "unlabeled-speech" => new { items = EditingImport.FindUnlabeledSpeech(Words(input), Audio(input.GetProperty("audio")), Number(input.GetProperty("audio").GetProperty("seconds"))) },
            "word-cleanup" => new { words = EditingImport.CleanWords(RawWords(input.GetProperty("rawWords"))) },
            "import-pipeline" => Pipeline(input),
            "text-whitespace" => new { trim = input.GetProperty("strings").EnumerateArray().Select(text => EditingAlgorithms.JsTrim(text.GetString()!)).ToArray(), split = input.GetProperty("strings").EnumerateArray().Select(text => EditingAlgorithms.SplitWords(text.GetString()!)).ToArray() },
            "content-key" => await ContentKeys(input),
            "project-plan" => await ProjectPlan(input),
            _ => throw new InvalidOperationException("Unknown editing fixture kind: " + fixture.GetProperty("kind").GetString())
        };
        Compare(expected, JsonSerializer.SerializeToElement(actual, JsonOptions), tolerance);
    }

    private static object Plan(JsonElement input, JsonElement expected)
    {
        var segments = Segments(input);
        var duration = Number(input.GetProperty("durationSeconds"));
        var rate = Number(input.GetProperty("sampleRate"));
        var keep = input.TryGetProperty("pauseKeepSeconds", out var breath) ? Number(breath) : 0.15;
        var plan = EditingEngine.BuildEditPlan(segments, duration, rate, keep);
        var cuts = segments.Select((segment, index) => (segment, index)).Where(pair => pair.segment.Cut && double.IsFinite(pair.segment.Start) && double.IsFinite(pair.segment.End) && pair.segment.End > pair.segment.Start)
            .Select(pair =>
            {
                var range = EditingEngine.CutRange(segments, pair.index, duration, keep);
                var start = Clamp(range.Start, rate, plan.TotalSamples);
                var end = Clamp(range.End, rate, plan.TotalSamples);
                return new { id = pair.segment.Id, rawStart = range.Start, rawEnd = range.End, startSample = start, endSample = end, empty = end <= start };
            }).ToArray();
        return new
        {
            totalSamples = plan.TotalSamples, outputSamples = plan.OutputSamples, durationSeconds = plan.Duration, segmentCuts = cuts,
            cuts = Ranges(plan.Cuts), kept = Ranges(plan.Kept), captions = EditingEngine.CaptionCopy(segments, plan),
            mapTime = expected.GetProperty("mapTime").EnumerateArray().Select(probe => new[] { Number(probe[0]), plan.MapTime(Number(probe[0])) }).ToArray(),
            sourceTime = expected.GetProperty("sourceTime").EnumerateArray().Select(probe => new[] { Number(probe[0]), plan.SourceTime(Number(probe[0])) }).ToArray(),
            previewSkip = expected.GetProperty("previewSkip").EnumerateArray().Select(probe => new double?[] { Number(probe[0]), plan.CutContaining(Number(probe[0])) is { } cut ? cut.EndSample / rate : null }).ToArray()
        };
    }

    private static object Fades(JsonElement input, JsonElement expected)
    {
        var plan = EditingEngine.BuildEditPlan(Segments(input), Number(input.GetProperty("durationSeconds")), Number(input.GetProperty("sampleRate")));
        long offset = 0;
        var parts = plan.Kept.Select(part =>
        {
            var length = part.EndSample - part.StartSample;
            var fade = Math.Min((long)Round(0.005 * plan.SampleRate), length / 2);
            var outputStart = offset;
            offset += length;
            return new { outputStart, length, fadeIn = part.StartSample > 0 ? fade : 0, fadeOut = part.EndSample < plan.TotalSamples ? fade : 0 };
        }).ToArray();
        foreach (var part in parts)
        {
            if (part.fadeIn > 0) Assert.Contains(plan.Joins, join => join.OutSample == part.outputStart && join.FadeInLen == part.fadeIn);
            if (part.fadeOut > 0) Assert.Contains(plan.Joins, join => join.OutSample == part.outputStart + part.length && join.FadeOutLen == part.fadeOut);
        }
        foreach (var probe in expected.GetProperty("gains").EnumerateArray())
            Assert.Equal(LeadParityTests.GainFromJoins(plan, probe[0].GetInt64()), plan.JoinGain(probe[0].GetInt64()));
        return new { kept = Ranges(plan.Kept), outputSamples = plan.OutputSamples, parts, joins = plan.Joins.Select(join => new[] { join.OutSample, join.FadeOutLen, join.FadeInLen }).ToArray(),
            gains = expected.GetProperty("gains").EnumerateArray().Select(probe => new[] { Number(probe[0]), plan.JoinGain(probe[0].GetInt64()) }).ToArray() };
    }

    private static object ClipRanges(JsonElement input)
    {
        var words = Words(input);
        return new { ranges = input.GetProperty("ranges").EnumerateArray().Select(range =>
        {
            var start = range[0].GetInt32(); var end = range[1].GetInt32();
            var times = EditingAlgorithms.ClipTimes(words, start, end);
            return new { startWord = start, endWord = end, start = times.Start, end = times.End };
        }).ToArray() };
    }

    private static object Pipeline(JsonElement input)
    {
        var audio = input.GetProperty("audio");
        var envelope = audio.ValueKind == JsonValueKind.Null ? null : Audio(audio);
        var result = EditingImport.Pipeline(RawWords(input.GetProperty("rawWords")), envelope, Timing(input.GetProperty("timing").GetString()!), input.GetProperty("verbatim").GetBoolean(), envelope is null ? null : Number(audio.GetProperty("seconds")));
        return new { words = result.Words, pauseThresholdSeconds = result.PauseThresholdSeconds, pauses = result.Pauses };
    }

    private static object Session(JsonElement input)
    {
        var duration = Number(input.GetProperty("durationSeconds"));
        var rate = Number(input.GetProperty("sampleRate"));
        var words = Words(input);
        var state = State(words, duration, input.GetProperty("hasDecodedAudio").GetBoolean());
        using var initial = JsonDocument.Parse("{\"op\":\"initial\"}");
        var steps = new List<object> { Step(initial.RootElement) };
        foreach (var operation in input.GetProperty("ops").EnumerateArray())
        {
            var name = operation.GetProperty("op").GetString();
            if (name == "previewClip")
            {
                var clip = operation.GetProperty("clip");
                if (clip.ValueKind == JsonValueKind.Null) state = EditingEngine.Reduce(state, new EditOperation.SetActiveClip(null));
                else
                {
                    var id = "preview-" + steps.Count;
                    state = EditingEngine.Reduce(state, new EditOperation.AddClip(new(id, words[clip[0].GetInt32()].Id, words[clip[1].GetInt32()].Id, null, ClipOrigin.Manual, null, null, true)));
                    state = EditingEngine.Reduce(state, new EditOperation.SetActiveClip(id));
                }
            }
            else
            {
                EditOperation op = name switch
                {
                    "toggle" => new EditOperation.Toggle(operation.GetProperty("id").GetString()!),
                    "cutSelection" => new EditOperation.CutSelection(operation.GetProperty("ids").EnumerateArray().Select(id => id.GetString()!).ToArray()),
                    "restoreSelection" => new EditOperation.RestoreSelection(operation.GetProperty("ids").EnumerateArray().Select(id => id.GetString()!).ToArray()),
                    "correct" => new EditOperation.Correct(operation.GetProperty("id").GetString()!, operation.GetProperty("text").GetString()!),
                    "cutFillers" => new EditOperation.CutFillers(), "tightenPauses" => new EditOperation.TightenPauses(), "restoreCuts" => new EditOperation.RestoreCuts(),
                    _ => throw new InvalidOperationException("Unknown session operation " + name)
                };
                state = EditingEngine.Reduce(state, op);
            }
            steps.Add(Step(operation));
        }
        return new { steps };

        object Step(JsonElement after)
        {
            var summary = EditingEngine.Summarize(state);
            var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, duration), duration, rate, state.PauseKeepSeconds);
            var clip = state.Clips.FirstOrDefault(clip => clip.Id == state.ActiveClipId);
            var ids = words.Select(word => word.Id).ToList();
            return new
            {
                after = after.Clone(), cutWords = state.CutWordIds.Order(StringComparer.Ordinal).ToArray(), cutPauses = state.CutPauseIds.Order(StringComparer.Ordinal).ToArray(),
                texts = words.ToDictionary(word => word.Id, word => state.Corrections.GetValueOrDefault(word.Id, word.Text)),
                activeClip = clip is null ? null : new[] { ids.IndexOf(clip.StartWordId), ids.IndexOf(clip.EndWordId) },
                ui = new { cutFillersLabel = summary.FillerCount > 0 ? "Cut fillers · " + summary.FillerCount : "Cut fillers", cutFillersEnabled = summary.CanCutFillers,
                    tightenPausesEnabled = summary.CanTighten, restoreCutsVisible = summary.HasEdits,
                    status = summary.HasEdits ? summary.CutWordCount + (summary.CutWordCount == 1 ? " word" : " words") + " and " + summary.CutPauseCount + (summary.CutPauseCount == 1 ? " pause" : " pauses") + " cut. Preview before publishing." : null,
                    publishEnabled = summary.CanExport }, durationSeconds = plan.Duration, captions = EditingEngine.CaptionWords(state, plan)
            };
        }
    }

    private static async Task<object> ProjectPlan(JsonElement input)
    {
        var path = Path.Combine(Path.GetDirectoryName(FixtureLoader.SharedRoot)!, input.GetProperty("projectPath").GetString()!);
        var opened = await new ProjectStore().LoadAsync(path, CancellationToken.None);
        var project = opened.Project;
        Assert.Empty(opened.Warnings);
        var duration = project.Media.Source.DurationSeconds;
        var rate = project.Media.Source.Audio?.SampleRate ?? 48000;
        var state = EditingEngine.FromProject(project)! with { ActiveClipId = null };
        object Target(EditState snapshot)
        {
            var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(snapshot, duration), duration, rate, snapshot.PauseKeepSeconds);
            return new { outputSamples = plan.OutputSamples, durationSeconds = plan.Duration, kept = Ranges(plan.Kept), captions = EditingEngine.CaptionWords(snapshot, plan) };
        }
        return new { sampleRate = rate, sourceDurationSeconds = duration, pauses = state.Pauses, take = Target(state), clips = state.Clips.Select(clip =>
        {
            var ids = state.Transcript.Words.Select(word => word.Id).ToList();
            var start = ids.IndexOf(clip.StartWordId); var end = ids.IndexOf(clip.EndWordId);
            var times = EditingAlgorithms.ClipTimes(state.Transcript.Words, start, end);
            var snapshot = state with { ActiveClipId = clip.Id };
            var plan = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(snapshot, duration), duration, rate, snapshot.PauseKeepSeconds);
            return new { id = clip.Id, startWord = start, endWord = end, sourceStart = times.Start, sourceEnd = times.End, outputSamples = plan.OutputSamples, durationSeconds = plan.Duration, kept = Ranges(plan.Kept), captions = EditingEngine.CaptionWords(snapshot, plan) };
        }).ToArray() };
    }

    private static async Task<object> ContentKeys(JsonElement input)
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-content-key-");
        try
        {
            var keys = new List<string>();
            foreach (var size in input.GetProperty("sizes").EnumerateArray())
            {
                var data = new byte[size.GetInt32()];
                for (var index = 0; index < data.Length; index++) data[index] = (byte)((index * 31 + 7) % 251);
                var path = Path.Combine(directory.FullName, "source.bin");
                await File.WriteAllBytesAsync(path, data);
                keys.Add(await new ProjectStore().ComputeContentKeyAsync(path, null, CancellationToken.None));
            }
            return new { contentKeys = keys };
        }
        finally { directory.Delete(true); }
    }

    internal static EditState State(IReadOnlyList<TimedWord> words, double duration = 10, bool refined = true)
        => new(new TranscriptModel(1, words, "en", null, duration, new(TranscriptEngine.Elevenlabs, "scribe_v2", null, "fixture", null), true, refined, 1, new string('0', 64), DateTimeOffset.UnixEpoch),
            EditingAlgorithms.DetectPauses(words, refined ? 0.8 : 1), refined ? 0.8 : 1, 0.15, new HashSet<string>(StringComparer.Ordinal), new HashSet<string>(StringComparer.Ordinal), new Dictionary<string, string>(StringComparer.Ordinal), [], null);

    internal static TimedWord Word(string id, string text, double start, double end, WordKind kind = WordKind.Word) => new(id, text, kind, start, end, start, end, null, null, TimingSource.Native);

    private static TimedWord[] Words(JsonElement input) => input.GetProperty("words").EnumerateArray().Select((word, index) => Word(
        word.TryGetProperty("id", out var id) ? id.GetString()! : "w" + index,
        word.TryGetProperty("text", out var text) ? text.GetString()! : word.TryGetProperty("word", out text) ? text.GetString()! : "word",
        Number(word.GetProperty("start")), Number(word.GetProperty("end")), Kind(word))).ToArray();

    private static RawWord[] RawWords(JsonElement array) => array.EnumerateArray().Select(word => new RawWord(
        word.TryGetProperty("text", out var text) ? text.GetString()! : word.GetProperty("word").GetString()!,
        OptionalNumber(word, "start"), OptionalNumber(word, "end"), OptionalNumber(word, "conf"), word.TryGetProperty("speaker", out var speaker) ? speaker.GetString() : null, Kind(word))).ToArray();

    private static EditSegment[] Segments(JsonElement input) => input.GetProperty("segments").EnumerateArray().Select(segment => new EditSegment(segment.GetProperty("id").GetString()!,
        segment.GetProperty("kind").GetString() switch { "word" => EditSegmentKind.Word, "pause" => EditSegmentKind.Pause, "range" => EditSegmentKind.Range, _ => throw new InvalidOperationException() },
        segment.TryGetProperty("wordKind", out var wordKind) ? WordKindValue(wordKind.GetString()) : null,
        segment.TryGetProperty("text", out var text) ? text.GetString() : null, Number(segment.GetProperty("start")), Number(segment.GetProperty("end")), segment.GetProperty("cut").GetBoolean())).ToArray();

    private static WordKind Kind(JsonElement word) => word.TryGetProperty("kind", out var kind) ? WordKindValue(kind.GetString()) : WordKind.Word;
    private static WordKind WordKindValue(string? kind) => kind switch { "event" => WordKind.Event, "unlabeledSpeech" => WordKind.UnlabeledSpeech, _ => WordKind.Word };
    private static TimingSource Timing(string timing) => timing switch { "native" => TimingSource.Native, "dtw" => TimingSource.Dtw, "runGrouped" => TimingSource.RunGrouped, "tokenGrouped" => TimingSource.TokenGrouped, _ => throw new InvalidOperationException() };
    private static double? OptionalNumber(JsonElement item, string key) => item.TryGetProperty(key, out var value) && value.ValueKind != JsonValueKind.Null ? Number(value) : null;
    private static double Number(JsonElement value) => value.Deserialize<double>(JsonOptions);
    private static double Round(double value) { var floor = Math.Floor(value); return value - floor >= 0.5 ? floor + 1 : floor; }
    private static long Clamp(double time, double rate, long total) => (long)Math.Min(total, Math.Max(0, Round(time * rate)));
    private static long[][] Ranges(IReadOnlyList<MediaInterval> intervals) => intervals.Select(interval => new[] { interval.StartSample, interval.EndSample }).ToArray();

    private static AudioEnvelope Audio(JsonElement audio)
    {
        Assert.Equal("vox-take-v1", audio.GetProperty("generator").GetString());
        var rate = audio.GetProperty("sampleRate").GetInt32();
        var samples = new float[(int)(Number(audio.GetProperty("seconds")) * rate)];
        double seed = 7;
        double Noise() { seed = seed * 16807 % 2147483647; return seed / 2147483647 * 2 - 1; }
        for (var sample = 0; sample < samples.Length; sample++) samples[sample] = (float)(0.002 * Noise());
        foreach (var section in audio.GetProperty("sections").EnumerateArray())
            for (var sample = (int)Round(Number(section[0]) * rate); sample < (int)Round(Number(section[1]) * rate); sample++)
            {
                var value = section[2].GetString() == "vowel" ? 0.5 * Math.Sin(2 * Math.PI * 180 * sample / rate) : 0.1 * Noise();
                if (sample < samples.Length) samples[sample] = (float)value;
            }
        var builder = new AudioEnvelopeBuilder(rate, 1);
        var chunks = new[] { 1, 3, 17, 257, 1025 };
        var offset = 0;
        var chunk = 0;
        while (offset < samples.Length)
        {
            var count = Math.Min(chunks[chunk++ % chunks.Length], samples.Length - offset);
            builder.Append(samples.AsSpan(offset, count));
            offset += count;
        }
        return builder.Finish();
    }

    private static void Compare(JsonElement expected, JsonElement actual, double tolerance, string path = "$")
    {
        if (expected.ValueKind == JsonValueKind.Object)
        {
            Assert.Equal(JsonValueKind.Object, actual.ValueKind);
            foreach (var property in expected.EnumerateObject())
            {
                if (property.Name == "tolerance") continue;
                Assert.True(actual.TryGetProperty(property.Name, out var child), path + "." + property.Name + " is missing");
                Compare(property.Value, child, tolerance, path + "." + property.Name);
            }
        }
        else if (expected.ValueKind == JsonValueKind.Array)
        {
            Assert.Equal(JsonValueKind.Array, actual.ValueKind);
            Assert.True(expected.GetArrayLength() == actual.GetArrayLength(), path + " array length differs: " + actual.GetArrayLength() + " != " + expected.GetArrayLength());
            for (var index = 0; index < expected.GetArrayLength(); index++) Compare(expected[index], actual[index], tolerance, path + "[" + index + "]");
        }
        else if (expected.ValueKind == JsonValueKind.Number)
        {
            Assert.Equal(JsonValueKind.Number, actual.ValueKind);
            var exact = path.EndsWith(".rawStart", StringComparison.Ordinal) || path.EndsWith(".rawEnd", StringComparison.Ordinal) || path.Contains("Sample", StringComparison.Ordinal) || path.Contains(".kept[", StringComparison.Ordinal) || path.Contains(".cuts[", StringComparison.Ordinal);
            if (exact && expected.TryGetInt64(out var integer))
            {
                Assert.Equal(integer, actual.GetInt64());
                return;
            }
            var distance = Math.Abs(expected.GetDouble() - actual.GetDouble());
            Assert.True(distance <= (exact ? 0 : tolerance), path + ": " + actual.GetRawText() + " != " + expected.GetRawText());
        }
        else Assert.True(expected.GetRawText() == actual.GetRawText() || expected.ValueKind == JsonValueKind.String && actual.ValueKind == JsonValueKind.String && expected.GetString() == actual.GetString(), path + ": " + actual.GetRawText() + " != " + expected.GetRawText());
    }
}
