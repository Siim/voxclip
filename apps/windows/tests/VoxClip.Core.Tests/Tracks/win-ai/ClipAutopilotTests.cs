using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Settings;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

/// <summary>The Make it postable planner (ai.md §16), the twin of the Swift ClipAutopilotTests, ClipAutopilotV2Tests,
/// ClipAutopilotToneTests and ClipHookTitleTests. It replays every shared/fixtures/autopilot vector: plan-validation-cases.json,
/// plan-v2-cases.json and plan-tone-cases.json. No send leaves the process: every connector is a stub.</summary>
public sealed class ClipAutopilotTests
{
    internal static string Root => FixtureLoader.SharedRoot;
    internal static JsonObject Fixture(string name) => JsonNode.Parse(File.ReadAllText(Path.Combine(Root, "fixtures", "autopilot", name)))!.AsObject();
    private static JsonObject Validation() => Fixture("plan-validation-cases.json");

    internal static Transcript Transcript(JsonObject fixture, double duration)
    {
        var words = fixture["transcript"]!["words"]!.AsArray().Select(item => new TimedWord(item!["id"]!.GetValue<string>(), item["text"]!.GetValue<string>(),
            item["kind"]?.GetValue<string>() == "event" ? WordKind.Event : WordKind.Word, item["start"]!.GetValue<double>(), item["end"]!.GetValue<double>(),
            null, null, null, null, TimingSource.Native)).ToArray();
        return new(1, words, "en", null, duration, new(TranscriptEngine.Whispercpp, "fixture", null, "fixture", null), false, false, 1, new string('0', 64), DateTimeOffset.UnixEpoch);
    }
    internal static Transcript Transcript() => Transcript(Validation(), 12);

    internal static ProjectEdits Edits(IReadOnlyList<string>? cut = null, IReadOnlyList<string>? cutPauses = null, IReadOnlyDictionary<string, string>? corrections = null,
        IReadOnlyList<ClipRange>? clips = null) =>
        new(1, 0.15, cut ?? [], cutPauses ?? [], corrections ?? new Dictionary<string, string>(StringComparer.Ordinal), clips ?? [], null);

    private static ProjectEdits Edits(JsonNode? value) => Edits(
        value?["cutWordIds"]?.AsArray().Select(item => item!.GetValue<string>()).ToArray(),
        value?["cutPauseIds"]?.AsArray().Select(item => item!.GetValue<string>()).ToArray(),
        value?["corrections"]?.AsObject().ToDictionary(item => item.Key, item => item.Value!.GetValue<string>(), StringComparer.Ordinal));

    internal static ClipAutopilotContext Context(Transcript transcript, WordSpan scope, ProjectEdits? edits = null, ClipAutopilotCaptionPreference? preference = null,
        ClipAutopilotTone? tone = null)
    {
        edits ??= Edits();
        return new(transcript.Words, edits.Corrections, edits.CutWordIds.ToHashSet(StringComparer.Ordinal),
            EditingAlgorithms.DetectPauses(transcript.Words, edits.PauseThresholdSeconds), edits.CutPauseIds.ToHashSet(StringComparer.Ordinal), edits.PauseKeepSeconds,
            scope, CaptionStyleLibrary.Load(Root).Styles.Select(style => style.Id).ToHashSet(StringComparer.Ordinal), ClipAutopilotFonts.Load(Root), preference,
            ClipAutopilotPrompt.Load(Root), tone);
    }
    internal static ClipAutopilotContext Context(WordSpan scope, ProjectEdits? edits = null, ClipAutopilotCaptionPreference? preference = null) =>
        Context(Transcript(), scope, edits, preference);

    internal static WordSpan Range(JsonNode? value) => new(value![0]!.GetValue<int>(), value[1]!.GetValue<int>());

    internal static string[][] Repairs(IEnumerable<ClipAutopilotPlan.Repair> repairs) =>
        repairs.Select(repair => new[] { repair.Field, repair.Action }).OrderBy(pair => pair[0], StringComparer.Ordinal).ThenBy(pair => pair[1], StringComparer.Ordinal).ToArray();
    internal static string[][] Expected(JsonNode? value) =>
        value!.AsArray().Select(item => item!.AsArray().Select(cell => cell!.GetValue<string>()).ToArray())
            .OrderBy(pair => pair[0], StringComparer.Ordinal).ThenBy(pair => pair[1], StringComparer.Ordinal).ToArray();

    internal static JsonObject Case(JsonObject fixture, string id) => fixture["cases"]!.AsArray().Single(item => item!["id"]!.GetValue<string>() == id)!.AsObject();
    internal static JsonObject Reply(string id) => Case(Validation(), id)["reply"]!.DeepClone().AsObject();

    /// <summary>A version 1 vector reply with the later fields every send must carry, set to change nothing.</summary>
    internal static JsonObject Sendable(JsonObject reply)
    {
        var neutral = new JsonObject { ["corrections"] = new JsonArray(), ["lengthReason"] = "", ["captionReason"] = "", ["look"] = "original", ["lookReason"] = "",
            ["speed"] = 1, ["speedReason"] = "", ["tone"] = "none", ["toneSummary"] = "",
            ["frames"] = new JsonObject { ["blur"] = new JsonArray(), ["cover"] = new JsonObject { ["id"] = "", ["reason"] = "" } } };
        foreach (var (key, value) in neutral.ToArray()) if (!reply.ContainsKey(key)) reply[key] = value!.DeepClone();
        return reply;
    }

    private static string Fixed1(double value) => EditingFormat.ToFixed1(value);
    private static string Sha(string relative)
    {
        var bytes = File.ReadAllBytes(Path.Combine(Root, relative)).ToList();
        for (var index = bytes.Count - 2; index >= 0; index--) if (bytes[index] == 0x0D && bytes[index + 1] == 0x0A) bytes.RemoveAt(index);
        return Convert.ToHexStringLower(SHA256.HashData(bytes.ToArray()));
    }

    internal static Project Project(IReadOnlyList<ClipRange>? clips = null, IReadOnlyList<string>? cut = null, IReadOnlyList<string>? cutPauses = null)
    {
        var basis = ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/projects/interview-take.voxclip"));
        return basis with
        {
            Transcript = Transcript(), Edits = Edits(cut, cutPauses, clips: clips ?? [new ClipRange("c1", "w0", "w29", "Old", ClipOrigin.Manual, null, null, true)]),
            Media = new(basis.Media.Source with { DurationSeconds = 12 }), Share = new(new Dictionary<string, string>(StringComparer.Ordinal)), Ai = new([]),
            VoiceLab = new([]), Extensions = null
        };
    }

    // MARK: Prompt file

