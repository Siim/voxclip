using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Probe result for the presentation timeline; architecture §4 and §6.2.</summary>
public sealed record MediaInfo(string Path, double DurationSeconds, VideoTrackInfo? Video, AudioTrackInfo? Audio,
    PixelSize OrientedSize, string? VideoCodec, string? AudioCodec, bool IsHdr, int VideoTrackIndex, int AudioTrackIndex, double AudioTimelineStart);
/// <summary>Audio extraction input; architecture §4 and transcription §4.</summary>
public sealed record AudioExtractionRequest(MediaInfo Media, string ContentKey, string CacheDirectory);
/// <summary>Media progress, throttled to at most 10Hz; architecture §7.2.</summary>
public sealed record MediaProgress(string Phase, double? Fraction);
/// <summary>Exactly one immutable compose snapshot for preview/export; architecture §6.3–6.4.</summary>
public sealed record ComposeSnapshot(MediaInfo Media, EditPlan Plan, CaptionTrack? Captions, OutputSpec Output)
{
    /// <summary>Captured v3 input; null keeps the existing source-only edit route.</summary>
    public VoiceLabRenderInput? VoiceLab { get; init; }
    /// <summary>The single timeline used for duration, source frames, and audio.</summary>
    public RenderTimeline Timeline => VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true } input
        ? new RenderTimeline.VoiceLab(input.Prepared.OutputPlan) : new RenderTimeline.Legacy(Plan);
}
/// <summary>Output encoding configuration; architecture §4.1 and §6.4.</summary>
public sealed record OutputSpec(PixelSize Size, double FrameRate, long VideoBitrate, int AudioSampleRate = 48_000,
    int AudioChannels = 2, long AudioBitrate = 160_000, string VideoCodec = "h264");
/// <summary>Full-edit or clip export target; architecture §4.</summary>
public abstract record ExportTarget
{
    /// <summary>All kept source words.</summary>
    public sealed record FullEdit : ExportTarget;
    /// <summary>One range layer, retaining existing cuts.</summary>
    public sealed record Clip(string Id) : ExportTarget;
}
/// <summary>One sequential export job; architecture §4 and §6.4.</summary>
public sealed record ExportJob(ComposeSnapshot Snapshot, ExportTarget Target, ExportAspect Aspect,
    ExportQuality Quality, string OutputPath, string? SrtPath);
/// <summary>Export progress with explicit phases; architecture §6.4.</summary>
public sealed record ExportProgress(string Phase, double? Fraction, long FramesEncoded, long? TotalFrames);
/// <summary>Successful final output, never a partial path; architecture §9.3.</summary>
public sealed record ExportResult(string Output, string? Srt, double DurationSeconds, int Width, int Height, double Fps,
    long Frames, int AudioSampleRate, long AudioSamples, string VideoCodec, string Encoder, double ElapsedSeconds)
{
    /// <summary>Rung 5 used the OS software MFT; show the acceleration notice once per export.</summary>
    public bool SoftwareEncoding { get; init; }
}
/// <summary>Frame hand-off; caller owns its lifetime. Preview uses a bounded channel of six; architecture §6.3.</summary>
public sealed record PreviewFrame(PixelBuffer Buffer, double EditedPts, double SourcePts, long Generation);
/// <summary>Preview audio-clock position; architecture §6.3.</summary>
public sealed record PreviewPosition(double EditedTime, double SourceTime, bool IsPlaying);
/// <summary>Encoder ladder probe result; architecture §6.6. There is no GPL fallback.</summary>
public sealed record EncoderInfo(string Name, bool Available, string? Reason);
/// <summary>Adapter/driver/build identity for encoder cache invalidation; architecture §6.6.</summary>
public sealed record EncoderCacheKey(string AdapterLuid, string DriverVersion, string FfmpegVersion);
