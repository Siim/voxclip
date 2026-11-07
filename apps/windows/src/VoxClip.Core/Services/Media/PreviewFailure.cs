namespace VoxClip.Core.Services.Media;

/// <summary>Why the preview's frame compositor could not draw a frame: a fixed, app-authored tag for the log and the stage message,
/// never user text or a path (design.md §5.4.4 g; Mac <c>PreviewFailureReason</c>).</summary>
public enum PreviewFailureReason
{
    /// <summary><c>caption-layout</c>: the caption layout's band could not be drawn.</summary>
    CaptionLayout,
    /// <summary><c>caption-raster</c>: a legacy caption raster could not be made or drawn (the Mac's legacy path; Windows has none).</summary>
    CaptionRaster,
    /// <summary><c>disclosure</c>: the required AI voice disclosure could not be drawn.</summary>
    Disclosure,
    /// <summary><c>source-frame</c>: the source video frame was missing.</summary>
    SourceFrame,
    /// <summary><c>lipsync-frame</c>: a lip-sync take's frame was missing (Windows renders no lip sync yet).</summary>
    LipsyncFrame,
    /// <summary><c>demo-frame</c>: a context demo's frame was missing.</summary>
    DemoFrame,
    /// <summary><c>resources</c>: the bundled caption resources were missing.</summary>
    Resources,
    /// <summary><c>frame-buffer</c>: no output frame could be allocated.</summary>
    FrameBuffer,
    /// <summary><c>title</c>: a title or lower third could not be drawn.</summary>
    Title
}

/// <summary>The tags, the keep-the-picture rule and the reason a failed preview frame's exception carries.</summary>
public static class PreviewFailureReasons
{
    private const string DataKey = "voxclip.preview.failure";

    /// <summary>Every reason, in the Mac's <c>allCases</c> order.</summary>
    public static IReadOnlyList<PreviewFailureReason> All { get; } =
    [
        PreviewFailureReason.CaptionLayout, PreviewFailureReason.CaptionRaster, PreviewFailureReason.Disclosure, PreviewFailureReason.SourceFrame,
        PreviewFailureReason.LipsyncFrame, PreviewFailureReason.DemoFrame, PreviewFailureReason.Resources, PreviewFailureReason.FrameBuffer,
        PreviewFailureReason.Title
    ];

    /// <summary>The fixed tag the log and the stage use.</summary>
    public static string Tag(this PreviewFailureReason reason) => reason switch
    {
        PreviewFailureReason.CaptionLayout => "caption-layout",
        PreviewFailureReason.CaptionRaster => "caption-raster",
        PreviewFailureReason.Disclosure => "disclosure",
        PreviewFailureReason.SourceFrame => "source-frame",
        PreviewFailureReason.LipsyncFrame => "lipsync-frame",
        PreviewFailureReason.DemoFrame => "demo-frame",
        PreviewFailureReason.Resources => "resources",
        PreviewFailureReason.FrameBuffer => "frame-buffer",
        PreviewFailureReason.Title => "title",
        _ => throw new ArgumentOutOfRangeException(nameof(reason))
    };

    /// <summary>Captions and titles: preview still shows the picture without them (design.md §5.4.4 g).</summary>
    public static bool KeepsPicture(this PreviewFailureReason reason)
        => reason is PreviewFailureReason.CaptionLayout or PreviewFailureReason.CaptionRaster or PreviewFailureReason.Resources or PreviewFailureReason.Title;

    /// <summary>The reason a failed preview frame's exception was marked with, or null for any other failure.</summary>
    public static PreviewFailureReason? Of(Exception? exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
            if (current.Data[DataKey] is PreviewFailureReason reason) return reason;
        return null;
    }

    /// <summary>Marks the exception that stopped a preview frame with its reason; exports never mark theirs.</summary>
    public static void Mark(Exception exception, PreviewFailureReason reason)
    {
        ArgumentNullException.ThrowIfNull(exception);
        try { exception.Data[DataKey] = reason; }
        catch (ArgumentException) { }
        catch (NotSupportedException) { }
    }
}
