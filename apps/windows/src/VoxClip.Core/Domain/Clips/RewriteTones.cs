using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>A Rewrite tone (design §6.3.1): a preset from shared/data/rewrite-tones.json or a tone the user saved
/// (settings rewrite.myTones, "my-..." ids). Instruction is the exact text Rewrite sends and the clip planner applies.</summary>
public sealed record RewriteTone(string Id, string Title, string Descriptor, string Instruction, bool Shortens = false, bool Featured = false)
{
    /// <summary>A tone the user saved rather than a catalogue preset.</summary>
    public bool IsSaved => Id.StartsWith(RewriteToneCatalog.MyTonePrefix, StringComparison.Ordinal);
    /// <summary>"✦ Viral YouTuber" for the featured tone.</summary>
    public string ChipTitle => Featured ? "✦ " + Title : Title;
}

/// <summary>shared/data/rewrite-tones.json: the catalogue tones in chip order, the clip style card's Auto and As I said it
/// labels, and the limits saved tones share. The Mac twin is RewriteToneCatalog in RewriteTones.swift.</summary>
public sealed class RewriteToneCatalog
{
    /// <summary>The catalogue's path under the shared root.</summary>
    public const string RelativePath = "data/rewrite-tones.json";
    /// <summary>The prefix of a saved tone's id.</summary>
    public const string MyTonePrefix = "my-";
    /// <summary>The settings key that keeps the user's saved tones.</summary>
    public const string SettingsKey = "rewrite.myTones";

    /// <summary>A card menu entry that is not a tone: its label and detail.</summary>
    /// <param name="Label">"Auto" or "As I said it".</param>
    /// <param name="Detail">"Claude picks per clip" or "no tone change".</param>
    public sealed record Choice(string Label, string Detail);

    /// <summary>The catalogue tones in chip order.</summary>
    public IReadOnlyList<RewriteTone> Tones { get; }
    /// <summary>The card's Auto entry.</summary>
    public Choice Auto { get; }
    /// <summary>The card's As I said it entry.</summary>
    public Choice AsSaid { get; }
    /// <summary>A tone title's longest length, in scalars.</summary>
    public int MaxTitleScalars { get; }
    /// <summary>An instruction's longest length, in UTF-8 bytes.</summary>
    public int MaxInstructionBytes { get; }
    /// <summary>How many tones a user may save.</summary>
    public int MaxMyTones { get; }

    private RewriteToneCatalog(IReadOnlyList<RewriteTone> tones, Choice auto, Choice asSaid, int titles, int bytes, int mine)
    {
        Tones = tones; Auto = auto; AsSaid = asSaid; MaxTitleScalars = titles; MaxInstructionBytes = bytes; MaxMyTones = mine;
    }

    /// <summary>Reads shared/data/rewrite-tones.json.</summary>
    public static RewriteToneCatalog Load(string sharedRoot) => Parse(File.ReadAllText(Path.Combine(sharedRoot, "data", "rewrite-tones.json")));

