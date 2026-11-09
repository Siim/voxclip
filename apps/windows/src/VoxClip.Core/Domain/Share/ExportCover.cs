using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Share;

/// <summary>A clip export's cover (ADR-R48, doc/publishing.md §7), twin of the Mac <c>ExportCover</c>: the frame the export renders at the
/// clip's <c>coverSeconds</c>, written beside the video as <c>&lt;name&gt;-cover.jpg</c> and embedded as its MP4 <c>covr</c> art.</summary>
public static class ExportCover
{
    /// <summary>A cover JPEG is at most this big.</summary>
    public const long Limit = 8 * 1024 * 1024;
    /// <summary>The Mac's lossy compression quality, 0.9, on SkiaSharp's 0–100 scale.</summary>
    public const int Quality = 90;

    /// <summary>The JPEG beside <paramref name="video"/>: its base name with <c>-cover.jpg</c>.</summary>
    public static string PathFor(string video)
    {
        ArgumentException.ThrowIfNullOrEmpty(video);
        return Path.Combine(Path.GetDirectoryName(video) ?? "", Path.GetFileNameWithoutExtension(video) + "-cover.jpg");
    }

    /// <summary>Seconds into the render of the clip's cover: its source second at its place in the render, its speed applied, kept inside
    /// the video (at most one frame before its end). Null when the render has no cover (the full video, or a clip without one).</summary>
    public static double? Seconds(ComposeSnapshot snapshot, double fps)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (snapshot.Clip?.Controls?.CoverSeconds is not { } source || !double.IsFinite(source)) return null;
        var rendered = snapshot.Speed.Rendered(snapshot.Timeline.MapTime(source));
        var last = Math.Max(0, snapshot.RenderedDuration - 1 / Math.Max(1, fps));
        return Math.Min(Math.Max(0, double.IsFinite(rendered) ? rendered : 0), last);
    }

    /// <summary>The export frame that shows the cover, among <paramref name="frames"/> at <paramref name="fps"/>; null without a cover.</summary>
    public static long? Frame(ComposeSnapshot snapshot, double fps, long frames)
    {
        if (frames <= 0 || Seconds(snapshot, fps) is not { } seconds) return null;
        return Math.Clamp((long)Math.Round(seconds * fps, MidpointRounding.AwayFromZero), 0, frames - 1);
    }
}
