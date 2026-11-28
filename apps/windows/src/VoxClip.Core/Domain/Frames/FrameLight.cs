using VoxClip.Core.Domain.Clips;

namespace VoxClip.Core.Domain.Frames;

/// <summary>The light of one analysed frame (looks spec §9.3), twin of the Mac <c>FrameLight</c>: measured on the device from a small
/// picture of it (<see cref="ClipFrameSample"/>) and kept with its <see cref="FrameObservation"/> in the analysis cache. Only numbers:
/// the planner reads them as one line of notes from the shared thresholds (<see cref="ClipLightMeasure"/>), such as "light: face a
/// little dark · warm-yellow cast". No skin colour is measured or sent.</summary>
/// <param name="MedianLuma">The median luma.</param>
/// <param name="P95Luma">The nearest-rank 95th percentile of luma.</param>
/// <param name="MeanChroma">The mean chroma (max − min).</param>
public sealed record FrameLight(double MedianLuma, double P95Luma, double MeanChroma)
{
    /// <summary>The face's mean luma, or null without a face.</summary>
    public double? FaceMeanLuma { get; init; }
    /// <summary>The face's median luma, or null without a face.</summary>
    public double? FaceMedianLuma { get; init; }
    /// <summary>The share of face pixels with a channel at or above <see cref="ClipLightMeasure.ClippedChannel"/>, or null without a face.</summary>
    public double? FaceClippedShare { get; init; }
    /// <summary>The neutral pixels' mean red, green and blue (Auto's neutral mask), or null without any.</summary>
    public IReadOnlyList<double>? NeutralMeans { get; init; }

    /// <summary>The light of <paramref name="frame"/>, which holds at least one pixel; its face box is the frame's face.</summary>
    public static FrameLight Measure(ClipFrameSample frame, ClipColorMeasure measure)
    {
        ArgumentNullException.ThrowIfNull(frame);
        ArgumentNullException.ThrowIfNull(measure);
        var pixels = frame.Pixels();
        var face = frame.FacePixels();
        var lumas = pixels.Select(pixel => ClipGradeRecipe.Luma(pixel)).ToArray();
        var faceLumas = face.Select(pixel => ClipGradeRecipe.Luma(pixel)).ToArray();
        var ordered = lumas.Order().ToArray();
        return new(ClipColorMeasure.Median(lumas), ordered[Math.Max(0, (int)Math.Ceiling(0.95 * ordered.Length) - 1)],
            ClipColorMeasure.Sum(pixels.Select(pixel => ClipColorMeasure.Chroma(pixel))) / pixels.Length)
        {
            FaceMeanLuma = face.Length == 0 ? null : ClipColorMeasure.Sum(faceLumas) / face.Length,
            FaceMedianLuma = face.Length == 0 ? null : ClipColorMeasure.Median(faceLumas),
            FaceClippedShare = face.Length == 0 ? null
                : (double)face.Count(pixel => Math.Max(Math.Max(pixel[0], pixel[1]), pixel[2]) >= measure.Light.ClippedChannel) / face.Length,
            NeutralMeans = ClipColorMeasure.NeutralMeans(pixels, measure.Auto),
        };
    }

    /// <summary>The notes <paramref name="light"/>'s thresholds give, in the line's order: a dim face, clipped face highlights, a warm
    /// or cool cast, a green or magenta cast, then low or high colour.</summary>
    public IReadOnlyList<ClipLightNote> Notes(ClipLightMeasure light)
    {
        ArgumentNullException.ThrowIfNull(light);
        var notes = new List<ClipLightNote>();
        if (FaceMedianLuma < light.DimFaceLuma) notes.Add(new(ClipLightNoteKind.DimFace));
        if (FaceClippedShare is { } share && share > light.ClippedShare) notes.Add(new(ClipLightNoteKind.Clipped, ClipColorMeasure.Points(share * 100)));
        if (NeutralMeans is { Count: 3 } means)
        {
            var (r, g, b) = (means[0], means[1], means[2]);
            if (r - b > light.WarmCool) notes.Add(new(ClipLightNoteKind.WarmCast));
            else if (b - r > light.WarmCool) notes.Add(new(ClipLightNoteKind.CoolCast));
            if (g - (r + b) / 2 > light.GreenMagenta) notes.Add(new(ClipLightNoteKind.GreenCast));
            else if ((r + b) / 2 - g > light.GreenMagenta) notes.Add(new(ClipLightNoteKind.MagentaCast));
        }
        if (MeanChroma < light.LowColor) notes.Add(new(ClipLightNoteKind.LowColor));
        else if (MeanChroma > light.HighColor) notes.Add(new(ClipLightNoteKind.HighColor));
        return notes;
    }

    /// <summary>The planner's line: "light: " and the notes, or "light: even".</summary>
    public string Line(ClipLightMeasure light)
    {
        var notes = Notes(light);
        return "light: " + (notes.Count == 0 ? "even" : string.Join(" · ", notes.Select(note => note.Text)));
    }

    /// <summary>Whether the face is dim by <paramref name="light"/>'s threshold (the planner's dim-face repair, looks spec §9.5).</summary>
    public bool DimFace(ClipLightMeasure light) => light is not null && FaceMedianLuma < light.DimFaceLuma;

    /// <summary>Equal numbers, the neutral means compared value by value.</summary>
    public bool Equals(FrameLight? other) =>
        other is not null && MedianLuma.Equals(other.MedianLuma) && P95Luma.Equals(other.P95Luma) && MeanChroma.Equals(other.MeanChroma)
        && Nullable.Equals(FaceMeanLuma, other.FaceMeanLuma) && Nullable.Equals(FaceMedianLuma, other.FaceMedianLuma)
        && Nullable.Equals(FaceClippedShare, other.FaceClippedShare)
        && (NeutralMeans is null ? other.NeutralMeans is null : other.NeutralMeans is not null && NeutralMeans.SequenceEqual(other.NeutralMeans));

    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(MedianLuma, P95Luma, MeanChroma, FaceMeanLuma, FaceMedianLuma, FaceClippedShare, NeutralMeans?.Count);
}
