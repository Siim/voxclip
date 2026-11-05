using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Captions;

/// <summary>The captions of a run of words in another language (ai.md §18.2, Ask Claude's translate); project schema v4
/// $defs/captionTranslation. Every key is written, ClipId null included, as the Mac Core writes it.</summary>
public sealed record CaptionTranslation(string Id, string? ClipId, string StartWordId, string EndWordId, string Language, string Text);

/// <summary>Validation, pruning and the export refusal for the v4 captionTranslations field. Windows opens, validates and
/// saves translations unchanged; rendering them is Mac-only for now, so Windows render and export refuse with a reason.</summary>
public static class CaptionTranslations
{
    /// <summary>The reason a Windows render or export of a project with translated captions stops.</summary>
    public const string ExportUnsupportedMessage =
        "Windows cannot show translated captions yet. Export this project on a Mac, or undo the translation there. Your captions and edits are unchanged.";

    private const int MaximumEntries = 200;
    private const int MaximumTextScalars = 1000;
    private static readonly string[] Keys = ["id", "clipId", "startWordId", "endWordId", "language", "text"];

    private static bool Matches(string? value, string pattern) => value is not null &&
        Regex.IsMatch(value, "\\A(?:" + pattern + ")\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    private static void Require(bool condition)
    {
        if (!condition) throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "This project file can't be read.");
    }

    /// <summary>The wire shape: a non-empty list of objects with exactly the six keys.</summary>
    public static void ValidateWire(JsonElement value)
    {
        Require(value.ValueKind == JsonValueKind.Array && value.GetArrayLength() is > 0 and <= MaximumEntries);
        foreach (var entry in value.EnumerateArray())
        {
            Require(entry.ValueKind == JsonValueKind.Object && entry.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal)
                .SequenceEqual(Keys.Order(StringComparer.Ordinal)));
            foreach (var key in new[] { "id", "startWordId", "endWordId", "language", "text" })
                Require(entry.GetProperty(key).ValueKind == JsonValueKind.String);
            Require(entry.GetProperty("clipId").ValueKind is JsonValueKind.Null or JsonValueKind.String);
        }
    }

    /// <summary>The typed rules: v4 only, unique ids, known words in order, a known clip, a language tag, a trimmed text, no two
    /// over the same words in one scope.</summary>
    public static void Validate(Project project)
    {
        var entries = project.CaptionTranslations;
        if (entries.Count == 0) return;
        Require(project.SchemaVersion == 4 && entries.Count <= MaximumEntries);
        var order = (project.Transcript?.Words ?? []).Select((word, index) => (word.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index, StringComparer.Ordinal);
        var clips = project.Edits.Clips.Select(clip => clip.Id).ToHashSet(StringComparer.Ordinal);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var covered = new Dictionary<string, List<(int Lower, int Upper)>>(StringComparer.Ordinal);
        foreach (var entry in entries)
        {
            Require(Matches(entry.Id, "tr-[1-9][0-9]{0,5}") && ids.Add(entry.Id));
            var known = order.TryGetValue(entry.StartWordId, out var lower) & order.TryGetValue(entry.EndWordId, out var upper);
            Require(known && lower <= upper);
            Require(entry.ClipId is null || clips.Contains(entry.ClipId));
            Require(Matches(entry.Language, "[a-z]{2,3}(-[a-z0-9]{2,8})*"));
            Require(entry.Text.Length > 0 && entry.Text == entry.Text.Trim() && entry.Text.EnumerateRunes().Count() <= MaximumTextScalars);
            var scope = entry.ClipId ?? "";
            if (!covered.TryGetValue(scope, out var ranges)) covered[scope] = ranges = [];
            Require(!ranges.Any(range => range.Lower <= upper && lower <= range.Upper));
            ranges.Add((lower, upper));
        }
    }

    /// <summary>The translations left once clips outside <paramref name="clipIds"/> or words outside <paramref name="wordIds"/> are gone.</summary>
    public static IReadOnlyList<CaptionTranslation> Pruned(IReadOnlyList<CaptionTranslation> entries, IReadOnlySet<string> clipIds, IEnumerable<string> wordIds)
    {
        var words = wordIds.ToHashSet(StringComparer.Ordinal);
        return entries.Where(entry => (entry.ClipId is null || clipIds.Contains(entry.ClipId)) && words.Contains(entry.StartWordId) && words.Contains(entry.EndWordId)).ToArray();
    }
}
