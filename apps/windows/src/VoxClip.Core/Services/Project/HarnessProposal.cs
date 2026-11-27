using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Core.Services.Project;

/// <summary>A project harness refusal safe to return to the agent.</summary>
/// <param name="message">The user-facing reason.</param>
public class HarnessException(string message) : Exception(message);

/// <summary>A reducer refusal to display on the affected proposal row.</summary>
public sealed class HarnessTimelineEditException(string message) : HarnessException(message);

/// <summary>Validated local edit intent in the shared harness timeline format.</summary>
public sealed class HarnessTimeline
{
    private static readonly string[] LegacyKeys = ["clipId", "reason", "cuts", "captionStyle", "title", "musicTrackId", "generateMusic", "effects"];
    private static readonly string[] Keys = [.. LegacyKeys, "newClip", "parts", "pauseCuts", "corrections", "font", "case",
        "wordsPerCaption", "look", "speed", "hook", "postText", "coverTitle", "music", "rewrites", "edits"];

    private HarnessTimeline(JsonElement wire, ClipProposal proposal) { Wire = wire.Clone(); Proposal = proposal; }

    internal JsonElement Wire { get; }
    internal ClipProposal Proposal { get; }
    internal IReadOnlyList<TimelineEditRequest> Edits { get; private init; } = [];
    /// <summary>The companion this timeline adds before applying its other edits.</summary>
    public string? RecordingKey { get; private init; }
    internal string? RecordingRevision { get; private init; }
    internal bool UsesFootage => Proposal.Effects?.Any(effect => effect.Kind is "bRoll" or "screenshot" or "videoStack") == true;

    /// <summary>The optional music brief, for estimating only.</summary>
    public string? GenerateMusic => Proposal.Music?.Brief;

    /// <summary>Reject unknown fields and unsupported entries before resolving any anchors.</summary>
    public static HarnessTimeline Read(JsonElement wire) => Read(wire, legacy: false);

    /// <summary>Read one timeline or an envelope containing up to six timelines.</summary>
    public static IReadOnlyList<HarnessTimeline> ReadSeries(JsonElement wire)
    {
        if (wire.ValueKind != JsonValueKind.Object || !wire.TryGetProperty("timelines", out _)) return [Read(wire)];
        RequireObject(wire, ["timelines"]);
        return Items(wire, "timelines", 6).Select(Read).ToArray();
    }

