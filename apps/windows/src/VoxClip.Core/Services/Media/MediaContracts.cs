using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
namespace VoxClip.Core.Services.Media;

/// <summary>Media-free probe contract implemented by Media; architecture §2.1 and §6.2.</summary>
public interface IMediaProbe
{
    /// <summary>Probe presentation duration, tracks, display orientation and HDR metadata.</summary>
    Task<MediaInfo> ProbeAsync(string mediaPath, CancellationToken ct);
}
/// <summary>Audio extraction and native-rate envelope; transcription §4.</summary>
public interface IAudioExtractor
{
    /// <summary>Create a cache PCM16 mono16k WAV and 10ms RMS envelope.</summary>
    Task<AudioExtractionResult> ExtractAsync(AudioExtractionRequest request, IProgress<MediaProgress>? progress, CancellationToken ct);
}
/// <summary>Combined extraction products; architecture §4.</summary>
public sealed record AudioExtractionResult(ExtractedAudio Audio, AudioEnvelope Envelope);
/// <summary>Audio-clocked preview with immutable snapshots; architecture §6.3 and §7.2.</summary>
public interface IPreviewEngine : IAsyncDisposable
{
    /// <summary>Clock position; immutable value, never native context state.</summary>
    PreviewPosition Position { get; }
    /// <summary>Recoverable playback failure, raised on the engine owner thread; also fails the next Play or Seek once.</summary>
    event EventHandler<Exception>? PlaybackFaulted { add { } remove { } }
    /// <summary>Non-fatal audio output change, raised on the engine owner thread only when the status changes. Without usable output, video and the clock keep playing; a lost device gets one immediate reopen and every later start retries.</summary>
    event EventHandler<PreviewAudioStatus>? AudioStatusChanged { add { } remove { } }
    /// <summary>Load media and a plan snapshot.</summary>
    Task LoadAsync(ComposeSnapshot snapshot, IProgress<MediaProgress>? progress, CancellationToken ct);
    /// <summary>Start edited playback.</summary>
    Task PlayAsync(CancellationToken ct);
    /// <summary>Pause playback.</summary>
    Task PauseAsync(CancellationToken ct);
    /// <summary>Seek edited time; scrub seeks may coalesce.</summary>
    Task SeekAsync(double editedTime, bool exact, CancellationToken ct);
    /// <summary>Swap a plan, preserving source playhead time.</summary>
    Task UpdateSnapshotAsync(ComposeSnapshot snapshot, CancellationToken ct);
    /// <summary>Swap captions without rebuilding the plan and recompose the paused frame once.</summary>
    Task UpdateCaptionsAsync(CaptionTrack? captions, CancellationToken ct);
    /// <summary>Read bounded frame hand-offs for the engine lifetime, across recoverable playback faults. No re-subscribe is needed; only disposal or a terminal owner failure completes the stream. Consumer presents only the newest frame due at the clock.</summary>
    IAsyncEnumerable<PreviewFrame> ReadFramesAsync(CancellationToken ct);
}
/// <summary>Preview audio output state; never fatal, and export never needs an output device.</summary>
public enum PreviewAudioStatus
{
    /// <summary>Audio plays on the default output device, or no playback has needed one yet.</summary>
    Available,
    /// <summary>No default output device, or it was lost during playback; video keeps playing without sound.</summary>
    NoOutputDevice,
    /// <summary>Another app holds the output device exclusively; video keeps playing without sound.</summary>
    OutputInUse,
}
/// <summary>Sequential MP4 exporter sharing the exact preview compose path; architecture §6.4.</summary>
public interface IExporter
{
    /// <summary>Write .partial and rename only on success; delete partial on failure/cancellation.</summary>
    Task<ExportResult> ExportAsync(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct);
}
/// <summary>Hardware-only H264 ladder; architecture §6.6.</summary>
public interface IEncoderProbe
{
    /// <summary>Probe NVENC, QSV, AMF then Media Foundation; never x264/x265.</summary>
    Task<IReadOnlyList<EncoderInfo>> ProbeAsync(EncoderCacheKey key, IProgress<MediaProgress>? progress, CancellationToken ct);
}
/// <summary>Shared per-frame compositor; architecture §6.3.5. Never duplicate this implementation in preview and export.</summary>
public interface IFrameComposer
{
    /// <summary>Orient, crop, scale, tone-map and draw captions into a caller-owned BGRA buffer.</summary>
    void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct);
}
