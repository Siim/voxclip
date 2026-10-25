using VoxClip.Core.Domain.Transcript;
namespace VoxClip.Core.Services.Speech;

/// <summary>Cancelable transcriber adapter; transcription §3.3. Local work must observe cancellation within one second.</summary>
public interface ITranscriber
{
    /// <summary>Router engine id.</summary>
    TranscriptEngine Engine { get; }
    /// <summary>Describe capabilities without starting work.</summary>
    TranscriberCapabilities Capabilities(string? model);
    /// <summary>Check language support without cloud fallback.</summary>
    Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct);
    /// <summary>Preflight keys, installed models and language support.</summary>
    Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct);
    /// <summary>Prepare system assets when relevant; mirrors the Swift protocol.</summary>
    Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct);
    /// <summary>Return raw adapter tokens. Caller owns post-processing.</summary>
    Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct);
}

/// <summary>Import orchestration; architecture §7.2 and transcription §5.</summary>
public interface ITranscriptionService
{
    /// <summary>Transcribe with the caller's decoded envelope and stage-local progress; plan W5 and transcription §3.3.</summary>
    Task<Transcript> TranscribeAsync(TranscriptionRequest request, AudioEnvelope? envelope, IProgress<TranscriptionProgress>? progress, CancellationToken ct);
    /// <summary>Compatibility entry point that resolves the cached envelope for the caller.</summary>
    Task<Transcript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct);
}
