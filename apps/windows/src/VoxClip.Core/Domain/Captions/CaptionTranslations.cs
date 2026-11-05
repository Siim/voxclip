using System.Text.Json;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Captions;

/// <summary>The captions of a run of words in another language (ai.md §18.2, Ask Claude's translate); project schema v4
/// $defs/captionTranslation. Every key is written, ClipId null included, as the Mac Core writes it.</summary>
public sealed record CaptionTranslation(string Id, string? ClipId, string StartWordId, string EndWordId, string Language, string Text)
{
    /// <summary>The translation's words: its text split at white space.</summary>
    public IReadOnlyList<string> Tokens() => Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Validation, editing, pruning and rendering of the v4 captionTranslations field (Mac CaptionTranslations): the
/// translated text replaces the transcript words in the captions only; the voice, the words and the transcript stay.</summary>
public static class CaptionTranslations
{
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

    private static Dictionary<string, int> WordOrder(Project project)
    {
        var order = new Dictionary<string, int>(StringComparer.Ordinal);
        var words = project.Transcript?.Words ?? [];
        for (var index = 0; index < words.Count; index++) order.TryAdd(words[index].Id, index);
        return order;
    }

    /// <summary>The next free id: "tr-1", "tr-2"…</summary>
    public static string NextId(Project project)
    {
        var used = project.CaptionTranslations.Select(entry => entry.Id).ToHashSet(StringComparer.Ordinal);
        var index = 1;
        while (used.Contains("tr-" + index)) index++;
        return "tr-" + index;
    }

    private static bool Overlaps(CaptionTranslation entry, string? clipId, int start, int end, Dictionary<string, int> order) =>
        entry.ClipId == clipId && order.TryGetValue(entry.StartWordId, out var lower) && order.TryGetValue(entry.EndWordId, out var upper) &&
        lower <= end && start <= upper;

    /// <summary><paramref name="project"/> with a translation of transcript words <paramref name="start"/>…<paramref name="end"/> in
    /// <paramref name="language"/>: promoted to v4, replacing any translation in the same scope over any of those words.</summary>
    public static Project Translating(int start, int end, string? clipId, string language, string text, Project project)
    {
        var words = project.Transcript?.Words;
        Require(words is not null && start >= 0 && start <= end && end < words.Count);
        var result = project.SchemaVersion == 4 ? project : ContextDemoProject.UpgradeToV4(project);
        var order = WordOrder(result);
        var kept = result.CaptionTranslations.Where(entry => !Overlaps(entry, clipId, start, end, order)).ToList();
        result = result with { CaptionTranslations = kept };
        kept.Add(new(NextId(result), clipId, words![start].Id, words[end].Id, language.ToLowerInvariant(), text.Trim()));
        result = result with { CaptionTranslations = kept.ToArray() };
        Validate(result);
        return result;
    }

    /// <summary>Takes the translation of words <paramref name="start"/>…<paramref name="end"/> in <paramref name="clipId"/>'s scope
    /// back out of <paramref name="project"/>, putting back what <paramref name="before"/> had there.</summary>
    public static Project Untranslating(int start, int end, string? clipId, Project? before, Project project)
    {
        var order = WordOrder(project);
        var kept = project.CaptionTranslations.Where(entry => !Overlaps(entry, clipId, start, end, order)).ToList();
        foreach (var entry in before?.CaptionTranslations ?? [])
            if (Overlaps(entry, clipId, start, end, order) && kept.All(item => item.Id != entry.Id)) kept.Add(entry);
        var result = project with { CaptionTranslations = kept.ToArray() };
        Validate(result);
        return result;
    }

    /// <summary>The translations a render of <paramref name="clipId"/> shows: that clip's own first, then the Full Take's.</summary>
    public static IReadOnlyList<CaptionTranslation> Rendered(Project project, string? clipId) =>
        (clipId is null ? [] : project.CaptionTranslations.Where(entry => entry.ClipId == clipId))
            .Concat(project.CaptionTranslations.Where(entry => entry.ClipId is null)).ToArray();

