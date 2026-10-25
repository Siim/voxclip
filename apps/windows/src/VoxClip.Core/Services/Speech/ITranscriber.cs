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

/// <summary>ElevenLabs HTTP adapter placeholder; transcription §8. Never uploads until explicitly invoked.</summary>
public sealed class ElevenLabsTranscriber : ITranscriber
{
    // TODO(win-speech): implement preflight; unavailable readiness and no-op preparation never upload audio.
    /// <inheritdoc />
    public TranscriptEngine Engine => TranscriptEngine.Elevenlabs;
    /// <inheritdoc />
    public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Native, true, true, 36_000, null, false);
    /// <inheritdoc />
    public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => ServiceStub.Missing<bool>("win-speech", ct);
    /// <inheritdoc />
    public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(new Readiness.Unavailable("win-speech"));
    /// <inheritdoc />
    public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
    /// <inheritdoc />
    public Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct) => ServiceStub.Missing<RawTranscript>("win-speech", ct);
}

/// <summary>Import orchestration; architecture §7.2 and transcription §5.</summary>
public interface ITranscriptionService
{
    /// <summary>Route, preflight, transcribe, post-process and cache without silent engine switching.</summary>
    Task<Transcript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct);
}
/// <summary>Transcription orchestration placeholder owned by win-speech.</summary>
public sealed class TranscriptionService : ITranscriptionService
{
    /// <inheritdoc />
    public Task<Transcript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct) => ServiceStub.Missing<Transcript>("win-speech", ct);
}
