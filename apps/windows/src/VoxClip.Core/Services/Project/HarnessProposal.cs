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
using VoxClip.Core.Services.Settings;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.Core.Services.Project;

/// <summary>A project harness refusal safe to return to the agent.</summary>
/// <param name="message">The user-facing reason.</param>
public sealed class HarnessException(string message) : Exception(message);

/// <summary>Validated local edit intent in the shared harness timeline format.</summary>
public sealed class HarnessTimeline
{
    private static readonly HashSet<string> SupportedEffects = ["zoom", "punchIn", "motionTitle", "lowerThird", "emojiPop"];
    private static readonly string[] Keys = ["clipId", "reason", "cuts", "captionStyle", "title", "musicTrackId", "generateMusic", "effects"];
    private static readonly string[] CutKeys = ["startWord", "endWord", "kind", "reason"];

    private HarnessTimeline(JsonElement wire, string clipId, string? title, string? captionStyle, string? musicTrackId,
        string? generateMusic, IReadOnlyList<WordSpan> cuts, IReadOnlyList<ClipPlanEffect> effects)
    {
        Wire = wire.Clone();
        ClipId = clipId;
        Title = title;
        CaptionStyle = captionStyle;
        MusicTrackId = musicTrackId;
        GenerateMusic = generateMusic;
        Cuts = cuts;
        Effects = effects;
    }

    internal JsonElement Wire { get; }
    internal string ClipId { get; }
    internal string? Title { get; }
    internal string? CaptionStyle { get; }
    internal string? MusicTrackId { get; }
    /// <summary>The optional music brief, for estimating only.</summary>
    public string? GenerateMusic { get; }
    internal IReadOnlyList<WordSpan> Cuts { get; }
    internal IReadOnlyList<ClipPlanEffect> Effects { get; }

    /// <summary>Reject unknown fields and unsupported entries before resolving any anchors.</summary>
    public static HarnessTimeline Read(JsonElement wire)
    {
        RequireObject(wire, Keys);
        var clipId = Text(wire, "clipId");
        var title = Text(wire, "title", EditingLimits.MaxClipTitleCodePoints);
        var captionStyle = Text(wire, "captionStyle");
        var musicTrackId = Text(wire, "musicTrackId");
        var generateMusic = Text(wire, "generateMusic", 500);
        var cuts = Items(wire, "cuts", 30).Select(ReadCut).ToArray();
        var effects = Items(wire, "effects", ClipPlanEffect.MaximumEntries).Select(ReadEffect).ToArray();
        if (clipId is null || Text(wire, "reason", 240) is null || (musicTrackId is not null && generateMusic is not null) ||
            (title is null && captionStyle is null && musicTrackId is null && generateMusic is null && cuts.Length == 0 && effects.Length == 0))
            throw InvalidTimeline();
        return new(wire, clipId, title, captionStyle, musicTrackId, generateMusic, cuts, effects);
    }

    /// <summary>Accept only a JSON object with named, non-null, non-duplicate arguments.</summary>
    public static void RequireObject(JsonElement value, IReadOnlyCollection<string> keys)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Any(field =>
            !keys.Contains(field.Name) || !seen.Add(field.Name) || field.Value.ValueKind == JsonValueKind.Null))
            throw new HarnessException("Unexpected or null argument.");
    }

    private static WordSpan ReadCut(JsonElement cut)
    {
        RequireObject(cut, CutKeys);
        if (Text(cut, "kind") is not ("filler" or "stumble" or "repeat" or "falseStart" or "tangent" or "other") ||
            Text(cut, "reason", 240) is null || Index(cut, "startWord") is not { } start || Index(cut, "endWord") is not { } end)
            throw InvalidTimeline();
        return new(start, end);
    }

    private static ClipPlanEffect ReadEffect(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object || item.EnumerateObject().Count() != 5 ||
            item.EnumerateObject().Select(field => field.Name).Distinct(StringComparer.Ordinal).Count() != 5 ||
            ClipPlanEffect.Read(JsonNode.Parse(item.GetRawText())) is not { } effect || !SupportedEffects.Contains(effect.Kind))
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

    private static HarnessException InvalidTimeline() => new("Invalid timeline. Give a clip, a reason and at least one supported change.");
}

/// <summary>A versioned sidecar proposal pinned to a project and its editable revision.</summary>
/// <param name="timeline">Validated proposed changes.</param>
/// <param name="project">The saved base snapshot.</param>
public sealed class HarnessProposal(HarnessTimeline timeline, Domain.Shared.Project project)
{
    /// <summary>Byte limit for one request or sidecar.</summary>
    public const int MaximumBytes = 128 * 1024;
    private Guid Id { get; } = Guid.NewGuid();
    private string ProjectId { get; } = project.Id;
    private string BaseRevision { get; } = Revision(project, timeline.MusicTrackId is not null);

    /// <summary>The shared proposal envelope, with no applied edits or approval.</summary>
    public JsonObject ToJson() => new()
    {
        ["version"] = 1, ["id"] = Id.ToString("D"), ["projectId"] = ProjectId, ["baseRevision"] = BaseRevision,
        ["timeline"] = JsonNode.Parse(timeline.Wire.GetRawText())
    };

