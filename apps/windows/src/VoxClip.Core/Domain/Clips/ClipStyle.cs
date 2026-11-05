using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>One clip's caption look (design §6.6; project schema $defs/clipStyle): the style and its one-line reason, the overrides
/// that clip renders with (Make it postable's case, words per line and font) and who chose it. Claude's picks omit
/// <see cref="By"/>; the creator's own choice for the clip is "user".</summary>
public sealed record ClipCaptionPick(string StyleId, string Reason)
{
    /// <summary>A merge patch over the style, as captions.overrides; null keeps the project's overrides while the styles match, else none.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public JsonElement? Overrides { get; init; }
    /// <summary>"user" for the creator's own choice; null for Claude's pick.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? By { get; init; }

    /// <summary>The creator chose this clip's style.</summary>
    [JsonIgnore]
    public bool ByUser => By == "user";

    /// <summary>Field by field, the overrides by JSON value.</summary>
    public bool Equals(ClipCaptionPick? other) => other is not null && StyleId == other.StyleId && Reason == other.Reason && By == other.By
        && (Overrides is { } overrides ? other.Overrides is { } theirs && JsonElement.DeepEquals(overrides, theirs) : other.Overrides is null);

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(StyleId, Reason, By);
}

/// <summary>How clips should be made (design §6.6, project schema $defs/clipStyle). Stored per project once the user
/// chooses on the clip style card; Settings keeps the default a new project's card starts with. The clip autopilot
/// planner reads the same value. Wire values: preset auto|punchy|calm|demo|mine, captions "auto", "off" or a style id,
/// music auto|off, shapes "16:9"|"9:16"|"1:1", rewording off|fix-only|tighten.</summary>
public sealed record ClipStyle(string Preset, string Captions, string Music, int MaxLengthSec, IReadOnlyList<string> Shapes,
    string Rewording, IReadOnlyDictionary<string, ClipCaptionPick> CaptionPicks)
{
    /// <summary>The tone Claude writes each clip's words in (design §6.6 Tone row): null is Auto (omitted from the file and never
    /// written as "auto"), "as-said", a catalogue tone id from shared/data/rewrite-tones.json or a saved "my-..." id.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Tone { get; init; }

    /// <summary>The tone the planner gets: "as-said" whenever the style never rewords, else <see cref="Tone"/>.</summary>
    [JsonIgnore]
    public string? EffectiveTone => Rewording == "off" ? "as-said" : Tone;

    /// <summary>The preset ids, in the card's order.</summary>
    public static readonly IReadOnlyList<string> Presets = ["auto", "punchy", "calm", "demo", "mine"];

    /// <summary>True while the AI picks the caption style per clip.</summary>
    [JsonIgnore]
    public bool CaptionsAuto => Captions == "auto";

    /// <summary>The caption style the user fixed, or "off"; null while the AI picks.</summary>
    [JsonIgnore]
    public string? FixedCaptionStyle => CaptionsAuto ? null : Captions;

    /// <summary>The creator's own pick for the clip first, then the style they fixed; with Auto, the AI's pick for the clip, or null
    /// (the project's style stays).</summary>
    public string? CaptionStyleFor(string? clipId)
    {
        if (clipId is { Length: > 0 } && CaptionPicks.TryGetValue(clipId, out var own) && own.ByUser) return own.StyleId;
        if (FixedCaptionStyle is { } fixedStyle) return fixedStyle;
        return clipId is { Length: > 0 } && CaptionPicks.TryGetValue(clipId, out var pick) ? pick.StyleId : null;
    }

    /// <summary>The pick a render of the clip uses (design §6.6): the creator's own always; Claude's while captions are Auto, or when
    /// it keeps the fixed style. Null: the project's captions apply.</summary>
    public ClipCaptionPick? CaptionPickFor(string? clipId)
    {
        if (clipId is not { Length: > 0 } || !CaptionPicks.TryGetValue(clipId, out var pick)) return null;
        if (pick.ByUser || FixedCaptionStyle is null) return pick;
        return pick.StyleId == FixedCaptionStyle ? pick : null;
    }

    /// <summary>Records AI picks. A fixed caption style is never overridden: with anything but Auto this changes nothing. The
    /// creator's own pick for a clip is never replaced.</summary>
    public ClipStyle Recording(IReadOnlyDictionary<string, ClipCaptionPick> picks)
    {
        if (!CaptionsAuto) return this;
        var merged = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal);
        foreach (var (id, pick) in CaptionPicks) merged[id] = pick;
        foreach (var (id, pick) in picks) if (!(CaptionPicks.TryGetValue(id, out var own) && own.ByUser)) merged[id] = pick;
        return this with { CaptionPicks = merged };
    }

    /// <summary>The user chose a caption style (a gallery tile or the card's Captions row): it becomes the fixed choice.</summary>
    public ClipStyle FixingCaptions(string choice) => this with { Captions = choice, Preset = choice != "auto" && Preset == "auto" ? "mine" : Preset };

    /// <summary>Drops picks for clips that no longer exist.</summary>
    public ClipStyle Pruned(IReadOnlySet<string> clipIds) =>
        this with { CaptionPicks = new SortedDictionary<string, ClipCaptionPick>(CaptionPicks.Where(item => clipIds.Contains(item.Key)).ToDictionary(), StringComparer.Ordinal) };

    /// <summary>The status bar item: "Style: Auto · ≤60 s · 16:9+9:16".</summary>
    public string Summary(string presetLabel) => $"Style: {presetLabel} · ≤{MaxLengthSec} s · {string.Join("+", Shapes)}";

    /// <summary>The Settings default: this style without its picks.</summary>
    [JsonIgnore]
    public ClipStyle SettingsDefault => this with { CaptionPicks = new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal) };

    /// <summary>The same value, field by field (records compare collections by reference).</summary>
    public bool SameAs(ClipStyle? other) => other is not null && Preset == other.Preset && Captions == other.Captions && Music == other.Music
        && MaxLengthSec == other.MaxLengthSec && Shapes.SequenceEqual(other.Shapes) && Rewording == other.Rewording && Tone == other.Tone
        && CaptionPicks.Count == other.CaptionPicks.Count && CaptionPicks.All(item => other.CaptionPicks.TryGetValue(item.Key, out var pick) && pick == item.Value);

    /// <summary>Project schema $defs/clipStyle.</summary>
    public void Validate()
    {
        static void Require(bool condition, string field)
        {
            if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "clipStyle." + field);
        }
        Require(Presets.Contains(Preset), "preset");
        Require(IsSlug(Captions), "captions");
        Require(Music is "auto" or "off", "music");
        Require(MaxLengthSec is >= 5 and <= 600, "maxLengthSec");
        Require(Shapes.Count > 0 && Shapes.Distinct(StringComparer.Ordinal).Count() == Shapes.Count && Shapes.All(shape => shape is "16:9" or "9:16" or "1:1"), "shapes");
        Require(Rewording is "off" or "fix-only" or "tighten", "rewording");
        Require(Tone is null || IsSlug(Tone) && Tone != "auto" && System.Text.Encoding.UTF8.GetByteCount(Tone) <= 64, "tone");
        foreach (var (_, pick) in CaptionPicks)
            Require(IsSlug(pick.StyleId) && pick.StyleId != "auto" && pick.Reason.EnumerateRunes().Count() <= 120
                && (pick.By is null or "user") && (pick.Overrides is null or { ValueKind: JsonValueKind.Object }), "captionPicks");
    }

    internal static bool IsSlug(string? text) =>
        text is { Length: > 0 } && text.Split('-').All(run => run.Length > 0 && run.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9'));
}

