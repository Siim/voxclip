using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
namespace VoxClip.Core.Domain.Captions;

/// <summary>Bundled font shaping parameters; captions §4.3. No system-font fallback.</summary>
public sealed record ShapingRequest(string FontFile, string Text, int UnitsPerEm, bool Kern = true, bool Liga = true, bool Calt = true);
/// <summary>Font-unit glyph offset; captions §4.3.</summary>
public readonly record struct GlyphOffset(long X, long Y);
/// <summary>Glyph ids, integer advances, offsets and grapheme-cluster indices; captions §4.3.</summary>
public sealed record ShapedRun(string File, string Text, int UnitsPerEm, IReadOnlyList<uint> Glyphs,
    IReadOnlyList<long> Advances, IReadOnlyList<GlyphOffset> Offsets, IReadOnlyList<int> Clusters);
/// <summary>Injected shaper implemented with HarfBuzz in Media; captions §1.1 and §4.3.</summary>
public interface IGlyphShaper
{
    /// <summary>Shape at upem scale with explicit OpenType features; captions §4.3.</summary>
    Task<ShapedRun> ShapeAsync(ShapingRequest request, CancellationToken ct);
}
/// <summary>One measured caption word; captions §16.2.</summary>
public sealed record MeasuredCaptionWord(int SourceIndex, string Id, string Raw, string Text, double Start, double End,
    long Units, int Clusters, IReadOnlyList<ShapedRun> Runs, double EmphasisPoints, bool EmphasisCandidate,
    long? EmphasisUnits, IReadOnlyList<ShapedRun>? EmphasisRuns, IReadOnlyList<string>? DroppedClusters);
/// <summary>One line in export-pixel coordinates; captions §6–7.</summary>
public sealed record CaptionLine(IReadOnlyList<int> Words, long Units, double X, double Top, double Baseline, double Width);
/// <summary>Word hit geometry; captions §7 and §16.2.</summary>
public sealed record CaptionWordRect(int Word, int Line, double X, double Y, double W, double H, double Baseline, double Cx, double Cy);
/// <summary>Laid-out rounded box; captions §7.5.</summary>
public sealed record CaptionBoxLayout(string Kind, int? Word, double X, double Y, double W, double H, double R);
/// <summary>One emphasized word with resolved palette color; captions §9.1.</summary>
public sealed record CaptionEmphasisedWord(int Word, string? PaletteColor);
/// <summary>Bundled emoji placement; captions §9.2.</summary>
public sealed record CaptionEmojiLayout(int Word, string Codepoints, double X, double Y, double Size);
/// <summary>Laid-out page on edited timeline; captions §16.2.</summary>
public sealed record CaptionPage(int Index, IReadOnlyList<int> Words, double Start, double End, long FontPx64,
    double FontPx, bool Shrunk, IReadOnlyList<CaptionLine> Lines, IReadOnlyList<CaptionWordRect> WordRects,
    RectD Block, RectD Visual, IReadOnlyList<CaptionBoxLayout> Boxes, IReadOnlyList<CaptionEmphasisedWord> Emphasised,
    CaptionEmojiLayout? Emoji, PointD ClampShift);
/// <summary>One deterministic renderer input snapshot; captions §1.1. Layout is always at export resolution.</summary>
public sealed record CaptionTrack(CaptionStyle Style, PixelSize Frame, IReadOnlyList<MeasuredCaptionWord> Words,
    IReadOnlyList<CaptionPage> Pages, double Duration);
/// <summary>Layout inputs with project overrides and edited words; captions §2.4 and §16.2.</summary>
public sealed record CaptionLayoutRequest(CaptionStyle Style, ProjectCaptions Captions, PixelSize Frame,
    IReadOnlyList<CaptionWord> Words, string? Language, double Duration);
/// <summary>Caller-owned premultiplied BGRA8 pixels, top-left origin, gamma-encoded blending; architecture §6.3.</summary>
public sealed record PixelBuffer(Memory<byte> Pixels, int Width, int Height, int Stride);
/// <summary>Per-frame state independent of previously rendered frames; captions §1.2.</summary>
public sealed record CaptionRenderRequest(CaptionTrack Track, double Time, bool ReduceMotion = false, double Scale = 1);
/// <summary>Single renderer contract for preview, export, gallery and goldens; captions §1.2.</summary>
public interface ICaptionRasterizer
{
    /// <summary>Draw glyph outlines into caller-owned pixels; the synchronous path avoids frame allocations.</summary>
    void Draw(CaptionRenderRequest request, PixelBuffer target, CancellationToken ct);
    /// <summary>Render a transparent BGRA overlay for goldens and gallery; captions §16.</summary>
    Task<PixelBuffer> RenderAsync(CaptionRenderRequest request, CancellationToken ct);
}
/// <summary>Caption-domain entry points; captions §3, §6, §7 and §11. Implement in place, not in the UI.</summary>
public static class CaptionEngine
{
    /// <summary>Apply casemap and punctuation rules from bundled data; captions §3.</summary>
    public static string TransformText(string text, CaptionText options) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions");
    /// <summary>Build paging, line breaking and placement once at export resolution.</summary>
    public static Task<CaptionTrack> BuildAsync(CaptionLayoutRequest request, IGlyphShaper shaper, IProgress<double>? progress, CancellationToken ct)
        => Task.FromException<CaptionTrack>(new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions"));
    /// <summary>Page grouping; captions §6.1.</summary>
    public static IReadOnlyList<IReadOnlyList<int>> PageWords(IReadOnlyList<MeasuredCaptionWord> words, CaptionLayout options) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions");
}
/// <summary>Pure easing and rounding rules; captions §1.3 and §11.</summary>
public static class CaptionMath
{
    /// <summary>Integer half-up, including negative values.</summary>
    public static long RoundHalfUp(double value) => checked((long)Math.Floor(value) + (value - Math.Floor(value) >= 0.5 ? 1 : 0));
    /// <summary>Evaluate the named schema easing on normalized progress.</summary>
    public static double Ease(string easing, double progress, double overshoot = 1.70158) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions");
    /// <summary>Choose balanced or greedy line breaks from integer advances; captions §6.2.</summary>
    public static IReadOnlyList<IReadOnlyList<int>> BreakLines(IReadOnlyList<long> widths, long gap, long limit, int maxLines, bool balanced) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions");
    /// <summary>Clamp a visual rectangle inside the safe area; captions §7.3.</summary>
    public static PointD Place(RectD visual, RectD safeRect, CaptionStylePosition position) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-captions");
}