    internal static HarnessTimeline Read(JsonElement wire, bool legacy)
    {
        RequireObject(wire, legacy ? LegacyKeys : Keys);
        var clipId = Text(wire, "clipId");
        ClipProposal.NewClip? create = null;
        if (wire.TryGetProperty("newClip", out var newClip))
        {
            RequireObject(newClip, ["kind", "title"]);
            var kind = Text(newClip, "kind");
            if (kind is not ("stretch" or "story" or "showreel")) throw InvalidTimeline();
            create = new(kind, Text(newClip, "title", 120) ?? throw InvalidTimeline());
        }
        if ((clipId is null) == (create is null) || wire.EnumerateObject().Count() < 3) throw InvalidTimeline();
        var edits = new List<TimelineEditRequest>();
        string? recordingKey = null;
        string? recordingRevision = null;
        if (wire.TryGetProperty("edits", out _))
        {
            foreach (var item in Items(wire, "edits", TimelineEditRequest.Maximum))
            {
                if (item.ValueKind == JsonValueKind.Object && Text(item, "op") == "useRecording")
                {
                    RequireObject(item, ["op", "key", "transcriptRevision"]);
                    if (recordingKey is not null || Text(item, "key") is not { } key || !HarnessRecording.ValidKey(key)) throw InvalidTimeline();
                    recordingRevision = Text(item, "transcriptRevision");
                    if (item.TryGetProperty("transcriptRevision", out _) && (recordingRevision is null || !HarnessRecording.ValidKey(recordingRevision)))
                        throw InvalidTimeline();
                    recordingKey = key;
                }
                else edits.Add(new TimelineEditRequest(item));
            }
        }
        if (create is not null && edits.Count != 0) throw InvalidTimeline();
        var parts = ReadItems(wire, "parts", 12, ["startWord", "endWord"], part => new ClipProposal.Part(Anchor(part, "startWord"), Anchor(part, "endWord")));
        if (create is not null && (create.Kind == "stretch" ? parts?.Count != 1 : (parts?.Count ?? 0) < 2)) throw InvalidTimeline();
        var track = Text(wire, "musicTrackId");
        var brief = Text(wire, "generateMusic", 500);
        ClipPlanMusicShape? shape = null;
        if (wire.TryGetProperty("music", out var music))
        {
            if (track is not null || brief is not null) throw InvalidTimeline();
            RequireObject(music, ["trackId", "brief", .. ClipPlanMusicShape.Keys]);
            try { shape = ClipPlanMusicShape.Read(JsonNode.Parse(music.GetRawText())); }
            catch (JsonException exception) { throw new HarnessException(exception.Message); }
            track = Text(music, "trackId");
            brief = Text(music, "brief", 500);
            if ((track is null) == (brief is null)) throw InvalidTimeline();
        }
        else if (track is not null && brief is not null) throw InvalidTimeline();

        ClipAutopilotFont? font = null;
        if (wire.TryGetProperty("font", out var fontChoice))
        {
            RequireObject(fontChoice, ["family", "weight"]);
            var weight = Anchor(fontChoice, "weight");
            if (weight is < 100 or > 900) throw InvalidTimeline();
            font = new(Text(fontChoice, "family", 80) ?? throw InvalidTimeline(), weight);
        }
        ClipAutopilotPlan.Look? look = null;
        if (wire.TryGetProperty("look", out var lookChoice))
        {
            RequireObject(lookChoice, ["id", "reason"]);
            look = new(Text(lookChoice, "id") switch
            {
                "original" => ClipLook.Original, "muted" => ClipLook.Muted, "warm" => ClipLook.Warm, "bw" => ClipLook.Bw,
                _ => throw InvalidTimeline()
            }, Text(lookChoice, "reason", 240) ?? "");
        }
        ClipAutopilotPlan.Speed? speed = null;
        if (wire.TryGetProperty("speed", out var speedChoice))
        {
            RequireObject(speedChoice, ["rate", "reason"]);
            if (!speedChoice.TryGetProperty("rate", out var rate) || rate.ValueKind != JsonValueKind.Number || rate.GetDouble() is not (>= 0.5 and <= 2))
                throw InvalidTimeline();
            speed = new(rate.GetDouble(), Text(speedChoice, "reason", 240) ?? "");
        }
        var words = wire.TryGetProperty("wordsPerCaption", out _) ? Index(wire, "wordsPerCaption") ?? throw InvalidTimeline() : (int?)null;
        if (words is < 1 or > 12) throw InvalidTimeline();
        return new(wire, new(new(ClipId: clipId, New: create), Reason(wire))
        {
            Parts = parts, CaptionStyle = Text(wire, "captionStyle"), Font = font, WordsPerCaption = words, Look = look, Speed = speed,
            TextCase = Text(wire, "case") switch
            {
                null => null, "upper" => ClipAutopilotCaptionCase.Upper, "lower" => ClipAutopilotCaptionCase.Lower,
                "asSaid" => ClipAutopilotCaptionCase.AsSaid, _ => throw InvalidTimeline()
            },
            Hook = Text(wire, "hook", 80), Title = Text(wire, "title", 120), PostText = Text(wire, "postText", 500),
            CoverTitle = Text(wire, "coverTitle", 80), Music = track is not null || brief is not null ? new(track, brief) { Shape = shape } : null,
            Cuts = ReadItems(wire, "cuts", 30, ["startWord", "endWord", "kind", "reason"], ReadCut),
            PauseCuts = ReadItems(wire, "pauseCuts", 30, ["afterWord", "reason"], entry => new ClipAutopilotPlan.PauseCut(Anchor(entry, "afterWord"), Reason(entry))),
            Corrections = ReadItems(wire, "corrections", 30, ["word", "heard", "text", "reason"], entry => new ClipAutopilotPlan.Correction(Anchor(entry, "word"),
                Text(entry, "heard", 120) ?? throw InvalidTimeline(), Text(entry, "text", 120) ?? throw InvalidTimeline(), Reason(entry))),
            Rewrites = ReadItems(wire, "rewrites", 12, ["startWord", "endWord", "text", "reason"], entry => new ClipAutopilotPlan.Rewrite(Anchor(entry, "startWord"),
                Anchor(entry, "endWord"), Text(entry, "text", 2000) ?? throw InvalidTimeline(), Reason(entry))),
            Effects = wire.TryGetProperty("effects", out _) ? Items(wire, "effects", ClipPlanEffect.MaximumEntries).Select(ReadEffect).ToArray() : null,
        }) { Edits = edits, RecordingKey = recordingKey, RecordingRevision = recordingRevision };
    }

