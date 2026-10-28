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

    /// <summary>The right column's default width, clamp(388 − (1440 − W) × 0.25, min, max) for window width W:
    /// 388 at 1440 and 348 at 1280.</summary>
    public static double RightColumnWidth(double windowWidth, double min, double max) => Math.Clamp(388 - (1440 - windowWidth) * 0.25, min, max);

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

    /// <summary>The stage in a column of this inner width: 16:9 and landscape originals fill it; 9:16, 1:1 and portrait or
    /// square originals are centred, at most 320 high and never wider than the column.</summary>
    public static (double Width, double Height) Stage(double inner, ExportAspect aspect, PixelSize source)
    {
        var ratio = aspect switch
        {
            ExportAspect.Portrait => 16.0 / 9,
            ExportAspect.Square => 1,
            ExportAspect.Landscape => 9.0 / 16,
            _ => source.Width > 0 && source.Height > 0 ? (double)source.Height / source.Width : 9.0 / 16,
        };
        var width = Math.Max(0, ratio < 1 ? inner : Math.Min(inner, 320 / ratio));
        return (width, width * ratio);
    }

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