/// <summary>Each clip's caption look (design §6.6), the twin of the Swift Project.captionSettings(forClip:).</summary>
public static class ClipCaptionLooks
{
    private static readonly JsonElement Empty = JsonDocument.Parse("{}").RootElement.Clone();

    /// <summary>The captions a render of the clip uses: its pick when one applies (<see cref="ClipStyle.CaptionPickFor"/>), else the
    /// project's captions. The position stays the project's. A pick without overrides keeps the project's while the styles match.</summary>
    public static ProjectCaptions CaptionsFor(this Project project, string? clipId)
    {
        if (project.ClipStyle?.CaptionPickFor(clipId) is not { } pick) return project.Captions;
        var overrides = pick.Overrides ?? (pick.StyleId == project.Captions.StyleId ? project.Captions.Overrides : Empty);
        return project.Captions with { StyleId = pick.StyleId, Overrides = overrides };
    }
}

/// <summary>shared/data/clip-styles.json: the presets and the labels the card and status bar show.</summary>
public sealed class ClipStyleCatalog
{
    /// <summary>One chip.</summary>
    public sealed record Preset(string Id, string Label, string? Detail, ClipStyle Style, IReadOnlyList<string> ExcludeCaptionTags);
    /// <summary>One menu choice.</summary>
    public sealed record Option(string Id, string Label, string? Detail);

