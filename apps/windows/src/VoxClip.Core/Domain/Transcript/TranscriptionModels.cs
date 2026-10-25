using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Domain.Transcript;

/// <summary>Raw adapter engine identity; transcription §3.2.</summary>
public sealed record EngineRef(TranscriptEngine Engine, string? Model, string? ModelSha256, string EngineVersion, string? Locale);
/// <summary>One complete-UTF8 engine token; transcription §3.2. Input times precede presentation offset correction.</summary>
public sealed record RawToken(string Text, bool JoinsPrevious, double? Start, double? End, double? Conf, string? Speaker, WordKind? Kind, int Group);
/// <summary>Adapter result, cached before import post-processing; transcription §3.2.</summary>
public sealed record RawTranscript(EngineRef Engine, int AdapterVersion, GroupingRule Grouping,
    IReadOnlyList<RawToken> Tokens, string? Language, double? LanguageProbability, bool Verbatim, TimingSource Timing, string? ProviderRequestId);
/// <summary>Assembler output before cleanWords; transcription §3.2 and editing §5.0.</summary>
public sealed record RawWord(string Text, double? Start, double? End, double? Conf, string? Speaker, WordKind Kind);
/// <summary>Token grouping end rule; transcription §6.</summary>
public enum GroupingEnd
{
    /// <summary>Use the last token end.</summary>
    LastToken,
    /// <summary>Use the next word start.</summary>
    NextWordStart
}
/// <summary>Token confidence aggregation; transcription §6.</summary>
public enum GroupingConfidence
{
    /// <summary>Single token confidence.</summary>
    Single,
    /// <summary>Arithmetic mean.</summary>
    Mean,
    /// <summary>Minimum confidence.</summary>
    Min
}
/// <summary>Per-adapter token assembly rules; transcription §6.</summary>
public sealed record GroupingRule(GroupingEnd End, GroupingConfidence Conf, bool BracketEvents);
/// <summary>Auto-detection or forced BCP47 choice; transcription §3.3.</summary>
public abstract record LanguageChoice
{
    /// <summary>Detect language locally or with the chosen engine.</summary>
    public sealed record Auto : LanguageChoice;
    /// <summary>Force the supplied BCP47 code.</summary>
    public sealed record Forced(string Code) : LanguageChoice;
}
/// <summary>Explicit engine options; transcription §3.3.</summary>
public sealed record TranscriptionOptions(bool Diarize = false, int? NumSpeakers = null, IReadOnlyList<string>? Keyterms = null, bool Dtw = true);
/// <summary>Chosen engine, model and language; transcription §3.3.</summary>
public sealed record TranscriptionPlan(TranscriptEngine Engine, string? Model, LanguageChoice Language, TranscriptionOptions Options);
/// <summary>16kHz mono PCM16 extraction result; transcription §4.</summary>
public sealed record ExtractedAudio(string Wav16kPath, long SampleCount, double DurationSeconds, double TimelineStart, int AudioTrackIndex);
/// <summary>Cancelable adapter request; transcription §3.3.</summary>
public sealed record TranscriptionRequest(TranscriptionPlan Plan, ExtractedAudio Audio, string ContentKey);
/// <summary>Progress phases; transcription §13.</summary>
public enum TranscriptionStage
{
    /// <summary>Prepare input and model.</summary>
    Preparing,
    /// <summary>Explicit cloud upload.</summary>
    Uploading,
    /// <summary>Decode speech.</summary>
    Transcribing,
    /// <summary>Align and refine.</summary>
    Aligning
}
/// <summary>Fraction within a stage, null when indeterminate; transcription §3.3.</summary>
public readonly record struct TranscriptionProgress(TranscriptionStage Stage, double? Fraction);
/// <summary>Engine capabilities for a selected model; transcription §3.3.</summary>
public sealed record TranscriberCapabilities(TimingSource Timing, bool Verbatim, bool AutoLanguage, double? MaxDurationSeconds, long? MaxUploadBytes, bool OnDevice);
/// <summary>Non-destructive engine readiness; transcription §3.3.</summary>
public abstract record Readiness
{
    /// <summary>Ready to transcribe.</summary>
    public sealed record Ready : Readiness;
    /// <summary>Provider key required.</summary>
    public sealed record NeedsKey(string Provider) : Readiness;
    /// <summary>Explicit model download required.</summary>
    public sealed record NeedsModels(IReadOnlyList<string> Ids, long Bytes) : Readiness;
    /// <summary>Apple-only assets, retained to mirror the Swift contract.</summary>
    public sealed record NeedsSystemAssets(string Locale) : Readiness;
    /// <summary>Unsupported language; never silently upload.</summary>
    public sealed record UnsupportedLanguage(string Code) : Readiness;
    /// <summary>Unavailable runtime.</summary>
    public sealed record Unavailable(string Reason) : Readiness;
}
/// <summary>Decoded native-rate audio envelope; transcription §4 and editing §5.</summary>
public sealed record AudioEnvelope(int SampleRate, double FrameSeconds, IReadOnlyList<float> Rms);
/// <summary>Pure raw-token assembly; transcription §6.</summary>
public static class WordAssembler
{
    /// <summary>Group tokens without changing their order.</summary>
    public static IReadOnlyList<RawWord> Group(IReadOnlyList<RawToken> tokens, GroupingRule rule, double timelineStart) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-speech");
}
/// <summary>Pure import processing; transcription §7 and editing §5.</summary>
public static class TranscriptPostProcessor
{
    /// <summary>Clean, tighten, refine, detect omitted speech and assign stable ids once.</summary>
    public static Transcript Process(RawTranscript raw, double duration, AudioEnvelope? envelope, string rawKey, DateTimeOffset createdAt) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-speech");
}
