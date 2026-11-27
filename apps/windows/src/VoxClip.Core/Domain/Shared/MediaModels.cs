using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.Music;
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
    private readonly IReadOnlyList<RecordingRenderSource> recordingSources = [];
    private readonly IReadOnlyList<RecordingRenderSource> spanSources = [];
    /// <summary>Verified recordings, parallel to the kept intervals. Empty keeps the single-file path.</summary>
    public IReadOnlyList<RecordingRenderSource> SpanSources
    {
        get => spanSources;
        init { spanSources = value; recordingSources = value.DistinctBy(source => source.ContentKey).ToArray(); }
    }
    /// <summary>Find the recording under a sample on the project clock.</summary>
    public RecordingRenderSource? RecordingAt(long sample) => recordingSources.FirstOrDefault(source =>
        source.OffsetSamples <= sample && sample < source.OffsetSamples + source.DurationSamples);
    /// <summary>Find the recording under a time on the project clock.</summary>
    public RecordingRenderSource? RecordingAtTime(double sourceTime) => RecordingAt((long)EditingMath.Round(sourceTime * Plan.SampleRate));
    /// <summary>Captured v3 input; null keeps the existing source-only edit route.</summary>
    public VoiceLabRenderInput? VoiceLab { get; init; }
    /// <summary>The clip's controls and the scope's effects (design §6.9, ai.md §18.5); null renders exactly as before.</summary>
    public ClipRenderInput? Clip { get; init; }
    /// <summary>The screen recordings placed over this scope (doc/spec/context-demo.md); null draws the source picture throughout.</summary>
    public VoxClip.Core.Domain.ContextDemo.ContextDemoRenderLayers? ContextDemo { get; init; }
    /// <summary>Resolved, silent companion placements on the edited clock.</summary>
    public IReadOnlyList<FootageRenderLayer> Footage { get; init; } = [];
    /// <summary>The clip's speed timing; 1× without controls.</summary>
    public ClipSpeedTiming Speed => ClipSpeedTiming.ForEffects(Clip?.Controls?.Speed ?? 1, Timeline.MapTime, Clip?.Effects?.Effects ?? [], Timeline.MapEndTime);
    /// <summary>The rendered length in samples at the timeline rate: the edited length divided by the speed. One speed for the
    /// whole clip divides the sample count exactly (the shared clip-render vectors); spans of partial speed go through seconds.</summary>
    public long RenderedSamples => Speed.Spans.Count == 0
        ? Speed.RenderedSamples(Timeline.OutputSamples)
        : (long)Math.Round(Speed.Rendered(Timeline.Duration) * Timeline.SampleRate, MidpointRounding.AwayFromZero);
    /// <summary>The rendered length in seconds.</summary>
    public double RenderedDuration => RenderedSamples / Timeline.SampleRate;
    /// <summary>The single timeline used for duration, source frames, and audio.</summary>
    public RenderTimeline Timeline => VoiceLab is { Prepared.OutputPlan.RequiresSyntheticRendering: true } input
        ? new RenderTimeline.VoiceLab(input.Prepared.OutputPlan) : new RenderTimeline.Legacy(Plan);
}

/// <summary>A verified local recording and its location and stored gain on the project clock.</summary>
public sealed record RecordingRenderSource(string ContentKey, string Label, string Path, long OffsetSamples,
    long DurationSamples, double GainDb, int RotationDegrees)
{
    /// <summary>Convert project seconds to this file's seconds, keeping effect seeks inside the recording.</summary>
    public double LocalTime(double sourceTime, double rate) => Math.Clamp(sourceTime - OffsetSamples / rate, 0, Math.Max(0, (DurationSamples - 1) / rate));
}

/// <summary>A companion picture and its half-open interval on the edited timeline.</summary>
/// <param name="Entry">The original placement on the primary source clock.</param>
/// <param name="Path">The verified local companion file.</param>
/// <param name="EditedStart">The inclusive start on the edited timeline.</param>
/// <param name="EditedEnd">The exclusive end on the edited timeline.</param>
public sealed record FootageRenderLayer(ProjectFootage Entry, string Path, double EditedStart, double EditedEnd)
{
    /// <summary>Companion seconds for this frame at normal speed: a screenshot holds, video plays at 1×.</summary>
    public double SourceTime(double editedTime) => SourceTime(editedTime, new(1));