    /// <summary>Pin the recording words reviewed during staging.</summary>
    public HarnessTimeline PinRecordingTranscript(Transcript transcript)
    {
        if (RecordingKey is null || RecordingRevision is not null) return this;
        var timeline = JsonNode.Parse(Wire.GetRawText())!.AsObject();
        var operation = timeline["edits"]!.AsArray().Single(item => item?["op"]?.GetValue<string>() == "useRecording")!;
        operation["transcriptRevision"] = TranscriptRevision(transcript);
        using var pinned = JsonDocument.Parse(timeline.ToJsonString());
        return Read(pinned.RootElement);
    }

    internal static string TranscriptRevision(Transcript transcript) =>
        Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(transcript, ProjectJsonContext.Default.Transcript)));

    private static IReadOnlyList<T>? ReadItems<T>(JsonElement wire, string key, int maximum, string[] keys, Func<JsonElement, T> read) =>
        wire.TryGetProperty(key, out _) ? Items(wire, key, maximum).Select(item => { RequireObject(item, keys); return read(item); }).ToArray() : null;

    /// <summary>Accept only a JSON object with named, non-null, non-duplicate arguments.</summary>
    public static void RequireObject(JsonElement value, IReadOnlyCollection<string> keys)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Any(field =>
            !keys.Contains(field.Name) || !seen.Add(field.Name) || field.Value.ValueKind == JsonValueKind.Null))
            throw new HarnessException("Unexpected or null argument.");
    }

    private static ClipAutopilotPlan.Cut ReadCut(JsonElement cut) => new(Anchor(cut, "startWord"), Anchor(cut, "endWord"), Text(cut, "kind") switch
    {
        "filler" => ClipAutopilotCutKind.Filler, "stumble" => ClipAutopilotCutKind.Stumble, "repeat" => ClipAutopilotCutKind.Repeat,
        "falseStart" => ClipAutopilotCutKind.FalseStart, "tangent" => ClipAutopilotCutKind.Tangent, "other" => ClipAutopilotCutKind.Other,
        _ => throw InvalidTimeline()
    }, Reason(cut));

    private static int Anchor(JsonElement entry, string key) => Index(entry, key) ?? throw InvalidTimeline();
    private static string Reason(JsonElement entry) => Text(entry, "reason", 240) ?? throw InvalidTimeline();

    private static ClipPlanEffect ReadEffect(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object || item.EnumerateObject().Count() != 5 ||
            item.EnumerateObject().Select(field => field.Name).Distinct(StringComparer.Ordinal).Count() != 5 ||
            ClipPlanEffect.Read(JsonNode.Parse(item.GetRawText())) is not { } effect)
            throw InvalidTimeline();
        return effect;
    }

    private static int? Index(JsonElement value, string key) => value.TryGetProperty(key, out var field) &&
        field.ValueKind == JsonValueKind.Number && field.GetDouble() is >= 0 and <= int.MaxValue and var number &&
        double.IsInteger(number) ? (int)number : null;

    private static string? Text(JsonElement value, string key, int? maximum = null)
    {
        if (!value.TryGetProperty(key, out var field)) return null;
        if (field.ValueKind != JsonValueKind.String || field.GetString() is not { Length: > 0 } text ||
            (maximum is { } limit && (text != text.Trim() || text.EnumerateRunes().Count() > limit || text.EnumerateRunes().Any(rune =>
                Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator))))
            throw InvalidTimeline();
        return text;
    }

    private static IEnumerable<JsonElement> Items(JsonElement value, string key, int maximum)
    {
        if (!value.TryGetProperty(key, out var field)) return [];
        if (field.ValueKind != JsonValueKind.Array || field.GetArrayLength() < 1 || field.GetArrayLength() > maximum)
            throw InvalidTimeline();
        return field.EnumerateArray();
    }

    private static HarnessException InvalidTimeline() => new("Invalid timeline. Give a clip or new clip, a reason and at least one supported change.");
}

