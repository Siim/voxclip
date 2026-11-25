using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Domain.Clips;

/// <summary>Clip finder prompt preset; AI §11.1.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ClipPreset>))]
public enum ClipPreset
{
    /// <summary>Best moments.</summary>
    [JsonStringEnumMemberName("best")] Best,
    /// <summary>Hooks.</summary>
    [JsonStringEnumMemberName("hooks")] Hooks,
    /// <summary>One per topic.</summary>
    [JsonStringEnumMemberName("topics")] Topics,
    /// <summary>Quotes.</summary>
    [JsonStringEnumMemberName("quotes")] Quotes,
    /// <summary>User instruction.</summary>
    [JsonStringEnumMemberName("custom")] Custom
}

/// <summary>Stored validated suggestion; project schema $defs/aiClip and AI §11.7.</summary>
public sealed record AiClip(string Title, string Reason, int Score, string StartWordId, string EndWordId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<ClipWordRange>? Parts = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? NotInTake = null);

/// <summary>Stored run, stable across cuts; project schema $defs/aiResult.</summary>
public sealed record AiResult(string Id, DateTimeOffset CreatedAt, string Provider, string Model, ClipPreset Preset,
    string? Instructions, string? Language, string InputSha256, IReadOnlyList<AiClip> Clips);

/// <summary>Untrusted numeric indices remain double until validation; AI §2.3 and §11.7.</summary>
public sealed record RawClip(string Title, string Reason, double Score,
    [property: JsonPropertyName("start_word")] double StartWord = -1,
    [property: JsonPropertyName("end_word")] double EndWord = -1,
    IReadOnlyList<RawClipPart>? Parts = null, [property: JsonPropertyName("not_in_take")] string? NotInTake = null);

public readonly record struct RawClipPart([property: JsonPropertyName("start_word")] double Start,
    [property: JsonPropertyName("end_word")] double End);

public readonly record struct ClipIndexRange(int Start, int End)
{
    public int Length => End - Start + 1;
    public int Intersection(ClipIndexRange other) => Math.Max(0, Math.Min(End, other.End) - Math.Max(Start, other.Start) + 1);
}

/// <summary>Preset constraints read from shared/prompts/clip-finder.json, never duplicated in adapters; AI §11.7.</summary>
public sealed record ClipPresetRules(double MinSeconds, double MaxSeconds, int MaxClips, bool NoOverlap, int MaxParts = 1);

/// <summary>One numbered transcript entry with absolute index; AI §11.2.</summary>
public sealed record ClipWord(int Index, string Text, double Start, double End);

/// <summary>Sentence/gap-bounded line used for prompts and snapping; AI §11.3.</summary>
public sealed record TranscriptLine(int FirstIndex, int LastIndex, double Start, double End, string Text);

/// <summary>Inclusive validated item-index range; AI §11.7.</summary>
public sealed record ClipCandidate(string Title, string Reason, int Score, int Start, int End,
    IReadOnlyList<ClipIndexRange>? Parts = null, string? NotInTake = null)
{
    public IReadOnlyList<ClipIndexRange> PlayParts => Parts ?? [new(Start, End)];
}

/// <summary>Pure clip-validation input, including cuts and optional sentence snapping; AI §11.7.</summary>
public sealed record FinalizeClipsRequest(IReadOnlyList<RawClip> Candidates, IReadOnlyList<TimedWord> Words,
    ClipPresetRules Preset, IReadOnlyList<TranscriptLine> Lines, IReadOnlySet<string> CutSet,
    int WindowCount, bool Snap, IReadOnlyDictionary<string, string>? Corrections = null);

/// <summary>Clip filtering result; AI §11.7.</summary>
public sealed record FinalizeClipsResult(IReadOnlyList<ClipCandidate> Clips, int DroppedItems);

internal sealed record ClipValidationLimits(int TitleMaxLength = 120, int ReasonMaxLength = 300, int ScoreMin = 1, int ScoreMax = 10,
    double MinLengthFloorSeconds = 2, double MinLengthFactor = 0.6, double MaxLengthFactor = 1.4,
    int SnapRadiusWords = 3, double MostlyCutFraction = 0.5, double NearDuplicateOverlap = 0.6);

/// <summary>Pure clip pipeline entry points; AI §11.</summary>
public static class ClipValidation
{
    /// <summary>Validate integer indices, bounds, duration and score; never mutate edits.</summary>
    public static FinalizeClipsResult FinalizeClips(FinalizeClipsRequest request) => FinalizeClips(request, new());

