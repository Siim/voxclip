using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Captions;

/// <summary>The bands of a frame that feeds cover with their own buttons and text (design.md §5.1): 9:16 has bands over the top
/// 12% and the bottom 22%, 1:1 over the bottom 12% and 16:9 over the bottom 10%. The export check (ADR-R49) warns when a caption
/// card or the title reaches into one. Twin of the Mac <c>CaptionSafeZones</c>.</summary>
public static class CaptionSafeZones
{
    /// <summary>The frame edge a band hangs from.</summary>
    public enum Edge
    {
        /// <summary>The frame's top edge.</summary>
        Top,
        /// <summary>The frame's bottom edge.</summary>
        Bottom,
    }

    /// <summary>A band: its edge and its depth, as a fraction of the frame's height from that edge.</summary>
    public sealed record Band(Edge Edge, double Fraction);

    /// <summary>9:16's right-hand column where feeds stack their buttons: a guide only; the check leaves it out, as captions sit
    /// centred across the frame.</summary>
    public const double PortraitSideFraction = 0.12;

    /// <summary>The wire name: "top" or "bottom".</summary>
    public static string Name(Edge edge) => edge == Edge.Top ? "top" : "bottom";

    /// <summary>The bands of a frame of the aspect class the caption resolver names: "portrait", "square" or "landscape".</summary>
    public static IReadOnlyList<Band> Bands(string aspectClass) => aspectClass switch
    {
        "portrait" => [new(Edge.Top, 0.12), new(Edge.Bottom, 0.22)],
        "square" => [new(Edge.Bottom, 0.12)],
        "landscape" => [new(Edge.Bottom, 0.10)],
        _ => [],
    };

    /// <summary>The bands of a <paramref name="frame"/>, by the aspect class the caption resolver computes.</summary>
    public static IReadOnlyList<Band> Bands(PixelSize frame) => Bands(CaptionStyleResolver.Aspect(frame));

    /// <summary>How far <paramref name="rect"/> (top-left origin, in fractions of the frame) reaches into <paramref name="band"/>, as
    /// a fraction of the frame's height; 0 when it is clear of it.</summary>
    public static double Overlap(RectD rect, Band band)
    {
        if (rect.Width <= 0 || rect.Height <= 0) return 0;
        if (band.Edge == Edge.Top) return Math.Max(0, Math.Min(band.Fraction, rect.Y + rect.Height) - Math.Max(0, rect.Y));
        var start = 1 - band.Fraction;
        return Math.Max(0, Math.Min(1, rect.Y + rect.Height) - Math.Max(start, rect.Y));
    }
}
