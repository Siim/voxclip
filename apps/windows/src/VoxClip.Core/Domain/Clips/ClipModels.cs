using System.Text.Json.Serialization;
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
public sealed record AiClip(string Title, string Reason, int Score, string StartWordId, string EndWordId);

/// <summary>Stored run, stable across cuts; project schema $defs/aiResult.</summary>
public sealed record AiResult(string Id, DateTimeOffset CreatedAt, string Provider, string Model, ClipPreset Preset,
    string? Instructions, string? Language, string InputSha256, IReadOnlyList<AiClip> Clips);

/// <summary>Untrusted numeric indices remain double until validation; AI §2.3 and §11.7.</summary>
public sealed record RawClip(string Title, string Reason, double Score,
    [property: JsonPropertyName("start_word")] double StartWord,
    [property: JsonPropertyName("end_word")] double EndWord);

/// <summary>Preset constraints read from shared/prompts/clip-finder.json, never duplicated in adapters; AI §11.7.</summary>
public sealed record ClipPresetRules(double MinSeconds, double MaxSeconds, int MaxClips, bool NoOverlap);

/// <summary>One numbered transcript entry with absolute index; AI §11.2.</summary>
public sealed record ClipWord(int Index, string Text, double Start, double End);

/// <summary>Sentence/gap-bounded line used for prompts and snapping; AI §11.3.</summary>
public sealed record TranscriptLine(int FirstIndex, int LastIndex, double Start, double End, string Text);

/// <summary>Inclusive validated item-index range; AI §11.7.</summary>
public sealed record ClipCandidate(string Title, string Reason, int Score, int Start, int End);

/// <summary>Pure clip-validation input, including cuts and optional sentence snapping; AI §11.7.</summary>
public sealed record FinalizeClipsRequest(IReadOnlyList<RawClip> Candidates, IReadOnlyList<TimedWord> Words,
    ClipPresetRules Preset, IReadOnlyList<TranscriptLine> Lines, IReadOnlySet<string> CutSet,
    int WindowCount, bool Snap);

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
            if (!double.IsFinite(raw.StartWord) || !double.IsFinite(raw.EndWord) || !double.IsFinite(raw.Score) ||
                raw.StartWord != Math.Floor(raw.StartWord) || raw.EndWord != Math.Floor(raw.EndWord) ||
                raw.StartWord < 0 || raw.StartWord > raw.EndWord || raw.EndWord >= request.Words.Count) continue;
            var start = (int)raw.StartWord;
            var end = (int)raw.EndWord;
            if (request.Snap) (start, end) = ClipText.Snap(start, end, request.Lines, limits.SnapRadiusWords);
            var length = request.Words[end].End - request.Words[start].Start;
            if (length < Math.Max(limits.MinLengthFloorSeconds, request.Preset.MinSeconds * limits.MinLengthFactor) || length > request.Preset.MaxSeconds * limits.MaxLengthFactor) continue;
            var cuts = 0;
            for (var index = start; index <= end; index++) if (request.CutSet.Contains(request.Words[index].Id)) cuts++;
            if ((double)cuts / (end - start + 1) > limits.MostlyCutFraction) continue;
            var rounded = Math.Floor(raw.Score) + (raw.Score - Math.Floor(raw.Score) >= 0.5 ? 1 : 0);
            ranked.Add((new(ClipText.Limit(ClipText.Trim(raw.Title), limits.TitleMaxLength), ClipText.Limit(ClipText.Trim(raw.Reason), limits.ReasonMaxLength),
                (int)Math.Clamp(rounded, limits.ScoreMin, limits.ScoreMax), start, end), arrival));
        }
        var chosen = new List<ClipCandidate>();
        foreach (var item in ranked.OrderBy(item => item.Clip.Score * -1).ThenBy(item => item.Arrival))
        {
            if (chosen.Count >= request.Preset.MaxClips) break;
            var clip = item.Clip;
            if (chosen.Any(other => (clip.Start == other.Start && clip.End == other.End) ||
                (request.WindowCount > 1 && ClipText.Overlap(clip, other) >= limits.NearDuplicateOverlap) ||
                (request.Preset.NoOverlap && clip.Start <= other.End && other.Start <= clip.End))) continue;
            chosen.Add(clip);
        }
        var ordered = chosen.Select((clip, selection) => (clip, selection)).OrderBy(item => item.clip.Start)
            .ThenBy(item => item.selection).Select(item => item.clip).ToArray();
        return new(ordered, request.Candidates.Count - ordered.Length);
    }
    /// <summary>Numbered transcript block sent unchanged across providers; AI §11.2.</summary>
    public static string FormatTranscript(IReadOnlyList<TimedWord> words, IReadOnlyDictionary<string, string> corrections) =>
        ClipText.Render(ClipText.Lines(ClipText.Entries(words, corrections)));
}

/// <summary>M2 tighten proposal, pure cuts only; AI §12.</summary>
public sealed record TightenEdit(int Start, int End, string Reason);

/// <summary>M2 tighten suggestions; AI §12. No network action until explicitly requested.</summary>
public sealed record TightenResult(IReadOnlyList<TightenEdit> Edits, int DroppedItems);
