using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Effects;

/// <summary>The schema-v4 <c>clipEffects</c> field (doc/spec/ai.md §18.2): Ask Claude's censoring, overlays, freeze frames
/// and sound effects. Windows opens, validates and saves each entry unchanged as its JSON, and renders them in preview and
/// export through <see cref="ClipEffect"/> (ai.md §18.5). The rules match the Mac Core's ClipEffects (Swift) and the shared
/// vectors in shared/fixtures/clip-effects.</summary>
public static class ClipEffects
{
    /// <summary>The effects a render of <paramref name="clipId"/> (null: the full video) draws: every censor effect, and the
    /// others of that clip.</summary>
    public static IReadOnlyList<ClipEffect> Rendered(Project project, string? clipId)
        => project.ClipEffects.Select(ClipEffect.Parse).Where(effect => effect.IsCensor || effect.ClipId == clipId).ToArray();

    private const string Identifier = "[A-Za-z0-9][A-Za-z0-9._:-]{0,63}";
    private const string SoundFile = "[0-9a-f-]{36}/sfx-[a-z0-9][a-z0-9_-]{0,57}\\.(mp3|m4a|wav|aif|aiff|flac|ogg)";
    private static readonly string[] Common = ["id", "clipId", "kind", "start", "end"];
    private static readonly HashSet<string> Censor = new(["bleep", "mute", "blur", "pixelate"], StringComparer.Ordinal);
    private static readonly string[] BundledSounds = ["whoosh", "pop", "ding"];
    private static readonly string[] Positions = ["top", "center", "bottom", "topLeft", "topRight", "bottomLeft", "bottomRight"];

    /// <summary>The keys a kind writes besides id, clipId, kind, start and end; null for an unknown kind.</summary>
    public static string[]? KindKeys(string kind) => kind switch
    {
        "bleep" or "mute" => ["wordIds"],
        "blur" or "pixelate" => ["rect", "tracking", "track"],
        "title" or "lowerThird" => ["text", "position"],
        "sticker" => ["text", "position", "scale"],
        "arrow" or "circle" => ["rect"],
        "progress" => ["position"],
        "freeze" => [],
        "sound" => ["sound", "gainDb"],
        _ => null
    };

    /// <summary>True for the kinds that render wherever their range plays (every clip and the full video).</summary>
    public static bool IsCensor(string kind) => Censor.Contains(kind);

    private static bool Matches(string? value, string pattern) => value is not null &&
        Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    /// <summary>Strict wire shape: a non-empty list (absent when empty), exact keys per kind and JSON types.</summary>
    internal static void ValidateWire(JsonElement value)
    {
        Require(value.ValueKind == JsonValueKind.Array && value.GetArrayLength() is >= 1 and <= 500);
        foreach (var entry in value.EnumerateArray()) ValidateWireEntry(entry);
    }

    private static void ValidateWireEntry(JsonElement entry)
    {
        {
            Require(entry.ValueKind == JsonValueKind.Object);
            Require(entry.TryGetProperty("kind", out var kindValue) && kindValue.ValueKind == JsonValueKind.String);
            var keys = KindKeys(kindValue.GetString()!);
            Require(keys is not null);
            Object(entry, Common.Concat(keys!));
            Require(entry.GetProperty("id").ValueKind == JsonValueKind.String);
            Require(entry.GetProperty("clipId").ValueKind is JsonValueKind.String or JsonValueKind.Null);
            Number(entry.GetProperty("start")); Number(entry.GetProperty("end"));
            if (entry.TryGetProperty("wordIds", out var words))
            {
                Require(words.ValueKind == JsonValueKind.Array);
                foreach (var word in words.EnumerateArray()) Require(word.ValueKind == JsonValueKind.String);
            }
            if (entry.TryGetProperty("rect", out var rect)) Rect(rect, false);
            if (entry.TryGetProperty("tracking", out var tracking)) Require(tracking.ValueKind == JsonValueKind.String);
            if (entry.TryGetProperty("track", out var track))
            {
                Require(track.ValueKind == JsonValueKind.Array);
                foreach (var sample in track.EnumerateArray()) Rect(sample, true);
            }
            foreach (var key in new[] { "text", "position" })
                if (entry.TryGetProperty(key, out var text)) Require(text.ValueKind == JsonValueKind.String);
            foreach (var key in new[] { "scale", "gainDb" })
                if (entry.TryGetProperty(key, out var number)) Number(number);
            if (entry.TryGetProperty("sound", out var sound))
            {
                Require(sound.ValueKind == JsonValueKind.Object && sound.TryGetProperty("source", out var source) && source.ValueKind == JsonValueKind.String);
                var bundled = sound.GetProperty("source").GetString() == "bundled";
                Require(bundled || sound.GetProperty("source").GetString() == "library");
                Object(sound, bundled ? ["source", "id", "durationSeconds", "title", "license"]
                                      : ["source", "file", "sha256", "durationSeconds", "title", "creator", "license", "attribution", "sourceUrl"]);
                Number(sound.GetProperty("durationSeconds"));
                foreach (var key in bundled ? new[] { "id", "title", "license" } : ["file", "sha256", "title", "license"])
                    Require(sound.GetProperty(key).ValueKind == JsonValueKind.String);
                if (!bundled)
                    foreach (var key in new[] { "creator", "attribution", "sourceUrl" })
                        Require(sound.GetProperty(key).ValueKind is JsonValueKind.String or JsonValueKind.Null);
            }
        }
    }