    /// <summary>The presets in the card's order.</summary>
    public IReadOnlyList<Preset> Presets { get; }
    /// <summary>The preset a new project's card starts with when Settings has none.</summary>
    public string DefaultPreset { get; }
    /// <summary>The Length menu.</summary>
    public IReadOnlyList<int> LengthChoicesSec { get; }
    /// <summary>The Shape menu.</summary>
    public IReadOnlyList<string> Shapes { get; }
    /// <summary>The Rewording menu.</summary>
    public IReadOnlyList<Option> Rewording { get; }
    /// <summary>The Music menu.</summary>
    public IReadOnlyList<Option> Music { get; }

    private ClipStyleCatalog(IReadOnlyList<Preset> presets, string defaultPreset, IReadOnlyList<int> lengths, IReadOnlyList<string> shapes, IReadOnlyList<Option> rewording, IReadOnlyList<Option> music)
    {
        Presets = presets; DefaultPreset = defaultPreset; LengthChoicesSec = lengths; Shapes = shapes; Rewording = rewording; Music = music;
    }

    /// <summary>Reads shared/data/clip-styles.json.</summary>
    public static ClipStyleCatalog Load(string sharedRoot) => Parse(File.ReadAllText(Path.Combine(sharedRoot, "data", "clip-styles.json")));

    /// <summary>Parses a clip-styles.json document.</summary>
    public static ClipStyleCatalog Parse(string json)
    {
        var root = JsonNode.Parse(json)!.AsObject();
        if (root["schemaVersion"]?.GetValue<int>() != 1) throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "clip-styles.json");
        static IReadOnlyList<Option> Options(JsonNode? node) => node!.AsArray().Select(item => new Option(item!["id"]!.GetValue<string>(), item["label"]!.GetValue<string>(), item["detail"]?.GetValue<string>())).ToArray();
        var presets = root["presets"]!.AsArray().Select(item =>
        {
            var style = new ClipStyle(item!["id"]!.GetValue<string>(), item["captions"]!.GetValue<string>(), item["music"]!.GetValue<string>(), item["maxLengthSec"]!.GetValue<int>(),
                item["shapes"]!.AsArray().Select(shape => shape!.GetValue<string>()).ToArray(), item["rewording"]!.GetValue<string>(), new SortedDictionary<string, ClipCaptionPick>(StringComparer.Ordinal));
            style.Validate();
            return new Preset(style.Preset, item["label"]!.GetValue<string>(), item["detail"]?.GetValue<string>(), style,
                item["excludeCaptionTags"]!.AsArray().Select(tag => tag!.GetValue<string>()).ToArray());
        }).ToArray();
        var defaultPreset = root["defaultPreset"]!.GetValue<string>();
        if (!presets.Select(preset => preset.Id).ToHashSet().SetEquals(ClipStyle.Presets) || !ClipStyle.Presets.Contains(defaultPreset))
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "clip-styles.json");
        return new(presets, defaultPreset, root["lengthChoicesSec"]!.AsArray().Select(value => value!.GetValue<int>()).ToArray(),
            root["shapes"]!.AsArray().Select(value => value!.GetValue<string>()).ToArray(), Options(root["rewording"]), Options(root["music"]));
    }

    /// <summary>The preset <paramref name="id"/>, or the first one.</summary>
    public Preset Find(string id) => Presets.FirstOrDefault(preset => preset.Id == id) ?? Presets[0];

    /// <summary>The style a chip applies. "My style" applies the user's saved default when there is one.</summary>
    public ClipStyle StyleFor(string id, ClipStyle? mine) =>
        id == "mine" && mine is not null ? mine.SettingsDefault with { Preset = "mine" } : Find(id).Style;

    /// <summary>The style a new project's card starts with: the Settings default, or the default preset.</summary>
    public ClipStyle Initial(ClipStyle? saved) => saved?.SettingsDefault ?? Find(DefaultPreset).Style;

    /// <summary>The caption styles the AI may pick from under <paramref name="style"/>, in gallery order.</summary>
    public IReadOnlyList<CaptionStyle> CaptionCandidates(IEnumerable<CaptionStyle> library, ClipStyle style)
    {
        var excluded = Find(style.Preset).ExcludeCaptionTags.ToHashSet(StringComparer.Ordinal);
        return library.Where(caption => !caption.Tags.Any(excluded.Contains)).OrderBy(caption => caption.Order).ThenBy(caption => caption.Id, StringComparer.Ordinal).ToArray();
    }
}
