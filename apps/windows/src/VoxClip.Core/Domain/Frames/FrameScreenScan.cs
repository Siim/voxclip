using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>The text and screens one frame shows: its <see cref="FrameObservation.TextRects"/> and
/// <see cref="FrameObservation.Screens"/>. Rects only; no string.</summary>
public sealed record FrameScreenFindings(IReadOnlyList<ClipEffectRect> TextRects, IReadOnlyList<FrameScreen> Screens)
{
    /// <summary>Nothing looked for: an opening-scan frame.</summary>
    public static FrameScreenFindings None { get; } = new([], []);

    /// <summary><paramref name="observation"/> with these text rects and screens (its faces are the face pass's).</summary>
    public FrameObservation ApplyTo(FrameObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        return observation with { TextRects = TextRects, Screens = Screens };
    }
}

/// <summary>Text and screens in a frame on Windows, as the Mac's <c>AppleFrameVision.observe</c> makes them: OCR line boxes and the
/// <see cref="QuadFinder"/>'s quads through <see cref="FrameScreens.Detect"/> (ADR-R48 Windows, W4). Faces are another pass's.
/// One instance per decoding lane, like its quad finder.</summary>
public sealed class FrameScreenScan(IFrameTextLines text, QuadFinder quads)
{
    /// <summary>The findings of one frame from its line boxes and quads: the quads' bounding boxes are the rectangles, in the
    /// finder's order (the most confident first), as the Mac passes Vision's.</summary>
    public static FrameScreenFindings Detect(IReadOnlyList<ClipEffectRect> lines, IReadOnlyList<FrameQuad> found)
    {
        ArgumentNullException.ThrowIfNull(lines);
        ArgumentNullException.ThrowIfNull(found);
        var rectangles = found.Select(quad => quad.BoundingBox).ToArray();
        return new(lines.ToArray(), FrameScreens.Detect(rectangles, lines));
    }

    /// <summary>The text and screens in <paramref name="frame"/> (premultiplied BGRA, upright). An opening-scan frame
    /// (<paramref name="openingScan"/>) skips both and answers <see cref="FrameScreenFindings.None"/>: the opening scan only
    /// feeds the opening frame, which reads faces, and blur spans come from sentence frames (ADR-R48 Windows, the speed
    /// lever), so no decision changes.</summary>
    public async Task<FrameScreenFindings> ScanAsync(PixelBuffer frame, bool openingScan, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(frame);
        if (openingScan) return FrameScreenFindings.None;
        var lines = await text.LinesAsync(frame, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        // A screen needs text boxes inside it (FrameScreens.MinimumBoxes): without a line there is none, so the quads aren't looked for.
        return lines.Count == 0 ? FrameScreenFindings.None : Detect(lines, quads.Find(frame));
    }
}