    /// <summary>Parses a rewrite-tones.json document; a broken one is SharedResourcesMissing.</summary>
    public static RewriteToneCatalog Parse(string json)
    {
        static Exception Bad() => new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "rewrite-tones.json");
        try
        {
            var root = JsonNode.Parse(json)!.AsObject();
            if (root["schema"]?.GetValue<string>() != "voxclip-rewrite-tones/1" || root["schemaVersion"]?.GetValue<int>() != 1 ||
                root["myTonePrefix"]?.GetValue<string>() != MyTonePrefix) throw Bad();
            var limits = root["limits"]!.AsObject();
            int titles = limits["maxTitleScalars"]!.GetValue<int>(), bytes = limits["maxInstructionBytes"]!.GetValue<int>(), mine = limits["maxMyTones"]!.GetValue<int>();
            Choice Find(string id)
            {
                var item = root["choices"]!.AsArray().FirstOrDefault(choice => choice?["id"]?.GetValue<string>() == id) ?? throw Bad();
                return new Choice(item["label"]!.GetValue<string>(), item["detail"]!.GetValue<string>());
            }
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var tones = root["tones"]!.AsArray().Select(item =>
            {
                var id = item!["id"]!.GetValue<string>();
                var title = item["title"]!.GetValue<string>();
                var instruction = item["instruction"]!.GetValue<string>();
                if (!ClipStyle.IsSlug(id) || id is "auto" or "as-said" || id.StartsWith(MyTonePrefix, StringComparison.Ordinal) || !seen.Add(id) ||
                    title.Length == 0 || title.EnumerateRunes().Count() > titles || instruction.Length == 0 || Encoding.UTF8.GetByteCount(instruction) > bytes) throw Bad();
                return new RewriteTone(id, title, item["descriptor"]!.GetValue<string>(), instruction,
                    item["shortens"]?.GetValue<bool>() ?? false, item["featured"]?.GetValue<bool>() ?? false);
            }).ToArray();
            if (tones.Length == 0) throw Bad();
            return new RewriteToneCatalog(tones, Find("auto"), Find("as-said"), titles, bytes, mine);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or NullReferenceException or FormatException)
        {
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "rewrite-tones.json", exception);
        }
    }

    /// <summary>The tone <paramref name="id"/> names among the catalogue and <paramref name="saved"/>, if either has it.</summary>
    public RewriteTone? Find(string id, IEnumerable<RewriteTone>? saved = null) =>
        Tones.FirstOrDefault(tone => tone.Id == id) ?? saved?.FirstOrDefault(tone => tone.Id == id);

    /// <summary>The tone a clip style's Tone asks for: null for Auto (null), "as-said", or an id neither list knows (which plans as Auto).</summary>
    public RewriteTone? Resolve(string? tone, IEnumerable<RewriteTone> saved) => tone is null or "as-said" ? null : Find(tone, saved);
}

/// <summary>The user's saved tones, settings rewrite.myTones: at most 20 {id, title, instruction}, ids "my-..." and unique.</summary>
public static class MyRewriteTones
{
    /// <summary>A saved tone's id: "my-" and a slug, at most 64 bytes.</summary>
    public static bool IsId(string? id) =>
        id is not null && id.StartsWith(RewriteToneCatalog.MyTonePrefix, StringComparison.Ordinal) && Encoding.UTF8.GetByteCount(id) <= 64 && ClipStyle.IsSlug(id);

    /// <summary>A title of 1–32 scalars with no outer spaces or control characters, and an instruction of 1–1,000 UTF-8 bytes.</summary>
    public static bool IsValid(string? title, string? instruction) =>
        title is { Length: > 0 } && title == title.Trim() && title.EnumerateRunes().Count() <= 32 && !title.Any(char.IsControl) &&
        instruction is not null && instruction.Trim().Length > 0 && Encoding.UTF8.GetByteCount(instruction) <= 1_000;