    internal static FinalizeClipsResult FinalizeClips(FinalizeClipsRequest request, ClipValidationLimits limits)
    {
        var ranked = new List<(ClipCandidate Clip, int Arrival)>();
        for (var arrival = 0; arrival < request.Candidates.Count; arrival++)
        {
            var raw = request.Candidates[arrival];
            var proposed = raw.Parts ?? [new(raw.StartWord, raw.EndWord)];
            if (!double.IsFinite(raw.Score) || proposed.Count > request.Preset.MaxParts) continue;
            var minimum = Math.Max(limits.MinLengthFloorSeconds, request.Preset.MinSeconds * limits.MinLengthFactor);
            var maximum = request.Preset.MaxSeconds * limits.MaxLengthFactor;
            var parts = new List<ClipIndexRange>();
            var duration = 0.0;
            foreach (var item in proposed)
            {
                if (!double.IsFinite(item.Start) || !double.IsFinite(item.End) || item.Start != Math.Floor(item.Start) || item.End != Math.Floor(item.End) ||
                    item.Start < 0 || item.End < item.Start || item.End >= request.Words.Count) continue;
                var start = (int)item.Start;
                var end = (int)item.End;
                if (request.Snap)
                {
                    var snapped = ClipText.Snap(start, end, request.Lines, limits.SnapRadiusWords);
                    if (snapped.Item1 >= 0 && snapped.Item1 <= snapped.Item2 && snapped.Item2 < request.Words.Count) (start, end) = snapped;
                }
                var part = new ClipIndexRange(start, end);
                var length = request.Words[end].End - request.Words[start].Start;
                if (length < minimum || length > maximum || parts.Any(previous => previous.Intersection(part) > 0)) continue;
                var cuts = 0;
                for (var index = start; index <= end; index++) if (request.CutSet.Contains(request.Words[index].Id)) cuts++;
                if ((double)cuts / part.Length > limits.MostlyCutFraction) continue;
                parts.Add(part);
                duration += length;
            }
            if (parts.Count == 0 || duration > maximum) continue;
            var reason = CheckReason(raw.Reason, parts, request);
            var rounded = Math.Floor(raw.Score) + (raw.Score - Math.Floor(raw.Score) >= 0.5 ? 1 : 0);
            ranked.Add((new(ClipText.Limit(ClipText.Trim(raw.Title), limits.TitleMaxLength), ClipText.Limit(ClipText.Trim(reason), limits.ReasonMaxLength),
                (int)Math.Clamp(rounded, limits.ScoreMin, limits.ScoreMax), parts.Min(part => part.Start), parts.Max(part => part.End), parts.Count > 1 ? parts : null, raw.NotInTake), arrival));
        }
        var chosen = new List<ClipCandidate>();
        foreach (var item in ranked.OrderBy(item => item.Clip.Score * -1).ThenBy(item => item.Arrival))
        {
            if (chosen.Count >= request.Preset.MaxClips) break;
            var clip = item.Clip;
            var left = clip.PlayParts;
            if (chosen.Any(other =>
            {
                var right = other.PlayParts;
                if (left.SequenceEqual(right)) return true;
                var intersection = left.Sum(part => right.Sum(part.Intersection));
                var union = left.Sum(part => part.Length) + right.Sum(part => part.Length) - intersection;
                return (request.Preset.NoOverlap && intersection > 0) ||
                    (request.WindowCount > 1 && (double)intersection / union >= limits.NearDuplicateOverlap);
            })) continue;
            chosen.Add(clip);
        }
        var ordered = chosen.Select((clip, selection) => (clip, selection)).OrderBy(item => item.clip.Start)
            .ThenBy(item => item.selection).Select(item => item.clip).ToArray();
        return new(ordered, request.Candidates.Count - ordered.Length);
    }

    private static readonly Regex ReasonQuotes = new("“([^”]*)”|\"([^\"]*)\"", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex QuoteWords = new(@"[\p{L}\p{M}\p{N}]+", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    private static string CheckReason(string reason, IReadOnlyList<ClipIndexRange> parts, FinalizeClipsRequest request)
    {
        if (!ReasonQuotes.IsMatch(reason)) return reason;
        static string Normalize(string text) => string.Join(" ", QuoteWords.Matches(text.ToLowerInvariant()).Select(match => match.Value));
        var spoken = parts.Select(part => " " + Normalize(string.Join(" ", request.Words.Skip(part.Start).Take(part.Length)
            .Where(word => word.Kind == WordKind.Word && !request.CutSet.Contains(word.Id))
            .Select(word => request.Corrections?.GetValueOrDefault(word.Id) ?? word.Text))) + " ").ToArray();
        return ReasonQuotes.Replace(reason, match =>
        {
            var quote = Normalize(match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value);
            return quote.Length > 0 && spoken.Any(part => part.Contains(" " + quote + " ", StringComparison.Ordinal)) ? match.Value : "";
        });
    }
    /// <summary>Numbered transcript block sent unchanged across providers; AI §11.2.</summary>
    public static string FormatTranscript(IReadOnlyList<TimedWord> words, IReadOnlyDictionary<string, string> corrections) =>
        ClipText.Render(ClipText.Lines(ClipText.Entries(words, corrections)));
}

/// <summary>M2 tighten proposal, pure cuts only; AI §12.</summary>
public sealed record TightenEdit(int Start, int End, string Reason);

/// <summary>M2 tighten suggestions; AI §12. No network action until explicitly requested.</summary>
public sealed record TightenResult(IReadOnlyList<TightenEdit> Edits, int DroppedItems);
