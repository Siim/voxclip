using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Captions;
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
public sealed record CaptionEmphasisedWord(int Word, string? PaletteColor)
{
    internal SolidPaint? PalettePaint { get; } = PaletteColor is null ? null : new(PaletteColor);
}
/// <summary>Bundled emoji placement; captions §9.2.</summary>
public sealed record CaptionEmojiLayout(int Word, string Codepoints, double X, double Y, double Size);
/// <summary>Laid-out page on edited timeline; captions §16.2.</summary>
public sealed record CaptionPage(int Index, IReadOnlyList<int> Words, double Start, double End, long FontPx64,
    double FontPx, bool Shrunk, IReadOnlyList<CaptionLine> Lines, IReadOnlyList<CaptionWordRect> WordRects,
    RectD Block, RectD Visual, IReadOnlyList<CaptionBoxLayout> Boxes, IReadOnlyList<CaptionEmphasisedWord> Emphasised,
    CaptionEmojiLayout? Emoji, PointD ClampShift)
{
    internal double LetterSpacingPx { get; init; }
}
/// <summary>One deterministic renderer input snapshot; captions §1.1. Layout is always at export resolution.</summary>
public sealed record CaptionTrack(CaptionStyle Style, PixelSize Frame, IReadOnlyList<MeasuredCaptionWord> Words,
    IReadOnlyList<CaptionPage> Pages, double Duration)
{
    /// <summary>Source words omitted by normalization or the bundled-font cascade; captions §3.1 and §4.4.</summary>
    public IReadOnlyList<(int SourceIndex, string Text, string Reason)> Dropped { get; init; } = [];
    /// <summary>The project patch was rejected and the unpatched style is shown; captions §2.4.</summary>
    public bool OverridesRejected { get; init; }
    internal long FontPx64 { get; init; }
    internal long LimitPx64 { get; init; }
    internal double LimitPx { get; init; }
    internal long GapUnits { get; init; }
    internal RectD SafeRect { get; init; }
    internal (double Left, double Right, double Top, double Bottom) SafeInsets { get; init; }
}
/// <summary>Layout inputs with project overrides and edited words; captions §2.4 and §16.2.</summary>
public sealed record CaptionLayoutRequest(CaptionStyle Style, ProjectCaptions Captions, PixelSize Frame,
    IReadOnlyList<CaptionWord> Words, string? Language, double Duration)
{
    /// <summary>Optional manual choices, indexed by source word; captions §9.1–9.2.</summary>
    public IReadOnlyList<CaptionWordHints>? WordHints { get; init; }
}
/// <summary>Manual emphasis and emoji choices for one source word; null allows the style's rule.</summary>
public sealed record CaptionWordHints(bool? Emphasis = null, string? Emoji = null);
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
    /// <summary>Resolve only the stored position that reaches this output frame.</summary>
    public static CaptionPosition? StoredPosition(ProjectCaptions captions, PixelSize frame)
        => CaptionStyleResolver.Preset(frame) is { } preset && captions.PositionByAspect.TryGetValue(preset, out var position) ? position : captions.Position;
    /// <summary>Apply casemap and punctuation rules from bundled data; captions §3.</summary>
    public static string TransformText(string text, CaptionText options) => CaptionTextRules.Normalize(text, options, "", CaptionDataLoader.Current);
    /// <summary>Build paging, line breaking and placement once at export resolution.</summary>
    public static Task<CaptionTrack> BuildAsync(CaptionLayoutRequest request, IGlyphShaper shaper, IProgress<double>? progress, CancellationToken ct)
        => CaptionLayoutBuilder.BuildAsync(request, shaper, progress, ct, shaper is ICaptionResourceShaper linguistic ? linguistic.Resources.Data : CaptionDataLoader.Current);
    /// <summary>Count/timing grouping only; this signature cannot evaluate pageFits (captions §6.1–6.2).
    /// SRT and UI consumers must use CaptionTrack.Pages for the actual width-aware rendered grouping (§14).</summary>
    public static IReadOnlyList<IReadOnlyList<int>> PageWords(IReadOnlyList<MeasuredCaptionWord> words, CaptionLayout options)
        => CaptionLayoutBuilder.Group(words, options, _ => true);
}
/// <summary>Pure easing and rounding rules; captions §1.3 and §11.</summary>
public static class CaptionMath
{
    /// <summary>Resolve a caption hex or accent colour to eight-bit RGBA channels.</summary>
    public static (byte R, byte G, byte B, byte A) ParseColor(string value, CaptionStyle style)
    {
        var color = CaptionColor.Parse(value, style);
        return (color.R, color.G, color.B, color.A);
    }
    /// <summary>Resolve a caption box radius in export pixels.</summary>
    public static double BoxRadius(bool pill, double radiusEm, double width, double height, double fontSize)
        => CaptionLayoutBuilder.Radius(pill, radiusEm, width, height, fontSize);
    /// <summary>Integer half-up, including negative values.</summary>
    public static long RoundHalfUp(double value) => checked((long)Math.Floor(value) + (value - Math.Floor(value) >= 0.5 ? 1 : 0));
    /// <summary>Evaluate the named schema easing on normalized progress.</summary>
    public static double Ease(string easing, double progress, double overshoot = 1.70158)
    {
        progress = Math.Clamp(progress, 0, 1);
        return easing switch
        {
            "linear" or "easeOutCubic" or "easeInOutCubic" or "easeOutBack" when progress == 0 || progress == 1 => progress,
            "linear" => progress,
            "easeOutCubic" => 1 - Math.Pow(1 - progress, 3),
            "easeInOutCubic" => progress < 0.5 ? 4 * Math.Pow(progress, 3) : 1 - Math.Pow(-2 * progress + 2, 3) / 2,
            "easeOutBack" => 1 + (overshoot + 1) * Math.Pow(progress - 1, 3) + overshoot * Math.Pow(progress - 1, 2),
            _ => throw new ArgumentException("Unknown caption easing.", nameof(easing))
        };
    }
    /// <summary>Choose balanced or greedy line breaks from integer advances; captions §6.2.</summary>
    public static IReadOnlyList<IReadOnlyList<int>> BreakLines(IReadOnlyList<long> widths, long gap, long limit, int maxLines, bool balanced)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxLines, 1);
        return CaptionLayoutBuilder.Break(widths, gap, units => units <= limit, balanced);
    }
    /// <summary>Clamp a visual rectangle inside the safe area; captions §7.3.</summary>
    public static PointD Place(RectD visual, RectD safeRect, CaptionStylePosition position)
        => new(CaptionLayoutBuilder.Shift(visual.X, visual.X + visual.Width, safeRect.X, safeRect.X + safeRect.Width),
            CaptionLayoutBuilder.Shift(visual.Y, visual.Y + visual.Height, safeRect.Y, safeRect.Y + safeRect.Height));
}