    /// <summary>Validate the edit against the matching revision and return an in-memory candidate, without saving it.</summary>
    public Domain.Shared.Project Applying(Domain.Shared.Project snapshot, string sharedRoot)
    {
        var reuseMusic = timeline.MusicTrackId is not null;
        if (snapshot.Id != ProjectId || BaseRevision != Revision(snapshot, reuseMusic))
            throw new HarnessException("The project changed. Ask for a new timeline proposal.");
        if (EditingEngine.FromProject(snapshot) is not { } state ||
            snapshot.Edits.Clips.FirstOrDefault(clip => clip.Id == timeline.ClipId) is not { } clip)
            throw new HarnessException("Choose an existing clip with a transcript.");
        var words = state.Transcript.Words;
        var indices = words.Select((word, index) => (word.Id, index)).ToDictionary(item => item.Id, item => item.index, StringComparer.Ordinal);
        if (!indices.TryGetValue(clip.StartWordId, out var start) || !indices.TryGetValue(clip.EndWordId, out var end) || start > end)
            throw new HarnessException("Choose an existing clip with a transcript.");
        var scope = new WordSpan(start, end);
        var cuts = new HashSet<string>(StringComparer.Ordinal);
        foreach (var cut in timeline.Cuts)
        {
            if (cut.Start < scope.Start || cut.End > scope.End || cut.Start > cut.End)
                throw new HarnessException("A cut is outside the clip.");
            var ids = cut.Indices.Select(index => words[index]).Where(word => word.Kind == WordKind.Word).Select(word => word.Id).ToArray();
            if (ids.Length == 0 || ids.Any(id => !cuts.Add(id)))
                throw new HarnessException("Cuts must name distinct spoken words.");
        }
        var uncut = cuts.Except(state.CutWordIds).Order(StringComparer.Ordinal).ToArray();
        if (uncut.Length != 0) state = EditingEngine.Reduce(state, new EditOperation.CutSelection(uncut));
        if (!cuts.IsSubsetOf(state.CutWordIds) || !scope.Indices.Any(index => words[index].Kind == WordKind.Word && !state.CutWordIds.Contains(words[index].Id)))
            throw new HarnessException("Keep at least one spoken word in the clip.");
        var rename = timeline.Title is { } title && title != clip.Title;
        if (rename) state = EditingEngine.Reduce(state, new EditOperation.RenameClip(clip.Id, timeline.Title));
        var next = uncut.Length != 0 || rename ? EditingEngine.ApplyToProject(snapshot, state) : snapshot;

        if (timeline.CaptionStyle is { } style)
        {
            if (style != "off" && CaptionStyleLibrary.Load(sharedRoot).Find(style) is null)
                throw new HarnessException("Choose a bundled caption style or off.");
            if (next.ClipStyle is null)
            {
                var catalog = ClipStyleCatalog.Load(sharedRoot);
                next = next with { ClipStyle = catalog.Initial(null) };
            }
            next = ClipCaptionStyles.Choosing(next, clip.Id, style);
        }
        if (timeline.MusicTrackId is { } trackId)
        {
            var track = snapshot.Music.FirstOrDefault(entry => entry.Id == trackId)
                ?? throw new HarnessException("Choose a saved music track from this project.");
            var taken = next.Music.Where(entry => entry.ClipId != clip.Id).Select(entry => entry.Id).ToHashSet(StringComparer.Ordinal);
            var id = track.Id;
            for (var suffix = 2; taken.Contains(id); suffix++) id = string.Create(CultureInfo.InvariantCulture, $"{track.Id}-{suffix}");
            next = MusicProject.Setting(track with { Id = id, ClipId = clip.Id }, clip.Id, next);
        }
        if (timeline.Effects.Count != 0)
        {
            var stickers = AskClaudePrompt.Load(sharedRoot).Stickers;
            var tightened = state.Pauses.Where(pause => state.CutPauseIds.Contains(pause.Id)).Select(pause => pause.AfterIndex).ToHashSet();
            for (var index = 0; index < timeline.Effects.Count; index++)
            {
                var effectId = string.Create(CultureInfo.InvariantCulture, $"harness-{Id:D}-{index}");
                var effect = timeline.Effects[index].Operation(effectId, clip.Id, scope, words, state.CutWordIds, tightened, stickers);
                next = effect?.Action switch
                {
                    ClipAutopilotAction.Motion motion => ClipAutopilotMapping.AddingMotionCue(motion.Cue, next) ??
                        throw new HarnessException($"Effect {index + 1} overlaps a cut or another zoom."),
                    ClipAutopilotAction.Effect overlay => ClipEffects.Adding([overlay.Value], next),
                    _ => throw new HarnessException($"Effect {index + 1} is not supported on those words. Use a kept span of 0.1–5 seconds.")
                };
            }
        }
        if (timeline.GenerateMusic is null && BaseRevision == Revision(next, reuseMusic))
            throw new HarnessException("The timeline doesn't change the project.");
        _ = ProjectSerialization.Serialize(next);
        return next;
    }

    /// <summary>Look up an estimate for the candidate clip without contacting a provider.</summary>
    public string? EstimatedMusicPrice(Domain.Shared.Project candidate, string sharedRoot)
    {
        if (timeline.GenerateMusic is null || EditingEngine.FromProject(candidate) is not { } state) return null;
        var source = candidate.Media.Source;
        state = state with { ActiveClipId = timeline.ClipId };
        var rate = source.Audio?.SampleRate ?? 48_000;
        var edit = EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state, source.DurationSeconds), source.DurationSeconds, rate, state.PauseKeepSeconds);
        var speed = ClipControlsProject.Controls(timeline.ClipId, candidate)?.Speed ?? 1;
        return MusicPricing.Label(MusicPricing.Estimate(MusicPricing.LengthSeconds(edit.Duration / speed), VoiceLabPrices.Load(sharedRoot)));
    }

    private static string Revision(Domain.Shared.Project snapshot, bool reuseMusic)
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
            ["reuseMusic"] = reuseMusic ? Take("music") ?? new JsonArray() : null
        };
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
