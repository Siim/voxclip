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

/// <summary>Pure clip pipeline entry points; AI §11.</summary>
public static class ClipValidation
{
    /// <summary>Validate integer indices, bounds, duration and score; never mutate edits.</summary>
    public static FinalizeClipsResult FinalizeClips(FinalizeClipsRequest request) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-ai");
    /// <summary>Numbered transcript block sent unchanged across providers; AI §11.2.</summary>
    public static string FormatTranscript(IReadOnlyList<TimedWord> words, IReadOnlyDictionary<string, string> corrections) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-ai");
}

/// <summary>M2 tighten proposal, pure cuts only; AI §12.</summary>
public sealed record TightenEdit(int Start, int End, string Reason);

/// <summary>M2 tighten suggestions; AI §12. No network action until explicitly requested.</summary>
public sealed record TightenResult(IReadOnlyList<TightenEdit> Edits, int DroppedItems);