    [Fact]
    public void PromptFileFillsItsLimitsAndEveryFixturePinsIt()
    {
        var prompt = ClipAutopilotPrompt.Load(Root);
        Assert.Equal(9, prompt.PromptVersion);
        foreach (var system in new[] { prompt.System, prompt.MomentsSystem })
        {
            Assert.DoesNotContain("{", system, StringComparison.Ordinal);
            Assert.Contains("Length: 20 to 45 seconds after cuts. Up to 60 s only when the idea cannot land in less", system, StringComparison.Ordinal);
        }
        Assert.Contains("Never more than 3 in a clip", prompt.System, StringComparison.Ordinal);
        Assert.Contains("from 1.05 to 1.35", prompt.System, StringComparison.Ordinal);
        Assert.Contains("from 0.75 to 1.5", prompt.System, StringComparison.Ordinal);
        Assert.Contains("- original: the footage as filmed\n- muted: ", prompt.System, StringComparison.Ordinal);
        Assert.Contains("Tone\n- The request gives the clip a tone", prompt.System, StringComparison.Ordinal);
        Assert.Contains("Your task: pick the moments", prompt.MomentsSystem, StringComparison.Ordinal);
        Assert.DoesNotContain("Your task: pick the moments", prompt.System, StringComparison.Ordinal);
        Assert.Equal([ClipLook.Original, ClipLook.Muted, ClipLook.Warm, ClipLook.Bw], prompt.Looks);
        Assert.Equal((20.0, 45.0, 60.0), (prompt.Limits.MinTargetSeconds, prompt.Limits.MaxTargetSeconds, prompt.Limits.MaxReasonedSeconds));
        Assert.Equal(new ClipAutopilotFont("Roboto", 900), prompt.Defaults.Font);
        Assert.Equal(TimeSpan.FromSeconds(1200), prompt.MinimumTimeout);
        var required = prompt.Schema["required"]!.AsArray().Select(item => item!.GetValue<string>()).ToArray();
        Assert.Equal(prompt.Schema["properties"]!.AsObject().Count, required.Length);
        Assert.Contains("tone", required);
        Assert.Contains("toneSummary", required);
        Assert.Equal(Sha("prompts/clip-autopilot.json"), prompt.Sha256);
        foreach (var name in new[] { "plan-validation-cases.json", "plan-v2-cases.json", "plan-tone-cases.json" })
            Assert.Equal(prompt.Sha256, Fixture(name)["sources"]!["shared/prompts/clip-autopilot.json"]!.GetValue<string>());
        Assert.Equal(Sha("data/rewrite-tones.json"), Fixture("plan-tone-cases.json")["sources"]!["shared/data/rewrite-tones.json"]!.GetValue<string>());
        // Each fixture's exact top-level keys and case count, as the Mac twin pins them.
        Assert.Equal(["schema", "id", "origin", "sources", "description", "transcript", "rendering", "cases"], Validation().Select(item => item.Key));
        Assert.Equal((11, 14, 11), (Validation()["cases"]!.AsArray().Count, Fixture("plan-v2-cases.json")["cases"]!.AsArray().Count, Fixture("plan-tone-cases.json")["cases"]!.AsArray().Count));
    }