/// <summary>A versioned sidecar proposal pinned to a project and its editable revision.</summary>
public sealed class HarnessProposal
{
    /// <summary>Byte limit for one request or sidecar.</summary>
    public const int MaximumBytes = 128 * 1024;
    private readonly int version;
    private readonly IReadOnlyList<HarnessTimeline> timelines;
    private Guid Id { get; }
    private string ProjectId { get; }
    private string BaseRevision { get; }

    /// <summary>Pin one timeline to the saved base snapshot.</summary>
    public HarnessProposal(HarnessTimeline timeline, Domain.Shared.Project project) : this([timeline], project) { }

    /// <summary>Pin a series of timelines to the saved base snapshot.</summary>
    public HarnessProposal(IReadOnlyList<HarnessTimeline> timelines, Domain.Shared.Project project) : this(Guid.NewGuid(), timelines, project) { }

    private HarnessProposal(Guid id, IReadOnlyList<HarnessTimeline> timelines, Domain.Shared.Project project)
        : this(2, id, project.Id, Revision(project, timelines, 2), timelines) { }

    private HarnessProposal(int version, Guid id, string projectId, string baseRevision, IReadOnlyList<HarnessTimeline> timelines)
    {
        if (timelines.Count is < 1 or > 6) throw new HarnessException("Propose one to six timelines.");
        this.version = version;
        Id = id;
        ProjectId = projectId;
        BaseRevision = baseRevision;
        this.timelines = timelines.ToArray();
    }

    /// <summary>The first timeline's original wire intent.</summary>
    public JsonElement Timeline => timelines[0].Wire;

    /// <summary>The validated canonical intent for each timeline.</summary>
    public IReadOnlyList<ClipProposal> Timelines => timelines.Select(timeline => timeline.Proposal).ToArray();

    /// <summary>The existing clip ID, or a stable ID for the clip to be created.</summary>
    public string ClipIdAt(int index)
    {
        var timeline = timelines[index];
        if (timeline.Proposal.Target.ClipId is { } existing) return existing;
        using var bytes = new MemoryStream();
        using (var writer = new Utf8JsonWriter(bytes)) WriteCanonical(JsonNode.Parse(timeline.Wire.GetRawText()), writer);
        return $"harness-{Id:D}-{Convert.ToHexStringLower(SHA256.HashData(bytes.GetBuffer().AsSpan(0, (int)bytes.Length)))[..12]}";
    }

    /// <summary>The original wire intent for a timeline's review.</summary>
    public JsonElement TimelineAt(int index) => timelines[index].Wire;

    /// <summary>The companion the timeline adds, if any.</summary>
    public string? RecordingKeyAt(int index) => timelines[index].RecordingKey;

    /// <summary>Whether the proposed indices were validated against a particular cached transcript.</summary>
    public bool HasPinnedRecordingTranscriptAt(int index) => timelines[index].RecordingRevision is not null;

