using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
namespace VoxClip.Media.Speech;

/// <summary>Whisper.net CPU adapter placeholder, x64 and ARM64 runtimes; transcription §9. Never loads a model at app startup.</summary>
public sealed class WhisperNetTranscriber : ITranscriber
{
    // TODO(win-speech): check installed CPU models; unavailable readiness and no-op preparation load no model.
    /// <inheritdoc />
    public TranscriptEngine Engine => TranscriptEngine.Whispercpp;
    /// <inheritdoc />
    public TranscriberCapabilities Capabilities(string? model) => new(TimingSource.Dtw, true, true, null, null, true);
    /// <inheritdoc />
    public Task<bool> SupportsAsync(LanguageChoice language, string? model, CancellationToken ct) => Task.FromException<bool>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-speech"));
    /// <inheritdoc />
    public Task<Readiness> ReadinessAsync(TranscriptionPlan plan, CancellationToken ct) => Task.FromResult<Readiness>(new Readiness.Unavailable("win-speech"));
    /// <inheritdoc />
    public Task PrepareAsync(TranscriptionPlan plan, IProgress<double>? progress, CancellationToken ct) => Task.CompletedTask;
    /// <inheritdoc />
    public Task<RawTranscript> TranscribeAsync(TranscriptionRequest request, IProgress<TranscriptionProgress> progress, CancellationToken ct)
        => Task.FromException<RawTranscript>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-speech"));
}