    /// <summary>Companion seconds for this frame when the primary picture has speed changes.</summary>
    public double SourceTime(double editedTime, ClipSpeedTiming speed) => Entry.Kind == "screenshot" ? Entry.Footage.Start :
        Entry.Footage.Start + (speed.Rendered(editedTime) - speed.Rendered(EditedStart));
}
/// <summary>Output encoding configuration; architecture §4.1 and §6.4.</summary>
public sealed record OutputSpec(PixelSize Size, double FrameRate, long VideoBitrate, int AudioSampleRate = 48_000,
    int AudioChannels = 2, long AudioBitrate = 160_000, string VideoCodec = "h264")
{
    /// <summary>Preserve the whole source when Source output rounding differs by at most one pixel.</summary>
    public bool PreserveSource { get; init; }
}
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
    ExportQuality Quality, string OutputPath, string? SrtPath)
{
    /// <summary>Social loudness by default for every export (ADR-R47); Off writes the mix as composed.</summary>
    public ExportLoudness Loudness { get; init; } = ExportLoudness.Social;
}
/// <summary>Export progress with explicit phases; architecture §6.4.</summary>
public sealed record ExportProgress(string Phase, double? Fraction, long FramesEncoded, long? TotalFrames);
/// <summary>Successful final output, never a partial path; architecture §9.3.</summary>
public sealed record ExportResult(string Output, string? Srt, double DurationSeconds, int Width, int Height, double Fps,
    long Frames, int AudioSampleRate, long AudioSamples, string VideoCodec, string Encoder, double ElapsedSeconds)
{
    /// <summary>Rung 5 used the OS software MFT; show the acceleration notice once per export.</summary>
    public bool SoftwareEncoding { get; init; }
    /// <summary>The social loudness the export applied (ADR-R47); null with loudness off or without an audio track.</summary>
    public SocialLoudnessReport? Loudness { get; init; }
    /// <summary>The cover JPEG written beside the video (ADR-R48), <c>&lt;name&gt;-cover.jpg</c>; null without a cover.</summary>
    public string? Cover { get; init; }
    /// <summary>The cover is also the MP4's <c>covr</c> art.</summary>
    public bool CoverEmbedded { get; init; }
}
/// <summary>Frame hand-off; caller owns its lifetime. Preview uses a bounded channel of six; architecture §6.3.</summary>
public sealed record PreviewFrame(PixelBuffer Buffer, double EditedPts, double SourcePts, long Generation);
/// <summary>Preview audio-clock position; architecture §6.3.</summary>
public sealed record PreviewPosition(double EditedTime, double SourceTime, bool IsPlaying);
/// <summary>Encoder ladder probe result; architecture §6.6. There is no GPL fallback.</summary>
public sealed record EncoderInfo(string Name, bool Available, string? Reason);
/// <summary>Adapter/driver/build identity for encoder cache invalidation; architecture §6.6.</summary>
public sealed record EncoderCacheKey(string AdapterLuid, string DriverVersion, string FfmpegVersion);
/// <summary>What a clip render adds to the edit (design §6.9, ai.md §18.5, doc/spec/music.md §4): the clip's controls (null at the
/// defaults or for the full video), the scope's effects (null without any) and the scope's background music (null without).</summary>
public sealed record ClipRenderInput(ProjectClipControls? Controls, ClipEffectsRenderInput? Effects)
{
    /// <summary>Source-anchored face centres for story parts; absent parts use the clip's own controls.</summary>
    public IReadOnlyList<(TimeRange Source, ReframeSettings Reframe)> PartReframes { get; init; } = [];

    /// <summary>The story part's face framing at this source time.</summary>
    public ReframeSettings? PartReframeAt(double sourceTime)
    {
        foreach (var (source, reframe) in PartReframes)
            if (source.Start <= sourceTime && sourceTime < source.End)
                return reframe;
        return null;
    }
    /// <summary>The track mixed under the voice for this scope.</summary>
    public MusicRenderInput? Music { get; init; }
    /// <summary>The clip's motion cues (punch-in zooms), applied after censors and before overlays; empty for the full video.</summary>
    public IReadOnlyList<ContextDemo.MotionCue> Motion { get; init; } = [];
    /// <summary>Windows "Animation effects" off: a preview shows no motion (export always renders it), as the Mac's Reduce Motion.</summary>
    public bool ReduceMotionInPreview { get; init; }

    /// <summary>The input for a render of <paramref name="clipId"/> (null: the full video), or null when nothing changes it.</summary>
    public static ClipRenderInput? Resolve(Project project, string? clipId, string dataRoot, string sharedRoot)
    {
        var controls = ClipControlsRendering.Controls(project, clipId);
        var effects = ClipEffectsRenderInput.Resolve(project, clipId, dataRoot, sharedRoot);
        var music = MusicRenderInput.Resolve(project, clipId, dataRoot);
        var motion = ContextDemo.MotionCueRendering.For(project, clipId);
        (TimeRange Source, ReframeSettings Reframe)[] reframes = [];
        if (clipId is not null && project.Transcript is { } transcript &&
            project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId) is { Parts: { } parts } story)
            reframes = StoryClips.Times(story, transcript.Words).Zip(parts)
                .Where(pair => pair.Second.Reframe is not null).Select(pair => (pair.First, pair.Second.Reframe!)).ToArray();
        return controls is null && effects is null && music is null && motion.Count == 0 && reframes.Length == 0
            ? null : new(controls, effects) { Music = music, Motion = motion, PartReframes = reframes };
    }

    /// <summary>The same input for the edited WAV: 1× with no controls, bleeps and mutes kept, no sound effects and no music
    /// (the edited-audio path reads the voice alone).</summary>
    public ClipRenderInput? ForEditedAudio => Effects?.WithoutSounds is { } kept
        ? new(null, kept with { Effects = kept.Effects.Where(effect => effect.Kind != "speedForPart").ToArray() }) : null;
}