    /// <summary>The saved tones a settings value holds; anything unreadable is skipped.</summary>
    public static IReadOnlyList<RewriteTone> Decode(JsonElement? value)
    {
        if (value is not { ValueKind: JsonValueKind.Array } array) return [];
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var tones = new List<RewriteTone>();
        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("id", out var id) || !item.TryGetProperty("title", out var title) ||
                !item.TryGetProperty("instruction", out var instruction) || id.ValueKind != JsonValueKind.String || title.ValueKind != JsonValueKind.String ||
                instruction.ValueKind != JsonValueKind.String) continue;
            if (!IsId(id.GetString()) || !IsValid(title.GetString(), instruction.GetString()) || !seen.Add(id.GetString()!)) continue;
            tones.Add(new RewriteTone(id.GetString()!, title.GetString()!, "", instruction.GetString()!));
        }
        return tones;
    }

    /// <summary>Settings validation of rewrite.myTones; false for anything the settings schema refuses.</summary>
    public static bool Validates(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > 20) return false;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object) return false;
            var keys = item.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal);
            if (!keys.SetEquals(["id", "title", "instruction"])) return false;
            JsonElement id = item.GetProperty("id"), title = item.GetProperty("title"), instruction = item.GetProperty("instruction");
            if (id.ValueKind != JsonValueKind.String || title.ValueKind != JsonValueKind.String || instruction.ValueKind != JsonValueKind.String) return false;
            if (!IsId(id.GetString()) || !seen.Add(id.GetString()!) || !IsValid(title.GetString(), instruction.GetString())) return false;
        }
        return true;
    }

    /// <summary>The settings value for <paramref name="tones"/>: an array of id, title and instruction.</summary>
    public static JsonElement Encode(IReadOnlyList<RewriteTone> tones)
    {
        var array = new JsonArray(tones.Select(tone => (JsonNode)new JsonObject { ["id"] = tone.Id, ["title"] = tone.Title, ["instruction"] = tone.Instruction }).ToArray());
        using var document = JsonDocument.Parse(array.ToJsonString());
        return document.RootElement.Clone();
    }

    /// <summary>"+ Save as my tone": <paramref name="tones"/> with a new tone named <paramref name="title"/>, its id "my-" and a slug of the
    /// title (made unique with "-2", "-3"…). Throws InvalidInput for a title or instruction the settings schema refuses, or past
    /// <paramref name="limit"/> tones. Twin of the Mac <c>MyRewriteTones.saving</c>.</summary>
    public static (IReadOnlyList<RewriteTone> Tones, RewriteTone Tone) Saving(string title, string instruction, IReadOnlyList<RewriteTone> tones, int limit = 20)
    {
        var name = title.Trim();
        var text = instruction.Trim();
        if (!IsValid(name, text) || tones.Count >= limit) throw new VoxClip.Core.Domain.VoiceLab.VoiceLabException(VoxClip.Core.Domain.VoiceLab.VoiceLabErrorKind.InvalidInput);
        var folded = new StringBuilder();
        foreach (var character in name.ToLowerInvariant().Normalize(NormalizationForm.FormD))
        {
            if (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(character) == System.Globalization.UnicodeCategory.NonSpacingMark) continue;
            folded.Append(character is >= 'a' and <= 'z' or >= '0' and <= '9' ? character : '-');
        }
        var slug = string.Join('-', folded.ToString().Split('-', StringSplitOptions.RemoveEmptyEntries));
        var stem = (slug.Length == 0 ? "tone" : slug);
        var basis = RewriteToneCatalog.MyTonePrefix + stem[..Math.Min(48, stem.Length)].Trim('-');
        var id = basis;
        for (var number = 2; tones.Any(tone => tone.Id == id); number++) id = basis + "-" + number.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var made = new RewriteTone(id, name, "", text);
        return ([.. tones, made], made);
    }

    /// <summary><paramref name="tones"/> with <paramref name="id"/> renamed; its id stays, so clip styles that chose it keep it.</summary>
    public static IReadOnlyList<RewriteTone> Renaming(string id, string title, IReadOnlyList<RewriteTone> tones)
    {
        var name = title.Trim();
        var index = tones.ToList().FindIndex(tone => tone.Id == id);
        if (index < 0 || !IsValid(name, tones[index].Instruction)) throw new VoxClip.Core.Domain.VoiceLab.VoiceLabException(VoxClip.Core.Domain.VoiceLab.VoiceLabErrorKind.InvalidInput);
        return tones.Select((tone, at) => at == index ? tone with { Title = name } : tone).ToArray();
    }

    /// <summary><paramref name="tones"/> without <paramref name="id"/>. A clip style that chose it plans as Auto from then on.</summary>
    public static IReadOnlyList<RewriteTone> Deleting(string id, IReadOnlyList<RewriteTone> tones) => tones.Where(tone => tone.Id != id).ToArray();
}