    /// <summary>The typed rules: v4 only, unique ids, the clip and words exist, and each kind's own limits.</summary>
    public static void Validate(Project project)
    {
        if (project.ClipEffects.Count == 0) return;
        Require(project.SchemaVersion == 4 && project.ClipEffects.Count <= 500);
        var clips = project.Edits.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        var words = (project.Transcript?.Words ?? []).Select(word => word.Id).ToHashSet(StringComparer.Ordinal);
        var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var effect in project.ClipEffects)
        {
            ValidateWireEntry(effect);
            Validate(effect, project.Id);
            Require(identities.Add(effect.GetProperty("id").GetString()!));
            var clip = effect.GetProperty("clipId");
            Require(clip.ValueKind == JsonValueKind.Null || clips.Contains(clip.GetString()!));
            if (effect.TryGetProperty("wordIds", out var ids))
                foreach (var id in ids.EnumerateArray()) Require(words.Contains(id.GetString()!));
        }
    }

    private static void Validate(JsonElement effect, string projectId)
    {
        var kind = effect.GetProperty("kind").GetString()!;
        var start = effect.GetProperty("start").GetDouble();
        var end = effect.GetProperty("end").GetDouble();
        Require(Matches(effect.GetProperty("id").GetString(), Identifier));
        var clip = effect.GetProperty("clipId");
        Require(clip.ValueKind == JsonValueKind.Null || Matches(clip.GetString(), Identifier));
        Require(start >= 0 && end > start && end - start <= 600 + 1e-9);
        if (effect.TryGetProperty("wordIds", out var words))
        {
            var ids = words.EnumerateArray().Select(word => word.GetString()!).ToArray();
            Require(ids.Length is >= 1 and <= 200 && ids.Distinct(StringComparer.Ordinal).Count() == ids.Length && ids.All(id => Matches(id, Identifier)));
        }
        if (effect.TryGetProperty("rect", out var rect)) Require(RectIsValid(rect));
        if (effect.TryGetProperty("track", out var track))
        {
            var tracking = effect.GetProperty("tracking").GetString();
            Require(tracking is "none" or "face" or "saliency" && track.GetArrayLength() <= 2401 && (tracking != "none" || track.GetArrayLength() == 0));
            var previous = double.NegativeInfinity;
            foreach (var sample in track.EnumerateArray())
            {
                var t = sample.GetProperty("t").GetDouble();
                Require(t > previous && RectIsValid(sample));
                previous = t;
            }
        }
        if (effect.TryGetProperty("text", out var textValue))
        {
            var text = textValue.GetString()!;
            var scalars = text.EnumerateRunes().Count();
            Require(text.Length > 0 && scalars <= (kind == "sticker" ? 16 : 80) && text == text.Trim() &&
                !text.EnumerateRunes().Any(rune => Rune.GetUnicodeCategory(rune) == UnicodeCategory.Control));
        }
        if (effect.TryGetProperty("position", out var position))
        {
            var value = position.GetString();
            Require(Positions.Contains(value) && (kind != "progress" || value is "top" or "bottom"));
        }
        if (effect.TryGetProperty("scale", out var scale)) Require(scale.GetDouble() is >= 0.5 and <= 3);
        if (kind == "freeze") Require(end - start <= 5 + 1e-9);
        if (effect.TryGetProperty("sound", out var sound))
        {
            var gain = effect.GetProperty("gainDb").GetDouble();
            var duration = sound.GetProperty("durationSeconds").GetDouble();
            var title = sound.GetProperty("title").GetString()!;
            var license = sound.GetProperty("license").GetString();
            Require(gain is >= -30 and <= 6 && duration is > 0 and <= 10 && Math.Abs(end - start - duration) < 1e-6 && title.Length is >= 1 and <= 200);
            if (sound.GetProperty("source").GetString() == "bundled")
                Require(BundledSounds.Contains(sound.GetProperty("id").GetString()) && license == "cc0");
            else
            {
                var file = sound.GetProperty("file").GetString();
                Require(Matches(file, SoundFile) && file!.StartsWith(projectId + "/", StringComparison.Ordinal));
                Require(Matches(sound.GetProperty("sha256").GetString(), "[0-9a-f]{64}") && license is "cc0" or "by" or "pdm");
                var attribution = sound.GetProperty("attribution");
                Require(license != "by" || (attribution.ValueKind == JsonValueKind.String && attribution.GetString()!.Length is >= 1 and <= 1000));
                var creator = sound.GetProperty("creator");
                Require(creator.ValueKind == JsonValueKind.Null || creator.GetString()!.Length is >= 1 and <= 200);
                var url = sound.GetProperty("sourceUrl");
                Require(url.ValueKind == JsonValueKind.String && url.GetString()!.Length <= 2048 && Matches(url.GetString(), "https://[^\\s]+"));
            }
        }
    }

    /// <summary>The project with these effects added (an existing id replaced in place), promoted to v4 on its first effect.</summary>
    public static Project Adding(IReadOnlyList<JsonElement> effects, Project project)
    {
        if (effects.Count == 0) return project;
        var result = project.SchemaVersion == 4 ? project : ContextDemoProject.UpgradeToV4(project);
        var list = result.ClipEffects.ToList();
        foreach (var effect in effects)
        {
            var id = effect.GetProperty("id").GetString();
            var index = list.FindIndex(item => item.GetProperty("id").GetString() == id);
            if (index >= 0) list[index] = effect.Clone(); else list.Add(effect.Clone());
        }
        result = result with { ClipEffects = list };
        Validate(result);
        return result;
    }

    /// <summary>Keeps effects whose clip still exists (full-video effects stay) and whose words are still in the transcript.</summary>
    public static IReadOnlyList<JsonElement> Pruned(IReadOnlyList<JsonElement> effects, IEnumerable<string> clipIds, IEnumerable<string>? wordIds = null)
    {
        var clips = clipIds.ToHashSet(StringComparer.Ordinal);
        var words = wordIds?.ToHashSet(StringComparer.Ordinal);
        return effects.Where(effect =>
        {
            var clip = effect.GetProperty("clipId");
            if (clip.ValueKind == JsonValueKind.String && !clips.Contains(clip.GetString()!)) return false;
            if (words is not null && effect.TryGetProperty("wordIds", out var ids) && ids.EnumerateArray().Any(id => !words.Contains(id.GetString()!))) return false;
            return true;
        }).ToArray();
    }

    private static bool RectIsValid(JsonElement rect)
    {
        double Get(string key) => rect.GetProperty(key).GetDouble();
        var (x, y, width, height) = (Get("x"), Get("y"), Get("width"), Get("height"));
        return x >= 0 && y >= 0 && width >= 0.01 && height >= 0.01 && x + width <= 1 + 1e-9 && y + height <= 1 + 1e-9;
    }

    private static void Rect(JsonElement value, bool sample)
    {
        Object(value, sample ? ["t", "x", "y", "width", "height"] : ["x", "y", "width", "height"]);
        foreach (var property in value.EnumerateObject()) Number(property.Value);
    }

    private static void Object(JsonElement value, IEnumerable<string> keys)
    {
        Require(value.ValueKind == JsonValueKind.Object);
        Require(value.EnumerateObject().Select(property => property.Name).ToHashSet(StringComparer.Ordinal).SetEquals(keys));
    }

    private static void Number(JsonElement value) =>
        Require(value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number));

    private static void Require([DoesNotReturnIf(false)] bool condition)
    {
        if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Invalid clip effects.");
    }
}
