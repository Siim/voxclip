#pragma warning disable CS1591
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;

namespace VoxClip.Core.Domain.VoiceLab;

public static class VoiceLabAudioTags
{
    public sealed record Definition(string Tag, double Seconds);
    private static readonly Lazy<JsonElement> Catalog = new(() =>
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "data", "voice-audio-tags.json")));
            return document.RootElement.Clone();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or VoxClipException)
        { throw new VoiceLabProjectException(VoiceLabProjectErrorCode.InvalidWords); }
    });
    private static readonly Lazy<IReadOnlySet<string>> Allowed = new(() => Definitions.Select(definition => definition.Tag).ToHashSet(StringComparer.Ordinal));
    internal static IReadOnlySet<string> AllowedTags => Allowed.Value;
    private static readonly Regex Brackets = new(@"\[[^\[\]\r\n]*\]", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    public static IReadOnlyList<Definition> Definitions => Catalog.Value.GetProperty("tags").EnumerateArray()
        .Select(item => new Definition(item.GetProperty("tag").GetString()!, item.GetProperty("seconds").GetDouble())).ToArray();
    public static bool Supports(string modelId) => Catalog.Value.GetProperty("models").EnumerateArray().Any(value => value.GetString() == modelId);
    public static IReadOnlyList<VoiceLabAudioTag> Validated(IReadOnlyList<VoiceLabAudioTag> tags, string text)
    {
        if (tags.Count == 0) return [];
        var count = EditingAlgorithms.SplitWords(text).Count;
        var allowed = AllowedTags;
        return tags.Take(64).Where(annotation => annotation is not null && annotation.BeforeToken >= 0 && annotation.BeforeToken <= count && allowed.Contains(annotation.Tag))
            .OrderBy(annotation => annotation.BeforeToken).ToArray();
    }
    public static IReadOnlyList<VoiceLabAudioTag> Parse(JsonNode? value, string text)
    {
        var tags = new List<VoiceLabAudioTag>();
        if (value is JsonArray items)
            foreach (var item in items)
                if (item is JsonObject entry && entry["beforeToken"] is JsonValue boundary && boundary.TryGetValue<double>(out var number) &&
                    double.IsFinite(number) && number == Math.Truncate(number) && number is >= 0 and <= int.MaxValue &&
                    entry["tag"] is JsonValue tag && tag.TryGetValue<string>(out var name)) tags.Add(new((int)number, name));
        return Validated(tags, text).Take(Math.Max(1, (EditingAlgorithms.SplitWords(text).Count + 7) / 8)).ToArray();
    }
    public static string RequestText(string words, IReadOnlyList<VoiceLabAudioTag> tags, string modelId)
    {
        if (tags.Count == 0 || !Supports(modelId)) return StrippingTags(words);
        var tokens = EditingAlgorithms.SplitWords(StrippingTags(words));
        var annotations = Validated(tags, words);
        var result = new List<string>();
        for (var boundary = 0; boundary <= tokens.Count; boundary++)
        {
            result.AddRange(annotations.Where(annotation => annotation.BeforeToken == boundary).Select(annotation => $"[{annotation.Tag}]"));
            if (boundary < tokens.Count) result.Add(tokens[boundary]);
        }
        return string.Join(" ", result);
    }
    public static double Allowance(IReadOnlyList<VoiceLabAudioTag> tags, string text, string modelId) => tags.Count == 0 || !Supports(modelId) ? 0 :
        Validated(tags, text).Sum(annotation => Definitions.First(definition => definition.Tag == annotation.Tag).Seconds);
    internal static IReadOnlyList<Match> TagRanges(string text) => Brackets.Matches(text).Cast<Match>()
        .Where(match => Definitions.Any(definition => definition.Tag == match.Value[1..^1])).ToArray();
    public static string SanitizedRequest(string text, string modelId) => Brackets.Replace(text,
        match => Supports(modelId) && Definitions.Any(definition => definition.Tag == match.Value[1..^1]) ? match.Value : "");
    public static string StrippingTags(string text) => Brackets.Replace(text,
        match => Definitions.Any(definition => definition.Tag == match.Value[1..^1]) ? "" : match.Value);
    public static bool IsScribeEvent(string text)
    {
        var tokens = VoiceLabTakeQuality.Tokens(text);
        return tokens.Length > 0 && Catalog.Value.GetProperty("scribeEvents").EnumerateArray()
            .Any(value => VoiceLabTakeQuality.Tokens(value.GetString()!).SequenceEqual(tokens, StringComparer.Ordinal));
    }
    public static IReadOnlyList<string> FilterScribeEvents(IReadOnlyList<string> expected, IReadOnlyList<string> recognized, bool hasTags)
    {
        var tokens = recognized.SelectMany(VoiceLabTakeQuality.Tokens).ToArray();
        if (!hasTags) return tokens;
        var events = Catalog.Value.GetProperty("scribeEvents").EnumerateArray().SelectMany(value => VoiceLabTakeQuality.Tokens(value.GetString()!))
            .ToHashSet(StringComparer.Ordinal);
        var expectedTokens = expected.SelectMany(VoiceLabTakeQuality.Tokens).ToArray();
        var expectedCounts = expectedTokens.GroupBy(token => token, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        var extras = tokens.GroupBy(token => token, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count() - expectedCounts.GetValueOrDefault(group.Key), StringComparer.Ordinal);
        var matched = new HashSet<int>();
        if (tokens.Length <= 5000 && expectedTokens.Length <= 5000 &&
            extras.Any(pair => pair.Value > 0 && expectedCounts.GetValueOrDefault(pair.Key) > 0 && events.Contains(pair.Key)))
        {
            var width = tokens.Length + 1;
            var lengths = new ushort[(expectedTokens.Length + 1) * width];
            for (var expectedIndex = expectedTokens.Length - 1; expectedIndex >= 0; expectedIndex--)
                for (var recognizedIndex = tokens.Length - 1; recognizedIndex >= 0; recognizedIndex--)
                {
                    var cell = expectedIndex * width + recognizedIndex;
                    lengths[cell] = (ushort)(expectedTokens[expectedIndex] == tokens[recognizedIndex] ?
                        lengths[cell + width + 1] + 1 : Math.Max(lengths[cell + width], lengths[cell + 1]));
                }
            var expectedAt = 0;
            var recognizedAt = 0;
            while (expectedAt < expectedTokens.Length && recognizedAt < tokens.Length)
            {
                if (expectedTokens[expectedAt] == tokens[recognizedAt]) { matched.Add(recognizedAt); expectedAt++; recognizedAt++; }
                else if (lengths[(expectedAt + 1) * width + recognizedAt] >= lengths[expectedAt * width + recognizedAt + 1]) expectedAt++;
                else recognizedAt++;
            }
        }
        return tokens.Where((token, index) =>
        {
            if (matched.Contains(index) || !events.Contains(token) || extras.GetValueOrDefault(token) <= 0) return true;
            extras[token]--;
            return false;
        }).ToArray();
    }

    public static IReadOnlyList<VoiceLabWord> ExtendEdges(IReadOnlyList<VoiceLabWord> words, float[] samples, int rate,
        IReadOnlyList<VoiceLabAudioTag> tags, int tokenCount, string modelId, IReadOnlyList<VoiceLabCharacterTiming> alignment)
    {
        var result = words.ToArray();
        if (words.Count == 0 || tags.Count == 0 || !Supports(modelId)) return result;
        if (rate <= 0 || samples.Length == 0) throw VoiceLabGeometry.Error(VoiceLabGeometryErrorCode.InvalidInput);
        var text = string.Concat(alignment.Select(timing => timing.Character));
        var ranges = TagRanges(text);
        foreach (var incoming in new[] { true, false })
        {
            var edgeTags = tags.Where(tag => tag.BeforeToken == (incoming ? 0 : tokenCount) && AllowedTags.Contains(tag.Tag)).ToArray();
            if (edgeTags.Length == 0) continue;
            var index = incoming ? 0 : result.Length - 1;
            var missing = false;
            var used = new HashSet<int>();
            foreach (var tag in edgeTags)
            {
                var match = Enumerable.Range(0, ranges.Count).Where(rangeIndex => !used.Contains(rangeIndex) && ranges[rangeIndex].Value == $"[{tag.Tag}]" &&
                    EditingAlgorithms.SplitWords(StrippingTags(text[..ranges[rangeIndex].Index])).Count == tag.BeforeToken).Select(rangeIndex => (int?)rangeIndex).FirstOrDefault();
                if (match is null) { missing = true; continue; }
                used.Add(match.Value);
                var range = ranges[match.Value];
                var offset = 0;
                foreach (var timing in alignment)
                {
                    var lower = Math.Max(range.Index, offset);
                    var upper = Math.Min(range.Index + range.Length, offset + timing.Character.Length);
                    var count = timing.Character.EnumerateRunes().Count();
                    if (upper > lower && count > 0)
                    {
                        var boundary = timing.Character[..((incoming ? lower : upper) - offset)].EnumerateRunes().Count();
                        var time = timing.Start + (timing.End - timing.Start) / count * boundary;
                        result[index] = incoming ? result[index] with { Start = Math.Max(0, Math.Min(result[index].Start, time)) } :
                            result[index] with { End = Math.Min(samples.Length / (double)rate, Math.Max(result[index].End, time)) };
                    }
                    offset += timing.Character.Length;
                }
            }
            if (missing)
            {
                var allowance = edgeTags.Sum(tag => Definitions.First(definition => definition.Tag == tag.Tag).Seconds);
                var refined = VoiceLabHardJoin.Refine(words, samples, rate, incoming, !incoming, VoiceLabHardJoin.AcousticSearchSeconds + allowance);
                result[index] = incoming ? result[index] with { Start = Math.Max(0, Math.Min(result[index].Start, refined[index].Start)) } :
                    result[index] with { End = Math.Min(samples.Length / (double)rate, Math.Max(result[index].End, refined[index].End)) };
            }
        }
        return result;
    }
    public static IReadOnlyList<VoiceLabAudioTag> Shifted(IReadOnlyList<VoiceLabAudioTag> tags, int offset) =>
        tags.Select(annotation => annotation with { BeforeToken = annotation.BeforeToken + offset }).ToArray();
    public static IReadOnlyList<VoiceLabAudioTag> Reanchored(IReadOnlyList<VoiceLabAudioTag> tags, string original, string edited)
    {
        if (tags.Count == 0) return [];
        if (original == edited) return Validated(tags, edited);
        var tokens = EditingAlgorithms.SplitWords(original);
        var source = tokens.Select((text, index) => new TimedWord(index.ToString(CultureInfo.InvariantCulture), text, WordKind.Word,
            index, index + 1, null, null, null, null, TimingSource.Native)).ToArray();
        IReadOnlyList<VoiceLabDiffOp> operations;
        try { operations = VoiceLabWordDiff.Diff(source, edited).Ops; }
        catch (VoiceLabWordDiffException) { return []; }
        var boundaries = new int[tokens.Count + 1];
        var oldIndex = 0;
        var newIndex = 0;
        foreach (var operation in operations)
            switch (operation.Kind)
            {
                case VoiceLabDiffOpKind.Equal: boundaries[oldIndex++] = newIndex++; break;
                case VoiceLabDiffOpKind.Delete: boundaries[oldIndex++] = newIndex; break;
                case VoiceLabDiffOpKind.Insert: newIndex++; break;
            }
        boundaries[tokens.Count] = newIndex;
        return Validated(tags, original).Select(annotation => annotation with { BeforeToken = boundaries[annotation.BeforeToken] }).ToArray();
    }
}