    [Fact]
    public void PromptFileDefectsRefuseToLoad()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(Root, ClipAutopilotPrompt.Path)))!.AsObject();
        _ = new ClipAutopilotPrompt(root.DeepClone().AsObject(), "");
        var broken = root.DeepClone().AsObject();
        broken["momentsSchema"] = new JsonObject { ["type"] = "object", ["additionalProperties"] = false, ["required"] = new JsonArray(), ["properties"] = new JsonObject() };
        Assert.Throws<VoxClipException>(() => new ClipAutopilotPrompt(broken, ""));
        broken = root.DeepClone().AsObject();
        broken["looks"] = new JsonArray(root["looks"]!.AsArray().Where(item => item!["id"]!.GetValue<string>() != "bw").Select(item => item!.DeepClone()).ToArray());
        Assert.Throws<VoxClipException>(() => new ClipAutopilotPrompt(broken, ""));
        broken = root.DeepClone().AsObject();
        broken["system"] = new JsonObject { ["plan"] = new JsonArray("role", "missing"), ["moments"] = new JsonArray("role") };
        Assert.Throws<VoxClipException>(() => new ClipAutopilotPrompt(broken, ""));
        broken = root.DeepClone().AsObject();
        broken["sections"]!["role"] = "Use {unknownLimit} rewrites.";
        Assert.Throws<VoxClipException>(() => new ClipAutopilotPrompt(broken, ""));
    }

    // MARK: Request

    [Theory]
    [InlineData("whole")]
    [InlineData("edited")]
    public void RenderedTranscriptMatchesTheSharedVector(string id)
    {
        var vector = Validation()["rendering"]!.AsArray().Single(item => item!["id"]!.GetValue<string>() == id)!;
        var edits = Edits(vector["edits"]);
        var transcript = Transcript();
        var rendered = ClipAutopilotRequestBuilder.Render(new(transcript, edits, new ClipAutopilotMode.Clip(Range(vector["scope"]))), ClipAutopilotPrompt.Load(Root),
            CaptionStyleLibrary.Load(Root).Styles, ClipAutopilotFonts.Load(Root), EditingAlgorithms.DetectPauses(transcript.Words, 1));
        Assert.EndsWith(vector["transcript"]!.GetValue<string>(), rendered.CachedBlock, StringComparison.Ordinal);
    }

    internal static ClipAutopilotService Service() => new(new LlmRunner(new MemoryKeys(null), AiTestSupport.Catalog(), new Redactor()), AiTestSupport.Catalog(), Root);

    [Fact]
    public void RequestSendsExtraHighEffortWithTheStylesFontsAndPreference()
    {
        var service = Service();
        var input = new ClipAutopilotRequest(Transcript(), Edits(), new ClipAutopilotMode.Clip(new(2, 26)))
            { CaptionPreference = new("karaoke", null, ClipAutopilotCaptionCase.AsSaid), Note = "Keep the laugh." };
        var request = service.Request(input, ConnectorId.ClaudeCode);
        Assert.Equal((Effort.XHigh, LlmFeature.ClipAutopilot, "clip_autopilot_plan", "clip-autopilot"), (request.Effort!.Value, request.Feature, request.SchemaName, request.Tag));
        Assert.True(request.Timeout >= TimeSpan.FromSeconds(1200));
        Assert.Equal(16_000, request.MaxOutputTokens);
        var head = "Language: en\nRecording: 8.3 s\n"
            + "Pace: about 211 words a minute once fillers and pauses are cut, so a 20–45 s clip holds about 70–158 spoken words.\n"
            + "Caption preference: style karaoke; case asSaid. The creator fixed these, so use them exactly and choose the rest per clip."
            + "\n\nCaption styles:\n- vox-bold: Bold.";
        Assert.StartsWith(head, request.CachedBlock, StringComparison.Ordinal);
        Assert.Contains("Fonts:\n- Roboto, weight 900 (default)\n- Anton, weight 400\n", request.CachedBlock, StringComparison.Ordinal);
        Assert.DoesNotContain("[1]um", request.CachedBlock, StringComparison.Ordinal);
        Assert.Contains("0:00 [2]the [3]big", request.CachedBlock, StringComparison.Ordinal);
        Assert.StartsWith("Plan the clip from word 2 to word 26 as one finished, postable short. As recorded it runs 8.3 s; "
            + "with its fillers and pauses cut, about 6.6 s. Land it at 20–45 s after all your cuts. You may tighten", request.Instruction, StringComparison.Ordinal);
        Assert.EndsWith("\n\nThe creator adds: Keep the laugh.", request.Instruction, StringComparison.Ordinal);
        var series = service.Request(new(Transcript(), Edits(), new ClipAutopilotMode.Series(null)), ConnectorId.ClaudeCode);
        var prompt = ClipAutopilotPrompt.Load(Root);
        Assert.Equal(("clip_autopilot_moments", prompt.MomentsSystem, Effort.High, "clip-autopilot-moments", 8_000),
            (series.SchemaName, series.System, series.Effort!.Value, series.Tag, series.MaxOutputTokens));
        Assert.True(JsonNode.DeepEquals(prompt.MomentsSchema, series.Schema));
        Assert.StartsWith("Pick the moments in this video worth posting as clips, at most 12, ranked best first.", series.Instruction, StringComparison.Ordinal);
        Assert.Contains("Recording: 12.0 s\nPace: about ", series.CachedBlock, StringComparison.Ordinal);
        Assert.Contains("\nCaption preference: none; choose what suits each clip\n", series.CachedBlock, StringComparison.Ordinal);
    }

    [Fact]
    public void RequestRefusesAnEmptyScopeABadLanguageAndALongNote()
    {
        var service = Service();
        var transcript = Transcript();
        foreach (var input in new[]
        {
            new ClipAutopilotRequest(transcript, Edits(), new ClipAutopilotMode.Clip(new(16, 16))),
            new ClipAutopilotRequest(transcript, Edits(), new ClipAutopilotMode.Clip(new(20, 40))),
            new ClipAutopilotRequest(transcript, Edits(Enumerable.Range(17, 13).Select(index => "w" + index).ToArray()), new ClipAutopilotMode.Clip(new(16, 29))),
            new ClipAutopilotRequest(transcript, Edits(), new ClipAutopilotMode.Clip(new(0, 29))) { Language = "english!" },
            new ClipAutopilotRequest(transcript, Edits(), new ClipAutopilotMode.Clip(new(0, 29))) { Note = new string('a', 2_001) }
        })
            Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.Request(input, ConnectorId.ClaudeCode)).Kind);
    }

    // MARK: Validation (plan-validation-cases.json)

    [Theory]
    [InlineData("valid-clip")] [InlineData("out-of-range")] [InlineData("overlaps")] [InlineData("unknown-style")] [InlineData("off-style-bundled-font")]
    [InlineData("bridge-words")] [InlineData("rewrite-limit")] [InlineData("malformed")] [InlineData("cut-everything")] [InlineData("span-tightened-no-music")]
    public void ValidatorRepairsOrDropsEachItem(string id)
    {
        var vector = Case(Validation(), id);
        var preference = vector["preference"] is { } wanted ? new ClipAutopilotCaptionPreference(wanted["styleId"]?.GetValue<string>()) : null;
        var plan = ClipAutopilotValidator.Plan(vector["reply"], Context(Range(vector["scope"]), preference: preference))!;
        var expect = vector["expect"]!;
        Assert.Equal(Range(expect["span"]), plan.Span);
        string[][] Cells(string key) => expect[key]!.AsArray().Select(item => item!.AsArray().Select(cell =>
            cell is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : Fixed1(cell!.GetValue<double>())).ToArray()).ToArray();
        Assert.Equal(Cells("cuts"), plan.Cuts.Select(cut => new[] { Fixed1(cut.StartWord), Fixed1(cut.EndWord), cut.Kind.Name() }).ToArray());
        Assert.Equal(expect["pauseCuts"]!.AsArray().Select(item => item!.GetValue<int>()), plan.PauseCuts.Select(pause => pause.AfterWord));
        Assert.Equal(Cells("rewrites"), plan.Rewrites.Select(rewrite => new[] { Fixed1(rewrite.StartWord), Fixed1(rewrite.EndWord), rewrite.Text }).ToArray());
        var captions = expect["captions"]!;
        Assert.Equal((captions["styleId"]!.GetValue<string>(), new ClipAutopilotFont(captions["family"]!.GetValue<string>(), captions["weight"]!.GetValue<int>()),
            captions["case"]!.GetValue<string>(), captions["wordsPerCaption"]!.GetValue<int>()),
            (plan.CaptionChoice.StyleId, plan.CaptionChoice.Font, plan.CaptionChoice.TextCase.Name(), plan.CaptionChoice.WordsPerCaption));
        Assert.Equal(Cells("music"), plan.MusicChoices.Select(music => new[] { music.Title, music.Prompt, Fixed1(music.UnderVoiceDb) }).ToArray());
        Assert.Equal(expect["musicPick"]?.GetValue<int>(), plan.MusicPick);
        Assert.Equal(expect["zooms"]!.AsArray().Select(item => new[] { Fixed1(item![0]!.GetValue<double>()), Fixed1(item[1]!.GetValue<double>()), item[2]!.GetValue<double>().ToString("R", CultureInfo.InvariantCulture) }).ToArray(),
            plan.Zooms.Select(zoom => new[] { Fixed1(zoom.Word), Fixed1(zoom.UntilWord), zoom.Scale.ToString("R", CultureInfo.InvariantCulture) }).ToArray());
        Assert.Equal((expect["title"]!.GetValue<string>(), expect["hook"]!.GetValue<string>(), expect["score"]!.GetValue<int>(), expect["verdict"]!.GetValue<string>(), expect["questions"]!.GetValue<int>()),
            (plan.Title, plan.Hook, plan.Score, plan.Verdict.Name(), plan.Questions.Count));
        Assert.Equal(Expected(expect["repairs"]), Repairs(plan.Repairs));
    }

    [Fact]
    public void MomentsLeaveOutOverlappingShortAndUnreadableClips()
    {
        var vector = Case(Validation(), "series");
        var (moments, repairs) = ClipAutopilotValidator.Moments(vector["reply"], Context(new(0, 29)));
        Assert.Equal(vector["expect"]!["plans"]!.AsArray().Select(item => new[] { item![0]!.GetValue<int>(), item[1]!.GetValue<int>() }).ToArray(),
            moments.Select(moment => new[] { moment.StartWord, moment.EndWord }).ToArray());
        Assert.Equal(Expected(vector["expect"]!["repairs"]), Repairs(repairs));
    }

    [Fact]
    public void MomentsKeepAtMostTheLimitAndAPlanRoundTripsAsJson()
    {
        var context = Context(new(0, 29));
        var first = Reply("valid-clip");
        first["startWord"] = 0; first["endWord"] = 26;
        var clips = new JsonArray(first.DeepClone());
        for (var index = 0; index < 14; index++)
        {
            var later = first.DeepClone().AsObject();
            later["startWord"] = 27; later["endWord"] = 29;
            clips.Add(later);
        }
        var (moments, repairs) = ClipAutopilotValidator.Moments(new JsonObject { ["clips"] = clips }, context);
        Assert.Single(moments);
        Assert.Equal(14, repairs.Count);
        var plan = ClipAutopilotValidator.Plan(Reply("valid-clip"), context)!;
        var text = plan.ToJson().ToJsonString();
        Assert.Contains("\"case\":\"upper\"", text, StringComparison.Ordinal);
        Assert.Equal(text, ClipAutopilotPlan.FromJson(JsonNode.Parse(text)!.AsObject()).ToJson().ToJsonString());
        Assert.Throws<VoxClipException>(() => ClipAutopilotPlan.FromJson(JsonNode.Parse(text.Replace("\"version\":4", "\"version\":5", StringComparison.Ordinal))!.AsObject()));
    }

    [Fact]
    public void AlreadyCutWordsAreNeverListedOrRewritten()
    {
        var context = Context(new(0, 29), Edits(["w19"], ["pause-after-w6"]));
        var reply = new JsonObject
        {
            ["rewrites"] = new JsonArray(new JsonObject { ["startWord"] = 17, ["endWord"] = 23, ["text"] = "You still need to feed the plants", ["reason"] = "" }),
            ["pauseCuts"] = new JsonArray(new JsonObject { ["afterWord"] = 6, ["reason"] = "" }),
            ["zooms"] = new JsonArray(new JsonObject { ["word"] = 19, ["untilWord"] = 20, ["scale"] = 1.2, ["reason"] = "" })
        };
        var plan = ClipAutopilotValidator.Plan(reply, context)!;
        Assert.Empty(plan.Rewrites); Assert.Empty(plan.PauseCuts); Assert.Empty(plan.Zooms);
        Assert.Equal(["pauseCuts[0]", "rewrites[0]", "zooms[0]"], plan.Repairs.Where(repair => repair.Dropped).Select(repair => repair.Field).Order(StringComparer.Ordinal));
    }

    // MARK: Version 2 (plan-v2-cases.json)

    private static ClipAutopilotCaptionPreference? Preference(JsonNode? value) => value is null ? null : new(value["styleId"]?.GetValue<string>(),
        value["fontFamily"] is { } family ? new ClipAutopilotFont(family.GetValue<string>(), value["fontWeight"]?.GetValue<int>() ?? 0) : null,
        ClipAutopilotWire.CaptionCase(value["case"]?.GetValue<string>()));

    private static string Cell(JsonNode? cell) => cell is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : cell!.GetValue<int>().ToString(CultureInfo.InvariantCulture);
    private static string[][] Rows(JsonNode? value) => value!.AsArray().Select(item => item!.AsArray().Select(Cell).ToArray()).ToArray();

    [Theory]
    [InlineData("corrections")] [InlineData("speed-clamped-bw")] [InlineData("speed-slow-clamped")] [InlineData("speed-unreadable-unknown-look")]
    [InlineData("v3-reply-without-new-fields")] [InlineData("over-length")] [InlineData("long-without-reason")] [InlineData("long-with-reason")]
    [InlineData("speed-brings-it-in")] [InlineData("cuts-bring-it-in")] [InlineData("fixed-style")] [InlineData("fixed-font-and-case")]
    public void V2PlanVectorsRepairDropAndFlag(string id)
    {
        var fixture = Fixture("plan-v2-cases.json");
        var vector = Case(fixture, id);
        var plan = ClipAutopilotValidator.Plan(vector["reply"], Context(Transcript(fixture, 75), Range(vector["scope"]), preference: Preference(vector["preference"])))!;
        var expect = vector["expect"]!;
        Assert.Equal(ClipAutopilotPlan.CurrentVersion, plan.Version);
        Assert.Equal(Range(expect["span"]), plan.Span);
        Assert.Equal(Rows(expect["corrections"]), plan.Corrections.Select(item => new[] { item.Word.ToString(CultureInfo.InvariantCulture), item.Heard, item.Text }).ToArray());
        Assert.Equal(Rows(expect["rewrites"]), plan.Rewrites.Select(item => new[] { item.StartWord.ToString(CultureInfo.InvariantCulture), item.EndWord.ToString(CultureInfo.InvariantCulture), item.Text }).ToArray());
        Assert.Equal(Rows(expect["cuts"]), plan.Cuts.Select(item => new[] { item.StartWord.ToString(CultureInfo.InvariantCulture), item.EndWord.ToString(CultureInfo.InvariantCulture), item.Kind.Name() }).ToArray());
        var captions = expect["captions"]!;
        Assert.Equal(new ClipAutopilotPlan.Captions(captions["styleId"]!.GetValue<string>(), new(captions["family"]!.GetValue<string>(), captions["weight"]!.GetValue<int>()),
            ClipAutopilotWire.CaptionCase(captions["case"]!.GetValue<string>())!.Value, captions["wordsPerCaption"]!.GetValue<int>(), captions["reason"]?.GetValue<string>() ?? ""), plan.CaptionChoice);
        Assert.Equal(expect["look"]!.AsArray().Select(item => item!.GetValue<string>()), new[] { plan.ClipLookChoice.Id.Name(), plan.ClipLookChoice.Reason });
        if (expect["speed"] is null) Assert.Null(plan.SpeedChoice);
        else Assert.Equal(new ClipAutopilotPlan.Speed(expect["speed"]![0]!.GetValue<double>(), expect["speed"]![1]!.GetValue<string>()), plan.SpeedChoice);
        Assert.True(Math.Abs(plan.Seconds - expect["seconds"]!.GetValue<double>()) < 1e-9, $"{plan.Seconds} s");
        Assert.Equal(expect["flags"]!.AsArray().Select(item => item!.GetValue<string>()), plan.Flags.Select(flag => flag.Kind));
        Assert.Equal(Expected(expect["repairs"]), Repairs(plan.Repairs));
    }

    [Theory]
    [InlineData("moments")]
    [InlineData("moments-fixed-style")]
    public void V2MomentVectorsKeepTheStrongestSpans(string id)
    {
        var fixture = Fixture("plan-v2-cases.json");
        var vector = Case(fixture, id);
        var (moments, repairs) = ClipAutopilotValidator.Moments(vector["reply"], Context(Transcript(fixture, 75), Range(vector["scope"]), preference: Preference(vector["preference"])));
        var expect = vector["expect"]!;
        Assert.Equal(Rows(expect["moments"]), moments.Select(moment => new[] { moment.StartWord.ToString(CultureInfo.InvariantCulture), moment.EndWord.ToString(CultureInfo.InvariantCulture), moment.Verdict.Name(), moment.CaptionStyle }).ToArray());
        Assert.Equal(expect["scores"]!.AsArray().Select(item => item!.GetValue<int>()), moments.Select(moment => moment.Score));
        Assert.Equal(Expected(expect["repairs"]), Repairs(repairs));
    }

    [Fact]
    public void AVersionOnePlanStillReadsAndIsUpgraded()
    {
        var fixture = Fixture("plan-v2-cases.json");
        var plan = ClipAutopilotValidator.Plan(Case(fixture, "corrections")["reply"], Context(Transcript(fixture, 75), new(0, 29)))!;
        var json = plan.ToJson();
        foreach (var key in new[] { "corrections", "look", "speed", "lengthReason", "seconds", "flags", "tone" }) json.Remove(key);
        json["captions"]!.AsObject().Remove("reason");
        json["version"] = 1;
        var old = ClipAutopilotPlan.FromJson(JsonNode.Parse(json.ToJsonString())!.AsObject());
        Assert.Equal(ClipAutopilotPlan.CurrentVersion, old.Version);
        Assert.Empty(old.Corrections); Assert.Equal(ClipAutopilotPlan.Look.Original, old.ClipLookChoice); Assert.Null(old.SpeedChoice);
        Assert.Equal(0, old.Seconds); Assert.Empty(old.Flags); Assert.Equal("", old.CaptionChoice.Reason);
        Assert.Equal(plan.Cuts, old.Cuts); Assert.Equal(plan.Rewrites, old.Rewrites);
        json["version"] = 5;
        Assert.Throws<VoxClipException>(() => ClipAutopilotPlan.FromJson(JsonNode.Parse(json.ToJsonString())!.AsObject()));
    }

    [Fact]
    public void ASeriesRanksByScoreAndKeepsOnePostFirst()
    {
        var context = Context(new(0, 29));
        var plan = ClipAutopilotValidator.Plan(Reply("valid-clip"), context)!;
        var series = ClipAutopilotValidator.Series([plan with { Score = 7, Verdict = ClipAutopilotVerdict.PostFirst }, null, plan with { Score = 9, Verdict = ClipAutopilotVerdict.PostFirst }],
            [], new Dictionary<int, string> { [1] = "the plan failed: Timeout" }, []);
        Assert.Equal([9, 7], series.Plans.Select(item => item.Score));
        Assert.Equal([ClipAutopilotVerdict.PostFirst, ClipAutopilotVerdict.Post], series.Plans.Select(item => item.Verdict));
        Assert.Contains(series.Repairs, repair => repair.Field == "plans[1]" && repair.Dropped && repair.Detail.Contains("Timeout", StringComparison.Ordinal));
    }

    // MARK: Tone (plan-tone-cases.json)

    private static RewriteToneCatalog Catalog() => RewriteToneCatalog.Load(Root);
    private static RewriteTone[] Saved() => Fixture("plan-tone-cases.json")["savedTones"]!.AsArray()
        .Select(item => new RewriteTone(item!["id"]!.GetValue<string>(), item["title"]!.GetValue<string>(), "", item["instruction"]!.GetValue<string>())).ToArray();

    private static ClipAutopilotTone? Tone(JsonNode? value) => value is null ? null : value["mode"]!.GetValue<string>() switch
    {
        "auto" => new ClipAutopilotTone.Auto(Catalog().Tones),
        "as-said" => new ClipAutopilotTone.AsSaid(),
        "fixed" => new ClipAutopilotTone.Fixed(Catalog().Find(value["id"]!.GetValue<string>(), Saved()) ?? throw new InvalidOperationException("unknown tone")),
        _ => throw new InvalidOperationException("unknown tone mode")
    };

    [Theory]
    [InlineData("fixed-viral")] [InlineData("fixed-other-reply")] [InlineData("fixed-saved")] [InlineData("fixed-long-summary")] [InlineData("auto-picks")]
    [InlineData("auto-none")] [InlineData("auto-unknown")] [InlineData("auto-saved-not-offered")] [InlineData("as-said")] [InlineData("as-said-none")] [InlineData("no-tone")]
    public void TonePlanVectorsKeepRepairOrDropTheTone(string id)
    {
        var vector = Case(Fixture("plan-tone-cases.json"), id);
        var plan = ClipAutopilotValidator.Plan(vector["reply"], Context(Transcript(), new(0, 29), tone: Tone(vector["tone"])))!;
        Assert.Equal(ClipAutopilotPlan.CurrentVersion, plan.Version);
        var expect = vector["expect"]!;
        if (expect["tone"] is null) Assert.Null(plan.ToneChoice);
        else
        {
            var parts = expect["tone"]!.AsArray().Select(item => item!.GetValue<string>()).ToArray();
            Assert.Equal(new ClipAutopilotPlan.Tone(parts[0], parts[1], parts[2]), plan.ToneChoice);
        }
        Assert.Equal(Expected(expect["repairs"]), Repairs(plan.Repairs));
        Assert.Equal([new ClipAutopilotPlan.Rewrite(17, 23, "You still need to feed the plants", "feed is the verb")], plan.Rewrites);
    }

    [Fact]
    public void EachToneModeEndsTheClipInstructionWithItsToneLine()
    {
        var transcript = Transcript();
        string Render(ClipAutopilotTone? tone) => ClipAutopilotRequestBuilder.Render(new(transcript, Edits(), new ClipAutopilotMode.Clip(new(0, 29))) { Tone = tone },
            ClipAutopilotPrompt.Load(Root), CaptionStyleLibrary.Load(Root).Styles, ClipAutopilotFonts.Load(Root), EditingAlgorithms.DetectPauses(transcript.Words, 1)).Instruction;
        var plain = Render(null);
        Assert.DoesNotContain("Tone:", plain, StringComparison.Ordinal);
        var vectors = Fixture("plan-tone-cases.json")["instructions"]!.AsArray();
        Assert.Equal(4, vectors.Count);
        foreach (var vector in vectors) Assert.Equal(plain + vector!["endsWith"]!.GetValue<string>(), Render(Tone(vector["tone"])));
        var series = new ClipAutopilotRequest(transcript, Edits(), new ClipAutopilotMode.Series(null)) { Tone = new ClipAutopilotTone.AsSaid() };
        Assert.DoesNotContain("Tone:", ClipAutopilotRequestBuilder.Render(series, ClipAutopilotPrompt.Load(Root), CaptionStyleLibrary.Load(Root).Styles, ClipAutopilotFonts.Load(Root),
            EditingAlgorithms.DetectPauses(transcript.Words, 1)).Instruction, StringComparison.Ordinal);
        Assert.IsType<ClipAutopilotTone.AsSaid>(series.ForClip(new(0, 29)).Tone);
    }

    [Fact]
    public void VersionTwoPlansReadWithoutATone()
    {
        var first = Fixture("plan-tone-cases.json")["cases"]!.AsArray()[0]!;
        var plan = ClipAutopilotValidator.Plan(first["reply"], Context(Transcript(), new(0, 29), tone: new ClipAutopilotTone.Fixed(Catalog().Tones[0])))!;
        Assert.Equal("viral-youtuber", plan.ToneChoice?.Id);
        var json = plan.ToJson();
        Assert.Equal(json.ToJsonString(), ClipAutopilotPlan.FromJson(JsonNode.Parse(json.ToJsonString())!.AsObject()).ToJson().ToJsonString());
        json.Remove("tone");
        json["version"] = 2;
        var old = ClipAutopilotPlan.FromJson(JsonNode.Parse(json.ToJsonString())!.AsObject());
        Assert.Equal(ClipAutopilotPlan.CurrentVersion, old.Version); Assert.Null(old.ToneChoice); Assert.Equal(plan.Rewrites, old.Rewrites);
    }

    // MARK: Mapping

    [Fact]
    public void PlanMapsToTheEditorsOperationsAndAppliesWhatWindowsRenders()
    {
        var fonts = ClipAutopilotFonts.Load(Root);
        var plan = ClipAutopilotValidator.Plan(Reply("valid-clip"), Context(new(0, 29)))! with { StartWord = 2 };
        var project = Project(cut: ["w9"]);
        var operations = ClipAutopilotMapping.Operations(plan, "c1", project, fonts);
        Assert.Equal(["clip", "title", "cut-0", "cut-2", "pause-0", "rewrite-0", "captions", "look", "zoom-0", "music", "hook", "post"], operations.Select(item => item.Id));
        Assert.Equal(new EditOperation.UpdateClip("c1", 2, 29), ((ClipAutopilotAction.Edit)operations[0].Action).Operation);
        Assert.Equal(new EditOperation.RenameClip("c1", "Coffee is great"), ((ClipAutopilotAction.Edit)operations[1].Action).Operation);
        Assert.Equal(["w1"], ((EditOperation.SetWordCuts)((ClipAutopilotAction.Edit)operations[2].Action).Operation).Ids);
        Assert.Equal(["pause-after-w6"], ((EditOperation.SetPauseCuts)((ClipAutopilotAction.Edit)operations[4].Action).Operation).Ids);
        Assert.Equal(new ClipAutopilotAction.Rewrite(new(17, 23), "You still need to feed the plants"), operations[5].Action);
        var captions = (ClipAutopilotAction.Captions)operations[6].Action;
        Assert.Equal("vox-bold", captions.Settings.StyleId);
        Assert.Null(captions.PendingFont);
        AiTestSupport.EqualJson(JsonNode.Parse("{\"text\":{\"transform\":\"uppercase\"},\"layout\":{\"maxWords\":3},\"font\":{\"file\":" + JsonValue.Create(fonts[new("Roboto", 900)])!.ToJsonString() + ",\"family\":\"Roboto\",\"weight\":900}}"),
            JsonNode.Parse(captions.Settings.Overrides.GetRawText()));
        Assert.Equal(new ClipAutopilotAction.Look("c1", ClipAutopilotPlan.Look.Original), operations[7].Action);
        var cue = ((ClipAutopilotAction.Motion)operations[8].Action).Cue;
        Assert.Equal(("c1", 4.9, 5.9), (cue.ClipID, cue.SourceStart, cue.SourceEnd));
        var music = ((ClipAutopilotAction.Music)operations[9].Action).Cue;
        Assert.Equal("Pulse", music.Picked.Title);
        Assert.Equal(["Glass", "Grit"], music.Alternatives.Select(item => item.Title));
        var (applied, pending) = ClipAutopilotMapping.Apply(operations, project);
        Assert.Equal(["w1", "w9", "w11"], applied.Edits.CutWordIds);
        Assert.Equal(["pause-after-w6"], applied.Edits.CutPauseIds);
        Assert.Equal(("w2", "Coffee is great"), (applied.Edits.Clips[0].StartWordId, applied.Edits.Clips[0].Title));
        Assert.Equal("vox-bold", applied.Captions.StyleId);
        Assert.Equal("Coffee is great. Sleep is better.", applied.Share.Captions["c1"]);
        // The zoom applies as the clip's motion cue (the project becomes v4, as on the Mac); rewrites and music need a paid voice or a source.
        Assert.Equal([ClipAutopilotDecision.Rewrite, ClipAutopilotDecision.Music], pending.Select(item => item.Decision));
        Assert.Equal([cue], applied.MotionCues);
        Assert.Equal(4, applied.SchemaVersion);
        var card = ClipHookTitle.Existing("c1", applied)!.Value;
        Assert.Equal(("title", plan.Hook, "top", "c1"), (card.GetProperty("kind").GetString(), card.GetProperty("text").GetString(), card.GetProperty("position").GetString(), card.GetProperty("clipId").GetString()));
        ProjectSerialization.Validate(applied);
        Assert.Equal(applied.Edits.Clips.Select(clip => clip.Id), ProjectSerialization.Deserialize(ProjectSerialization.Serialize(applied)).Edits.Clips.Select(clip => clip.Id));
    }

    [Fact]
    public void CorrectionsMapToTheCorrectOperationAndTheLookAndSpeedApply()
    {
        var reply = Reply("valid-clip");
        reply["corrections"] = new JsonArray(new JsonObject { ["word"] = 13, ["heard"] = "sleep", ["text"] = "Sleep", ["reason"] = "name" });
        reply["look"] = "warm"; reply["lookReason"] = "a human moment"; reply["speed"] = 1.2; reply["speedReason"] = "drags";
        var plan = ClipAutopilotValidator.Plan(reply, Context(new(0, 29)))!;
        var project = Project();
        var operations = ClipAutopilotMapping.Operations(plan, "c1", project, ClipAutopilotFonts.Load(Root));
        Assert.Equal(["title", "correction-0", "cut-0"], operations.Take(3).Select(item => item.Id));
        Assert.Equal(new EditOperation.Correct("w13", "Sleep"), ((ClipAutopilotAction.Edit)operations[1].Action).Operation);
        Assert.Equal(new ClipAutopilotAction.Look("c1", new(ClipLook.Warm, "a human moment")), operations.Single(item => item.Decision == ClipAutopilotDecision.Look).Action);
        Assert.Equal(new ClipAutopilotAction.Speed("c1", new(1.2, "drags")), operations.Single(item => item.Decision == ClipAutopilotDecision.Speed).Action);
        var (applied, _) = ClipAutopilotMapping.Apply(operations, project);
        Assert.Equal("Sleep", applied.Edits.Corrections["w13"]);
        Assert.Equal([new ProjectClipControls("c1", 1.2, null, ClipLook.Warm, 0, 0, 0, false, false, 0)], applied.ClipControls);
        ProjectSerialization.Validate(applied);
        var state = EditingEngine.FromProject(Project(clips: []))!;
        Assert.True(Math.Abs(ClipAutopilotMapping.FinalSeconds(plan, state) - 9.75 / 1.2) < 1e-9);
        Assert.True(Math.Abs(plan.Seconds - 9.75 / 1.2) < 1e-9);
        Assert.True(Math.Abs(ClipAutopilotMapping.EditedSeconds(ClipAutopilotValidator.Plan(Reply("valid-clip"), Context(new(0, 29)))!, state) - 9.75) < 1e-9);
    }

    [Fact]
    public void ABundledFontBecomesAnOverrideAndASeriesClipIsAdded()
    {
        var plan = ClipAutopilotValidator.Plan(Reply("off-style-bundled-font"), Context(new(0, 29)))!;
        var project = Project(clips: []);
        var operations = ClipAutopilotMapping.Operations(plan, "autopilot-1", project, ClipAutopilotFonts.Load(Root));
        var clip = ((EditOperation.AddClip)((ClipAutopilotAction.Edit)operations[0].Action).Operation).Clip;
        Assert.Equal(("autopilot-1", ClipOrigin.Ai, "Coffee is great"), (clip.Id, clip.Origin, clip.Title));
        var captions = (ClipAutopilotAction.Captions)operations.Single(item => item.Decision == ClipAutopilotDecision.Captions).Action;
        Assert.Null(captions.PendingFont);
        AiTestSupport.EqualJson(JsonNode.Parse("{\"text\":{\"transform\":\"none\"},\"layout\":{\"maxWords\":1,\"maxLines\":1},\"font\":{\"file\":\"Montserrat-Black.ttf\",\"family\":\"Montserrat\",\"weight\":900}}"),
            JsonNode.Parse(captions.Settings.Overrides.GetRawText()));
        var applied = ClipAutopilotMapping.Apply(operations, project).Project;
        Assert.Equal(["autopilot-1"], applied.Edits.Clips.Select(item => item.Id));
        ProjectSerialization.Validate(applied);
        Assert.Throws<VoiceLabException>(() => ClipAutopilotMapping.Operations(plan, "-bad id", project, new Dictionary<ClipAutopilotFont, string>()));
    }

    // MARK: Hook title card (ClipHookTitleTests)

    private static Project HookProject() =>
        Project([new ClipRange("c1", "w2", "w29", "Coffee", ClipOrigin.Manual, null, null, true)], ["w1", "w9", "w11"], ["pause-after-w6"]);

    [Fact]
    public void TheHookCardCoversTheFirstTwoRenderedSecondsAndShowsWholeOnTheFirstFrame()
    {
        var project = HookProject();
        var card = ClipHookTitle.Effect("Sleep beats coffee", "c1", project)!.Value;
        Assert.Equal(("fx-hook-1", "title", "c1", "Sleep beats coffee", "top"), (card.GetProperty("id").GetString(), card.GetProperty("kind").GetString(),
            card.GetProperty("clipId").GetString(), card.GetProperty("text").GetString(), card.GetProperty("position").GetString()));
        Assert.True(ClipHookTitle.IsHook(card));
        var timeline = ClipHookTitle.Timeline(project, "c1")!;
        var first = timeline.SourceTime(0);
        Assert.True(first <= 0.6);
        Assert.True(Math.Abs(card.GetProperty("start").GetDouble() - (first - ClipEffect.OverlayFadeSeconds)) < 1e-9);
        Assert.True(Math.Abs(timeline.MapTime(card.GetProperty("end").GetDouble()) - 2) < 0.001, "two edited seconds from the clip's start");
        Assert.True(card.GetProperty("end").GetDouble() > 3.1, "the tightened pause is skipped");
        ClipEffects.Validate(ClipEffects.Adding([card], project));
    }

    [Fact]
    public void AFasterClipShowsTheHookForTwoRenderedSecondsAndARunReplacesItsCard()
    {
        var project = ClipControlsProject.SettingSpeed(1.25, "c1", HookProject());
        var card = ClipHookTitle.Effect("Sleep beats coffee", "c1", project)!.Value;
        Assert.True(Math.Abs(ClipHookTitle.Timeline(project, "c1")!.MapTime(card.GetProperty("end").GetDouble()) - 2.5) < 0.001);
        project = ClipEffects.Adding([card], project);
        var again = ClipHookTitle.Effect("  Coffee\nis a loan  ", "c1", project)!.Value;
        Assert.Equal((card.GetProperty("id").GetString(), "Coffee is a loan"), (again.GetProperty("id").GetString(), again.GetProperty("text").GetString()));
        Assert.Null(ClipHookTitle.Effect(" \n ", "c1", project));
        Assert.Null(ClipHookTitle.Effect("Hook", "missing", project));
        Assert.Equal(80, ClipHookTitle.Text(new string('a', 100))!.Length);
    }

    [Fact]
    public void AHookOnAClipShorterThanTwoSecondsShowsToItsEnd()
    {
        var project = Project([new ClipRange("c2", "w2", "w4", "Short", ClipOrigin.Manual, null, null, true)]);
        var card = ClipHookTitle.Effect("Short", "c2", project)!.Value;
        Assert.True(Math.Abs(card.GetProperty("end").GetDouble() - 1.3) < 1e-9);
    }

    // MARK: Pricing

    [Fact]
    public void PriceAddsTheVoiceAndTheMusicAndNothingForAPlanSend()
    {
        var plan = ClipAutopilotValidator.Plan(Reply("valid-clip"), Context(new(0, 29)))!;
        var voice = VoiceLabPriceCatalog.Parse(File.ReadAllBytes(Path.Combine(Root, "catalog", "voice-lab.json")));
        var music = ClipAutopilotPricing.LoadMusicCatalog(Root);
        var price = ClipAutopilotPricing.Price(plan, "eleven_v3", 1, voice, music, 9.75, ConnectorId.ClaudeCode, CliSignIn.Plan);
        Assert.Equal((33.0, 0.00264m, 10.0, 0.025m, 0.02764m, true), (price.Voice!.Units, price.Voice.Usd, price.Music!.Units, price.Music.Usd, price.Usd, price.LlmIsFree));
        Assert.False(ClipAutopilotPricing.Price(plan, "eleven_v3", 1, voice, music, 9.75, ConnectorId.ClaudeCode, null).LlmIsFree);
        Assert.False(ClipAutopilotPricing.Price(plan, "eleven_v3", 1, voice, music, 9.75, ConnectorId.Anthropic, null).LlmIsFree);
        Assert.True(ClipAutopilotPricing.Price(plan, "eleven_v3", 1, voice, music, 9.75, ConnectorId.Ollama, null).LlmIsFree);
        var unknown = ClipAutopilotPricing.Price(plan, "eleven_v3", 1, voice, null, 9.75, ConnectorId.ClaudeCode, CliSignIn.Plan);
        Assert.Null(unknown.Music!.Usd); Assert.Null(unknown.Usd);
        var bare = ClipAutopilotPricing.Price(plan with { Rewrites = [], MusicPick = null }, "eleven_v3", 1, voice, music, 9.75, ConnectorId.ClaudeCode, CliSignIn.Plan);
        Assert.Equal((null, null, 0m), (bare.Voice, bare.Music, bare.Usd));
    }

    // MARK: Service

    internal static ScriptedConnector Stub(params string[] replies)
    {
        var queue = new Queue<string>(replies);
        return new(ConnectorId.Ollama, (request, model, ct) => Task.FromResult(new RawCompletion(queue.Count == 0 ? "" : queue.Dequeue(), null, model, new StopKind.Complete(), null, null)));
    }

    [Fact]
    public async Task ServicePlansThroughTheRunnerAndChecksTheReply()
    {
        var stub = Stub("not json", Sendable(Reply("overlaps")).ToJsonString());
        var result = await Service().PlanAsync(new(Transcript(), Edits(), new ClipAutopilotMode.Clip(new(0, 29))), stub, "fixture", ct: TestContext.Current.CancellationToken);
        Assert.Equal((1, 2), (result.Plan!.Rewrites.Count, result.Plan.Cuts.Count));
        Assert.Equal((9, 64), (result.PromptVersion, result.PromptSha256.Length));
        Assert.Equal(2, stub.Requests.Count);
        Assert.All(stub.Requests, request => Assert.Equal((Effort.XHigh, LlmFeature.ClipAutopilot), (request.Effort!.Value, request.Feature)));
        Assert.Contains("Your previous reply was not valid JSON", stub.Requests[1].Instruction, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ServiceSeriesDropsTypeInvalidMomentsAndPlansTheRest()
    {
        var moment = new JsonObject { ["startWord"] = 0, ["endWord"] = 29, ["title"] = "Coffee", ["idea"] = "Sleep wins.", ["captionStyle"] = "karaoke", ["captionReason"] = "",
            ["score"] = 8, ["verdict"] = "post", ["scoreReason"] = "" };
        var reply = new JsonObject { ["clips"] = new JsonArray(new JsonObject { ["startWord"] = "x" }, moment) };
        var stub = Stub(reply.ToJsonString(), Sendable(Reply("valid-clip")).ToJsonString());
        var result = await Service().PlanAsync(new(Transcript(), Edits(), new ClipAutopilotMode.Series(null)), stub, "fixture", ct: TestContext.Current.CancellationToken);
        Assert.Equal(1, result.DroppedItems);
        Assert.Equal([0], result.Series.Moments.Select(item => item.StartWord));
        Assert.Equal([0], result.Series.Plans.Select(item => item.StartWord));
        Assert.Equal(["clip_autopilot_moments", "clip_autopilot_plan"], stub.Requests.Select(request => request.SchemaName));
    }

    [Fact]
    public async Task ServiceFailsOnlyWhenTheReplyIsNeverJson()
    {
        var error = await Assert.ThrowsAsync<LlmException>(() => Service().PlanAsync(new(Transcript(), Edits(), new ClipAutopilotMode.Clip(new(0, 29))), Stub("no", "still no"), "fixture",
            ct: TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.InvalidOutput, error.Error.Kind);
    }

    /// <summary>Three spans on three lanes: every send waits until three are in flight (a deadlock fails at the one-minute guard),
    /// the fourth lane is never used, a failed plan is left out, and the plans rank by score.</summary>
    [Fact]
    public async Task ClipsPlanThreeAtOnceAndLeaveOutAFailedPlan()
    {
        var ct = TestContext.Current.CancellationToken;
        var inFlight = 0;
        var allThree = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var good = Sendable(Reply("valid-clip"));
        async Task<RawCompletion> Respond(LlmRequest request, string model, CancellationToken token)
        {
            if (Interlocked.Increment(ref inFlight) == 3) allThree.TrySetResult();
            await allThree.Task.WaitAsync(TimeSpan.FromMinutes(1), token);
            if (request.Instruction.Contains("word 27 to word 29", StringComparison.Ordinal)) return new("never json", null, model, new StopKind.Complete(), null, null);
            var reply = good.DeepClone().AsObject();
            var span = System.Text.RegularExpressions.Regex.Match(request.Instruction, "from word (\\d+) to word (\\d+)");
            reply["startWord"] = int.Parse(span.Groups[1].Value, CultureInfo.InvariantCulture);
            reply["endWord"] = int.Parse(span.Groups[2].Value, CultureInfo.InvariantCulture);
            reply["score"] = reply["startWord"]!.GetValue<int>() == 0 ? 6 : 9;
            return new(reply.ToJsonString(), null, model, new StopKind.Complete(), null, null);
        }
        var lanes = Enumerable.Range(0, 4).Select(_ => new ScriptedConnector(ConnectorId.Ollama, Respond)).ToArray();
        var progress = new List<ClipAutopilotProgress>();
        var result = await Service().PlanAsync(new(Transcript(), Edits(), new ClipAutopilotMode.Clips([new(0, 6), new(7, 15), new(27, 29)])), lanes[0], "fixture",
            lanes[1..], item => { lock (progress) progress.Add(item); }, ct);
        Assert.Empty(lanes[3].Requests);
        Assert.Equal([7, 0], result.Series.Plans.Select(plan => plan.StartWord));
        Assert.Contains(result.Series.Repairs, repair => repair.Field == "plans[2]" && repair.Dropped);
        Assert.Equal(3, progress.OfType<ClipAutopilotProgress.Planning>().Count());
        Assert.Single(progress.OfType<ClipAutopilotProgress.Failed>());
        await Assert.ThrowsAsync<VoiceLabException>(() => Service().PlanAsync(new(Transcript(), Edits(), new ClipAutopilotMode.Clips([new(0, 6)])), lanes[0], "fixture",
            [new ScriptedConnector(ConnectorId.ClaudeCode, Respond)], ct: ct));
    }

    [Fact]
    public async Task StoppingARunCancelsEveryLane()
    {
        using var stop = new CancellationTokenSource();
        var started = 0;
        async Task<RawCompletion> Respond(LlmRequest request, string model, CancellationToken token)
        {
            if (Interlocked.Increment(ref started) == 2) await stop.CancelAsync();
            await Task.Delay(Timeout.Infinite, token);
            throw new InvalidOperationException("unreachable");
        }
        var error = await Assert.ThrowsAsync<LlmException>(() => Service().PlanAsync(new(Transcript(), Edits(), new ClipAutopilotMode.Clips([new(0, 6), new(7, 15)])),
            new ScriptedConnector(ConnectorId.Ollama, Respond), "fixture", [new ScriptedConnector(ConnectorId.Ollama, Respond)], ct: stop.Token));
        Assert.Equal(LlmErrorKind.Cancelled, error.Error.Kind);
    }
}
