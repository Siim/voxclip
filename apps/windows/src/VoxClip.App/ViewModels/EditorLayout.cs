using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

/// <summary>The editor's layout rules (delta §3.3, §3.5, §3.7 and §5.1), kept apart from the page so they can be tested.
/// Sizes come in from the page's tokens.</summary>
public static class EditorLayout
{
    public static bool StackMeasuredRow(double availableWidth, double leadingWidth, double trailingWidth, double gap) =>
        leadingWidth > 0 && leadingWidth + trailingWidth + gap > availableWidth;

    /// <summary>The Frame row's order, 9:16 · 1:1 · 16:9 · Original; export.aspect keeps its persisted values.</summary>
    public static IReadOnlyList<ExportAspect> Frames { get; } = [ExportAspect.Portrait, ExportAspect.Square, ExportAspect.Landscape, ExportAspect.Source];

    /// <summary>The v2 right column follows 404 + (W − 1280) × 0.25 within the existing native splitter limits.</summary>
    public static double RightColumnWidth(double windowWidth, double min, double max) => Math.Clamp(404 + (windowWidth - 1280) * 0.25, min, max);

    /// <summary>The width ui.rightColumnWidth holds, kept to the column's own range (300–560 from the tokens; the schema
    /// allows 240–720), or null when the user has never moved the splitter and the column follows
    /// <see cref="RightColumnWidth"/>.</summary>
    public static double? StoredRightColumnWidth(double? stored, double min, double max) =>
        stored is { } width && double.IsFinite(width) ? Math.Clamp(width, min, max) : null;

    /// <summary>The width to store after the user moves the splitter: whole epx in the column's range.</summary>
    public static double? RightColumnWidthToStore(double width, double min, double max) =>
        double.IsFinite(width) ? Math.Clamp(Math.Round(width), min, max) : null;

    /// <summary>Whether the transcript keeps its minimum beside the splitter and a right column of this width.</summary>
    public static bool TranscriptFits(double pageWidth, double splitter, double rightColumn, double transcriptMin) =>
        pageWidth - splitter - rightColumn >= transcriptMin;

    /// <summary>The v2 viewer keeps a 16:9 envelope while the compositor letterboxes the actual export aspect inside it.</summary>
    public static (double Width, double Height) Viewer(double inner)
    {
        var width = double.IsFinite(inner) ? Math.Max(0, inner) : 0;
        return (width, width * 9 / 16);
    }

    public static double CaptionHeaderViewport(double availableForCaptions, double fixedContentHeight, double measuredHeaderHeight) =>
        Math.Clamp(availableForCaptions - fixedContentHeight, 56, Math.Max(56, measuredHeaderHeight));

    /// <summary>Why Export is unavailable for the scope, or null when it can run. The text is the button's tooltip and
    /// accessible description (delta §3.5, placeholder spec §5.4.4), and what Ctrl+E says. While transcription, clip search
    /// or an export runs it is design §14's "Finish the current task first."</summary>
    public static string? ExportBlocked(bool demo, bool videoUnavailable, bool busy, bool hasKeptWords, bool suggestionSelected) =>
        demo ? "Demo projects have no video to export."
        : videoUnavailable ? "Locate the video to export."
        : busy ? "Finish the current task first."
        : !hasKeptWords ? "Keep at least one word before exporting."
        : suggestionSelected ? "Keep this clip to export it."
        : null;
}