    /// <summary>The caption words a render of <paramref name="clipId"/> shows (Mac: masking, then <c>applying</c>): bleeped and muted
    /// words masked, then the scope's translations in place of their words. Every caption path (preview, export, SRT, the CLI) goes
    /// through here.</summary>
    public static IReadOnlyList<CaptionWord> Shown(IReadOnlyList<CaptionWord> words, Project project, string? clipId, IReadOnlyList<ClipEffect>? effects) =>
        Applying(ClipEffectsRendering.MaskingBleeps(words, effects), project, clipId, effects);

    /// <summary><paramref name="captions"/> (words on the edited or rendered timeline, with their transcript ids) with each rendered
    /// translation in place of its words (ai.md §18.2). Call after <see cref="ClipEffectsRendering.MaskingBleeps"/>. The translation's
    /// words spread over the shown words of its range, in order: with as many or more translated words, each shown word's time is
    /// shared evenly by the words it carries; with fewer, each translated word spans its share of the shown words. Times never leave
    /// the original words' bounds. A translated word over a bleeped or muted word is masked (× per letter).</summary>
    public static IReadOnlyList<CaptionWord> Applying(IReadOnlyList<CaptionWord> captions, Project project, string? clipId, IReadOnlyList<ClipEffect>? effects)
    {
        var translations = Rendered(project, clipId);
        if (translations.Count == 0 || captions.Count == 0) return captions;
        var order = WordOrder(project);
        var bleeped = (effects ?? []).Where(effect => effect.UsesWords).SelectMany(effect => effect.WordIds).ToHashSet(StringComparer.Ordinal);
        var result = captions.ToList();
        var consumed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var translation in translations)
        {
            if (!order.TryGetValue(translation.StartWordId, out var lower) || !order.TryGetValue(translation.EndWordId, out var upper)) continue;
            var positions = Enumerable.Range(0, result.Count)
                .Where(index => order.TryGetValue(result[index].Id, out var at) && at >= lower && at <= upper).ToArray();
            if (positions.Length == 0 || positions.Any(index => consumed.Contains(result[index].Id))) continue;
            var slots = positions.Select(index => result[index]).ToArray();
            var spread = Spreading(translation.Tokens(), slots, bleeped);
            if (spread.Count == 0) continue;
            foreach (var slot in slots) consumed.Add(slot.Id);
            foreach (var index in positions.Reverse()) result.RemoveAt(index);
            result.InsertRange(positions[0], spread);
        }
        return result;
    }

    /// <summary><paramref name="tokens"/> over the shown words <paramref name="slots"/> (see <see cref="Applying"/>). A slot's first
    /// word keeps the slot's id, the others add "#n", so every id stays unique and traces back to its transcript word.</summary>
    public static IReadOnlyList<CaptionWord> Spreading(IReadOnlyList<string> tokens, IReadOnlyList<CaptionWord> slots, IReadOnlySet<string> bleeped)
    {
        int count = tokens.Count, shown = slots.Count;
        if (count == 0 || shown == 0) return [];
        var words = new List<CaptionWord>();
        if (count >= shown)
        {
            for (var index = 0; index < shown; index++)
            {
                var slot = slots[index];
                int first = index * count / shown, last = (index + 1) * count / shown;
                var share = (slot.End - slot.Start) / (last - first);
                for (var token = first; token < last; token++)
                {
                    double offset = token - first;
                    var text = bleeped.Contains(slot.Id) ? ClipEffectsRendering.Masked(tokens[token]) : tokens[token];
                    words.Add(new(token == first ? slot.Id : slot.Id + "#" + (token - first), text,
                        slot.Start + offset * share, token == last - 1 ? slot.End : slot.Start + (offset + 1) * share));
                }
            }
        }
        else
        {
            for (var token = 0; token < count; token++)
            {
                int first = token * shown / count, last = (token + 1) * shown / count - 1;
                var masked = false;
                for (var index = first; index <= last; index++) masked |= bleeped.Contains(slots[index].Id);
                words.Add(new(slots[first].Id, masked ? ClipEffectsRendering.Masked(tokens[token]) : tokens[token], slots[first].Start, slots[last].End));
            }
        }
        return words;
    }
}
