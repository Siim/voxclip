using System.Runtime.CompilerServices;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
namespace VoxClip.Media.Pipeline;

/// <summary>FFmpeg probe placeholder; architecture §6.2. Implement in win-media.</summary>
public sealed class FfmpegMediaProbe : IMediaProbe
{
    /// <inheritdoc />
    public Task<MediaInfo> ProbeAsync(string mediaPath, CancellationToken ct) => Missing<MediaInfo>(ct);
    private static Task<T> Missing<T>(CancellationToken ct) => ct.IsCancellationRequested ? Task.FromCanceled<T>(ct) : Task.FromException<T>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media"));
}
/// <summary>FFmpeg extraction placeholder; architecture §4 and transcription §4.</summary>
public sealed class FfmpegAudioExtractor : IAudioExtractor
{
    /// <inheritdoc />
    public Task<AudioExtractionResult> ExtractAsync(AudioExtractionRequest request, IProgress<MediaProgress>? progress, CancellationToken ct)
        => Task.FromException<AudioExtractionResult>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media"));
}
/// <summary>Preview lifecycle placeholder, never starts decoder threads in the skeleton; architecture §6.3.</summary>
public sealed class PreviewEngine : IPreviewEngine
{
    // TODO(win-media): replace the idle position and safe pause/dispose placeholders with owner-thread playback.
    /// <inheritdoc />
    public PreviewPosition Position => new(0, 0, false);
    /// <inheritdoc />
    public Task LoadAsync(ComposeSnapshot snapshot, IProgress<MediaProgress>? progress, CancellationToken ct) => Missing();
    /// <inheritdoc />
    public Task PlayAsync(CancellationToken ct) => Missing();
    /// <inheritdoc />
    public Task PauseAsync(CancellationToken ct) => Task.CompletedTask;
    /// <inheritdoc />
    public Task SeekAsync(double editedTime, bool exact, CancellationToken ct) => Missing();
    /// <inheritdoc />
    public Task UpdateSnapshotAsync(ComposeSnapshot snapshot, CancellationToken ct) => Missing();
    /// <inheritdoc />
    public Task UpdateCaptionsAsync(CaptionTrack? captions, CancellationToken ct) => Missing();
    /// <inheritdoc />
    public async IAsyncEnumerable<PreviewFrame> ReadFramesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        await Task.CompletedTask.ConfigureAwait(false);
        yield break;
    }
    /// <inheritdoc />
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    private static Task Missing() => Task.FromException(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media"));
}
/// <summary>Sequential exporter placeholder; architecture §6.4. Shares FrameComposer with preview.</summary>
public sealed class Exporter : IExporter
{
    /// <inheritdoc />
    public Task<ExportResult> ExportAsync(ExportJob job, IProgress<ExportProgress>? progress, CancellationToken ct)
        => Task.FromException<ExportResult>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media"));
}
/// <summary>One compose implementation for every consumer; architecture §6.3.5.</summary>
public sealed class FrameComposer : IFrameComposer
{
    /// <inheritdoc />
    public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
        => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media");
}
/// <summary>LGPL-safe hardware encoder ladder; architecture §6.6.</summary>
public sealed class EncoderProbe : IEncoderProbe
{
    /// <summary>Probe order; no software GPL encoder can be inserted here.</summary>
    public static IReadOnlyList<string> Ladder { get; } = Array.AsReadOnly(new[] { "h264_nvenc", "h264_qsv", "h264_amf", "h264_mf" });
    /// <inheritdoc />
    public Task<IReadOnlyList<EncoderInfo>> ProbeAsync(EncoderCacheKey key, IProgress<MediaProgress>? progress, CancellationToken ct)
        => Task.FromException<IReadOnlyList<EncoderInfo>>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-media"));
}