    internal static HarnessProposal Read(JsonElement wire)
    {
        HarnessTimeline.RequireObject(wire, ["version", "id", "projectId", "baseRevision", "timeline", "timelines"]);
        if (!wire.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || version.GetDouble() is not (1 or 2) ||
            !wire.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String || !Guid.TryParseExact(id.GetString(), "D", out var proposalId) ||
            !wire.TryGetProperty("projectId", out var project) || project.ValueKind != JsonValueKind.String || project.GetString() is not { Length: > 0 } projectId ||
            !wire.TryGetProperty("baseRevision", out var revision) || revision.ValueKind != JsonValueKind.String || revision.GetString() is not { Length: 64 } digest ||
            digest.Any(character => character is not (>= '0' and <= '9' or >= 'a' and <= 'f')))
            throw new HarnessException("This timeline proposal can't be read.");
        var legacy = wire.TryGetProperty("timeline", out var change);
        var series = wire.TryGetProperty("timelines", out var changes);
        return version.GetDouble() switch
        {
            1 when legacy && !series => new(1, proposalId, projectId, digest, [HarnessTimeline.Read(change, legacy: true)]),
            2 when !legacy && series && changes.ValueKind == JsonValueKind.Array && changes.GetArrayLength() is >= 1 and <= 6 =>
                new(2, proposalId, projectId, digest, changes.EnumerateArray().Select(HarnessTimeline.Read).ToArray()),
            _ => throw new HarnessException("This timeline proposal can't be read.")
        };
    }

    /// <summary>Whether this is the same staged proposal, including all of its content.</summary>
    public bool Matches(HarnessProposal? other) => other is not null && Id == other.Id && ProjectId == other.ProjectId &&
        version == other.version && BaseRevision == other.BaseRevision && timelines.Count == other.timelines.Count &&
        timelines.Zip(other.timelines).All(pair => JsonElement.DeepEquals(pair.First.Wire, pair.Second.Wire));

    /// <summary>The shared proposal envelope, with no applied edits or approval.</summary>
    public JsonObject ToJson() => new()
    {
        ["version"] = version, ["id"] = Id.ToString("D"), ["projectId"] = ProjectId, ["baseRevision"] = BaseRevision,
        [version == 1 ? "timeline" : "timelines"] = version == 1 ? JsonNode.Parse(Timeline.GetRawText()) :
            new JsonArray(timelines.Select(timeline => JsonNode.Parse(timeline.Wire.GetRawText())).ToArray())
    };

    /// <summary>Pin the remaining timelines after Keep, to the resulting revision.</summary>
    public HarnessProposal? Remaining(int index, Domain.Shared.Project project) => timelines.Count == 1 ? null :
        new(Id, Without(index), project);

    /// <summary>Remove a timeline without authorizing any changes to the base revision.</summary>
    public HarnessProposal? Discarding(int index) => timelines.Count == 1 ? null : new(version, Id, ProjectId, BaseRevision, Without(index));

    private HarnessTimeline[] Without(int index) => timelines.Where((_, position) => index != position).ToArray();

    /// <summary>Validate the edit against the matching revision and return an in-memory candidate, without saving it.</summary>
    public Domain.Shared.Project Applying(Domain.Shared.Project snapshot, string sharedRoot) => Review(snapshot, sharedRoot).Project;

    /// <summary>Return a validated local edit and asset actions that still require a click in VoxClip.</summary>
    public (Domain.Shared.Project Project, IReadOnlyList<ClipAutopilotAction.Asset> Assets) Evaluate(Domain.Shared.Project snapshot, string sharedRoot)
    {
        var result = Review(snapshot, sharedRoot);
        return (result.Project, result.Pending.Select(operation => operation.Action).OfType<ClipAutopilotAction.Asset>().ToArray());
    }

