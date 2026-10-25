using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Domain.Transcript;

/// <summary>Persisted transcript, matching project.schema.json exactly; architecture §3 and editing §2.3. See CONTRACTS.md for the transcription §3.1 conflict.</summary>
public sealed record Transcript(int SchemaVersion, IReadOnlyList<TimedWord> Words, string? Language,
    double? LanguageProbability, double DurationSeconds, TranscriptEngineInfo Engine, bool Verbatim,
    bool Refined, int PipelineVersion, string RawKey, DateTimeOffset CreatedAt);

/// <summary>Persisted engine identity, distinct from routing enum; project schema $defs/transcript.</summary>
public sealed record TranscriptEngineInfo(string Id, string? ModelId, string? ModelSha256, string EngineVersion, string? Locale);

/// <summary>Transcription router engine identifiers; transcription §3.1.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<TranscriptEngine>))]
public enum TranscriptEngine
{
    /// <summary>ElevenLabs Scribe.</summary>
    [JsonStringEnumMemberName("elevenlabs")] Elevenlabs,
    /// <summary>Local Whisper.</summary>
    [JsonStringEnumMemberName("whispercpp")] Whispercpp,
    /// <summary>Apple Speech, catalog decoding only on Windows.</summary>
    [JsonStringEnumMemberName("apple-speech")] AppleSpeech
}

/// <summary>Per-word timing provenance; transcription §3.1. Estimated is raw-only, not accepted by the v1 persisted word schema.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<TimingSource>))]
public enum TimingSource
{
    /// <summary>Native word timestamps.</summary>
    [JsonStringEnumMemberName("native")] Native,
    /// <summary>Grouped token timestamps.</summary>
    [JsonStringEnumMemberName("tokenGrouped")] TokenGrouped,
    /// <summary>DTW-aligned token timestamps.</summary>
    [JsonStringEnumMemberName("dtw")] Dtw,
    /// <summary>Grouped Apple runs.</summary>
    [JsonStringEnumMemberName("runGrouped")] RunGrouped,
    /// <summary>Estimated times, raw-only in v1.</summary>
    [JsonStringEnumMemberName("estimated")] Estimated,
    /// <summary>Detected unlabeled speech.</summary>
    [JsonStringEnumMemberName("detected")] Detected
}

/// <summary>Post-processing refinement state; transcription §3.1.</summary>
public enum BoundaryRefinement
{
    /// <summary>Audio refinement applied.</summary>
    Applied,
    /// <summary>No decoded envelope.</summary>
    Skipped
}
