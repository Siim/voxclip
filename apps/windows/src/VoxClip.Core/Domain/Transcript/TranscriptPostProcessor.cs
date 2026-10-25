using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.Transcript;

/// <summary>Hands engine assembly to the editing-owned import pipeline; transcription §5.</summary>
public static class TranscriptPostProcessor
{
    /// <summary>Assemble engine tokens and create an immutable import transcript.</summary>
    public static Transcript Process(RawTranscript raw, double duration, AudioEnvelope? envelope, string rawKey, DateTimeOffset createdAt)
    {
        if (raw.Timing is TimingSource.Estimated or TimingSource.Detected)
            throw new VoxClipException(VoxClipErrorCode.TranscriptionFailed, "Transcription stopped: the engine returned unsupported timing. Your video is still here.");
        var import = EditingImport.Pipeline(WordAssembler.Group(raw.Tokens, raw.Grouping, 0), envelope, raw.Timing, raw.Verbatim, duration);
        return new(1, import.Words, raw.Language, raw.LanguageProbability, duration,
            raw.Engine, raw.Verbatim, envelope is not null && import.PauseThresholdSeconds == 0.8,
            1, rawKey, createdAt);
    }
}