    /// <summary>Refuse proposals pinned to a different project revision.</summary>
    public void ValidateRevision(Domain.Shared.Project snapshot)
    {
        if (snapshot.Id != ProjectId || BaseRevision != Revision(snapshot, timelines, version))
            throw new HarnessException("The project changed. Ask for a new timeline proposal.");
    }

    /// <summary>Validate the revision and map a single timeline through the shared operation apply path.</summary>
    public (Domain.Shared.Project Project, IReadOnlyList<ClipAutopilotOperation> Operations, IReadOnlyList<ClipAutopilotOperation> Pending)
        Review(Domain.Shared.Project snapshot, string sharedRoot, int index = 0, Transcript? recordingTranscript = null, bool preview = false)
    {
        ValidateRevision(snapshot);
        var original = snapshot;
        var awaitingRecording = false;
        if (timelines[index].RecordingKey is { } key)
        {
            var source = HarnessRecording.Source(key, snapshot);
            if (timelines[index].RecordingRevision is { } expected &&
                (recordingTranscript is null || HarnessTimeline.TranscriptRevision(recordingTranscript) != expected))
                throw new HarnessException("The recording transcript changed. Ask for a new timeline proposal.");
            if (recordingTranscript is not null) snapshot = HarnessRecording.Add(key, recordingTranscript, snapshot);
            else
            {
                if (!preview || timelines[index].Proposal.Parts?.Any(part => part.EndWord >= ProjectClock.Build(snapshot).Words.Count) == true)
                    throw HarnessRecording.Refusal(source);
                awaitingRecording = true;
            }
        }
        var proposal = timelines[index].Proposal;
        var clipId = ClipIdAt(index);
        if (proposal.CaptionStyle is { } style && style != "off" && CaptionStyleLibrary.Load(sharedRoot).Find(style) is null)
            throw new HarnessException("Choose a bundled caption style or off.");
        var fonts = proposal.Font is null ? new Dictionary<ClipAutopilotFont, string>() : ClipAutopilotFonts.Load(sharedRoot);
        if (proposal.Font is { } font && !fonts.ContainsKey(font)) throw new HarnessException("Choose a bundled caption font.");
        var stickers = proposal.Effects is null ? null : AskClaudePrompt.Load(sharedRoot).Stickers;
        var operations = ClipAutopilotMapping.Operations(proposal, clipId, snapshot, fonts, stickers);
        var clipStyle = operations.Any(operation => operation.Decision == ClipAutopilotDecision.Captions)
            ? snapshot.ClipStyle ?? ClipStyleCatalog.Load(sharedRoot).Initial(null) : null;
        var result = ClipAutopilotMapping.Apply(operations, snapshot, clipStyle is null ? null : (clipId, clipStyle));
        if (!result.Project.Edits.Clips.Any(clip => clip.Id == clipId))
            throw new HarnessException("The proposed clip duplicates an existing clip or doesn't have valid parts.");
        if (result.Pending.Any(operation => operation.Action is not (ClipAutopilotAction.Asset or ClipAutopilotAction.Music or ClipAutopilotAction.Rewrite)))
            throw new HarnessException("A proposed change overlaps a cut or an existing effect, or doesn't fit the clip.");
        var candidate = result.Project;
        foreach (var edit in timelines[index].Edits) candidate = edit.Apply(candidate, clipId).Project;
        _ = ProjectSerialization.Serialize(candidate);
        if (BaseRevision == Revision(candidate, timelines, version))
        {
            if (result.Pending.Count == 0 && !awaitingRecording) throw new HarnessException("The timeline doesn't change the project.");
            return (original, operations, result.Pending);
        }
        return (candidate, operations, result.Pending);
    }

