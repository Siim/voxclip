using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>Which of YuNet's boxes is the speaker's face on Windows (ADR-R48 Windows, W8). The face path reads the boxes in this order
/// and measures the first one the mesh confirms. Pure and per frame:
/// <list type="number">
/// <item>A box outside every screen the frame shows (<see cref="FrameScreen"/>, the text-dense rectangles and clusters of the screen
/// scan) comes before one inside a screen: a face on a slide, a call window or a TV is not the speaker.</item>
/// <item>A confident box (YuNet's score at least the calibration's <see cref="FrameFaceCalibration.SpeakerScore"/>) comes before a weak
/// one: a face in a graphic behind a title card, which Vision doesn't find at all, scores low.</item>
/// <item>Then the larger box first, as before; equal boxes keep the decoder's order (the best score first).</item>
/// </list>
/// With one box, or several confident ones outside any screen, this is the largest box, as the Mac's Vision takes its largest face.
/// <see cref="FaceCount"/> is how many faces the frame then has.</summary>
public static class SpeakerFace
{
    /// <summary>A box is inside a screen when at least this share of its area lies inside the screen's rect.</summary>
    public const double InsideScreenShare = 0.5;

    /// <summary><paramref name="faces"/> in the order the face path reads them; <paramref name="input"/> places each box in the picture
    /// and <paramref name="screens"/> are the frame's screen rects in picture space (empty when the frame had no screen scan).</summary>
    public static IReadOnlyList<YuNetFace> ReadingOrder(IReadOnlyList<YuNetFace> faces, YuNetInput input, IReadOnlyList<ClipEffectRect> screens,
        double speakerScore)
    {
        ArgumentNullException.ThrowIfNull(faces);
        ArgumentNullException.ThrowIfNull(screens);
        return [.. faces
            .Select((face, index) => (Face: face, Index: index, Inside: InsideScreen(face.PictureRect(input.ContentWidth, input.ContentHeight), screens)))
            .OrderBy(item => item.Inside ? 1 : 0)
            .ThenBy(item => item.Face.Score >= speakerScore ? 0 : 1)
            .ThenByDescending(item => item.Face.Area)
            .ThenBy(item => item.Index)
            .Select(item => item.Face)];
    }

    /// <summary>How many faces a frame has when the mesh confirmed <paramref name="order"/>[<paramref name="speaker"/>] and rejected
    /// every box before it: the speaker, plus each box after it that is a confident detection. A weak box counts only once the mesh
    /// confirms it, so a face in a graphic that Vision doesn't find isn't counted either.</summary>
    public static int FaceCount(IReadOnlyList<YuNetFace> order, int speaker, double speakerScore)
    {
        ArgumentNullException.ThrowIfNull(order);
        ArgumentOutOfRangeException.ThrowIfNegative(speaker);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(speaker, order.Count);
        return 1 + order.Skip(speaker + 1).Count(face => face.Score >= speakerScore);
    }

    /// <summary>Whether at least <see cref="InsideScreenShare"/> of <paramref name="face"/>'s area lies inside one of
    /// <paramref name="screens"/>.</summary>
    public static bool InsideScreen(ClipEffectRect face, IReadOnlyList<ClipEffectRect> screens)
    {
        ArgumentNullException.ThrowIfNull(screens);
        var area = FrameRect.Area(face);
        if (!(area > 0)) return false;
        foreach (var screen in screens)
        {
            var width = Math.Min(face.X + face.Width, screen.X + screen.Width) - Math.Max(face.X, screen.X);
            var height = Math.Min(face.Y + face.Height, screen.Y + screen.Height) - Math.Max(face.Y, screen.Y);
            if (width > 0 && height > 0 && width * height >= InsideScreenShare * area) return true;
        }
        return false;
    }
}