    /// <summary>Look up an estimate for the candidate clip without contacting a provider.</summary>
    public string? EstimatedMusicPrice(Domain.Shared.Project candidate, string sharedRoot, int index = 0)
    {
        if (timelines[index].GenerateMusic is null || EditingEngine.FromProject(candidate) is not { } state) return null;
        var clipId = ClipIdAt(index);
        var source = candidate.Media.Source;
        state = state with { ActiveClipId = clipId };
        var rate = source.Audio?.SampleRate ?? 48_000;
        var edit = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, source.DurationSeconds), source.DurationSeconds, rate, state.PauseKeepSeconds);
        var speed = ClipControlsProject.Controls(clipId, candidate)?.Speed ?? 1;
        RenderTimeline rendered = new RenderTimeline.Legacy(edit);
        if (candidate.SchemaVersion >= 3 && VoiceLabOutputPlanner.Build(candidate, VoiceLabOutputScope.Clip(clipId)) is
            { RequiresSyntheticRendering: true } reviewed) rendered = new RenderTimeline.VoiceLab(reviewed);
        var timing = ClipSpeedTiming.ForEffects(speed, rendered.MapTime, ClipEffects.Rendered(candidate, clipId));
        return MusicPricing.Label(MusicPricing.Estimate(MusicPricing.LengthSeconds(timing.Rendered(rendered.Duration)), VoiceLabPrices.Load(sharedRoot)));
    }

    private static string Revision(Domain.Shared.Project snapshot, IReadOnlyList<HarnessTimeline> timelines, int version)
    {
        var edits = snapshot.Edits with
        {
            ActiveClipId = null,
            CutWordIds = snapshot.Edits.CutWordIds.Order(StringComparer.Ordinal).ToArray(),
            CutPauseIds = snapshot.Edits.CutPauseIds.Order(StringComparer.Ordinal).ToArray()
        };
        var stored = JsonSerializer.SerializeToNode(snapshot with { Edits = edits }, ProjectJsonContext.Default.Project)!.AsObject();
        var inputs = new JsonObject
        {
            ["sourceKey"] = snapshot.Media.Source.ContentKey,
            ["transcript"] = Take("transcript"), ["edits"] = Take("edits"), ["captions"] = Take("captions"),
            ["clipStyle"] = Take("clipStyle"), ["controls"] = Take("clipControls") ?? new JsonArray(),
            ["motion"] = Take("motionCues") ?? new JsonArray(), ["effects"] = Take("clipEffects") ?? new JsonArray(),
            ["reuseMusic"] = version == 2 || timelines.Any(timeline => timeline.Proposal.Music?.TrackId is not null) ? Take("music") ?? new JsonArray() : null
        };
        if (version == 2 || timelines.Any(timeline => timeline.UsesFootage))
        {
            inputs["footageSources"] = stored["media"]?["additionalSources"]?.DeepClone() ?? new JsonArray();
            inputs["footage"] = stored["media"]?["footage"]?.DeepClone() ?? new JsonArray();
        }
        if (version == 2)
        {
            inputs["postText"] = stored["share"]?["captions"]?.DeepClone();
            inputs["voiceLab"] = Take("voiceLab");
        }
        if (snapshot.Media.SpokenSources?.Count > 0) inputs["spokenSources"] = stored["media"]?["spokenSources"]?.DeepClone();
        using var bytes = new MemoryStream();
        using (var writer = new Utf8JsonWriter(bytes)) WriteCanonical(inputs, writer);
        return Convert.ToHexStringLower(SHA256.HashData(bytes.GetBuffer().AsSpan(0, (int)bytes.Length)));

        JsonNode? Take(string key) => stored[key]?.DeepClone();
    }

    private static void WriteCanonical(JsonNode? node, Utf8JsonWriter writer)
    {
        switch (node)
        {
            case JsonObject fields:
                writer.WriteStartObject();
                foreach (var (key, value) in fields.OrderBy(field => field.Key, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(key);
                    WriteCanonical(value, writer);
                }
                writer.WriteEndObject();
                break;
            case JsonArray items:
                writer.WriteStartArray();
                foreach (var item in items) WriteCanonical(item, writer);
                writer.WriteEndArray();
                break;
            case null: writer.WriteNullValue(); break;
            default: node.WriteTo(writer); break;
        }
    }
}
