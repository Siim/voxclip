using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>What the on-device frame analyzer saw in one source frame (ADR-R48, ai.md §19), twin of the Mac <c>FrameObservation</c>.
/// Every rect is in picture space: normalized to the frame as it plays, top-left origin. Recognised text is never stored, only
/// where text is.</summary>
/// <param name="Time">The source seconds the frame was asked for; the cache keys on it to the millisecond.</param>
public sealed record FrameObservation(double Time)
{
    /// <summary>How many faces the analyzer found.</summary>
    public int FaceCount { get; init; }
    /// <summary>The largest face, or null when there is none.</summary>
    public FrameFace? Face { get; init; }
    /// <summary>Every text box found, positions only.</summary>
    public IReadOnlyList<ClipEffectRect> TextRects { get; init; } = [];
    /// <summary>Screen-like rectangles with dense text, and dense text clusters: the basis of blur suggestions.</summary>
    public IReadOnlyList<FrameScreen> Screens { get; init; } = [];

    /// <summary>A clear look at the speaker: a face with open eyes, good capture quality and, when measured, facing the camera
    /// (<see cref="FrameFace.FacesCamera"/>, judged against the recording's <paramref name="pitchBaseline"/>). The opening frame
    /// needs it.</summary>
    public bool IsClearLook(double? pitchBaseline) =>
        Face is { } face && face.Eyes == FrameEyes.Open && (face.CaptureQuality ?? 0) >= FrameFace.GoodQuality
        && face.FacesCamera(pitchBaseline) != false;
}

/// <summary>Whether the eyes are open, from the eye aspect ratio (<see cref="EyeAspect"/>).</summary>
public enum FrameEyes
{
    /// <summary>The mean ratio is at or above <see cref="EyeAspect.ClosedBelow"/>.</summary>
    Open,
    /// <summary>The mean ratio is below it.</summary>
    Closed,
    /// <summary>Neither eye was measured.</summary>
    Unknown,
}

/// <summary>The largest face in a frame, twin of the Mac <c>FrameFace</c>. <see cref="Eyes"/> is derived from the eye aspect ratios
/// when the face is made, so every reader uses the same threshold; a decoded face keeps the stored value, as the Mac's does.</summary>
public sealed record FrameFace
{
    /// <summary>A capture quality at or above this counts as good. Apple's score is relative (it ranks frames of one person);
    /// on the user's footage a sharp, lit, frontal face scores about 0.5–0.8, a blurred or turned one under 0.35.</summary>
    public const double GoodQuality = 0.4;
    /// <summary>A face turned left or right further than this (|yaw|, radians, about 20°) does not face the camera.</summary>
    public const double YawLimit = 0.35;
    /// <summary>A face tilted up or down further than this from the recording's typical pitch (radians, about 20°) does not face
    /// the camera. The typical pitch (<see cref="PitchBaseline"/>) is where the camera sits, so camera height never counts as
    /// looking away (ADR-R48 "Face pose").</summary>
    public const double PitchLimit = 0.35;

    /// <summary>A face, its eyes derived from the two ratios.</summary>
    public FrameFace(ClipEffectRect rect, double? captureQuality = null, double? leftEyeAspect = null, double? rightEyeAspect = null,
        double? yaw = null, double? pitch = null)
    {
        Rect = rect;
        CaptureQuality = captureQuality;
        LeftEyeAspect = leftEyeAspect;
        RightEyeAspect = rightEyeAspect;
        Yaw = yaw;
        Pitch = pitch;
        Eyes = EyeAspect.State(leftEyeAspect, rightEyeAspect);
    }

    /// <summary>The face's box in picture space.</summary>
    public ClipEffectRect Rect { get; init; }
    /// <summary>The capture quality, 0–1, or null when it was not measured.</summary>
    public double? CaptureQuality { get; init; }
    /// <summary>The left eye's aspect ratio (<see cref="EyeAspect.Ratio"/>), or null without landmarks.</summary>
    public double? LeftEyeAspect { get; init; }
    /// <summary>The right eye's aspect ratio, or null without landmarks.</summary>
    public double? RightEyeAspect { get; init; }
    /// <summary>Head rotation left or right, radians, when measured.</summary>
    public double? Yaw { get; init; }
    /// <summary>Head tilt, radians, when measured; negative when the head tilts back (chin up).</summary>
    public double? Pitch { get; init; }
    /// <summary>Open, closed or unknown, from the two ratios.</summary>
    public FrameEyes Eyes { get; init; }

    /// <summary>Whether the face faces the camera: |yaw| within <see cref="YawLimit"/>, and pitch within <see cref="PitchLimit"/> of
    /// <paramref name="pitchBaseline"/>, the recording's typical pitch (0 when null). Null when neither angle was measured.</summary>
    public bool? FacesCamera(double? pitchBaseline)
    {
        var measured = false;
        if (Yaw is { } yaw && double.IsFinite(yaw))
        {
            measured = true;
            if (Math.Abs(yaw) > YawLimit) return false;
        }
        if (Pitch is { } pitch && double.IsFinite(pitch))
        {
            measured = true;
            var baseline = pitchBaseline is { } value && double.IsFinite(value) ? value : 0;
            if (Math.Abs(pitch - baseline) > PitchLimit) return false;
        }
        return measured ? true : null;
    }

    /// <summary>The recording's typical pitch: the median pitch of the faces in <paramref name="frames"/> (the whole video's
    /// sentence pass, or a clip's own frames when there is no pass). Null when no face has a pitch.</summary>
    public static double? PitchBaseline(IEnumerable<FrameObservation> frames)
    {
        var pitches = frames.Select(frame => frame.Face?.Pitch).OfType<double>().Where(double.IsFinite).ToArray();
        if (pitches.Length == 0) return null;
        Array.Sort(pitches);
        var middle = pitches.Length / 2;
        return pitches.Length % 2 == 1 ? pitches[middle] : (pitches[middle - 1] + pitches[middle]) / 2;
    }
}

/// <summary>The eye aspect ratio: the height of an eye's landmark contour over its width, in pixels (after Soukupová and Čech,
/// 2016), twin of the Mac <c>EyeAspect</c>. On the user's footage open eyes measure 0.22–0.65 and a half-closed blink
/// 0.17–0.19.</summary>
public static class EyeAspect
{
    /// <summary>An eye whose ratio is below this is closed; at or above it, open. Both eyes are averaged first. Half-closed counts
    /// as closed.</summary>
    public const double ClosedBelow = 0.20;

    /// <summary>The ratio of an eye contour in pixel coordinates, or null for fewer than three points or a flat contour.</summary>
    public static double? Ratio(IReadOnlyList<(double X, double Y)> points)
    {
        if (points.Count < 3 || points.Any(point => !double.IsFinite(point.X) || !double.IsFinite(point.Y))) return null;
        var width = points.Max(point => point.X) - points.Min(point => point.X);
        var height = points.Max(point => point.Y) - points.Min(point => point.Y);
        return width > 0 ? height / width : null;
    }

    /// <summary>Open or closed from the two eyes' ratios; unknown when neither was measured.</summary>
    public static FrameEyes State(double? left, double? right)
    {
        var count = 0;
        var total = 0.0;
        foreach (var value in new[] { left, right })
        {
            if (value is not { } ratio || !double.IsFinite(ratio)) continue;
            total += ratio;
            count++;
        }
        if (count == 0) return FrameEyes.Unknown;
        return total / count < ClosedBelow ? FrameEyes.Closed : FrameEyes.Open;
    }
}

/// <summary>A screen-like region with dense text: a phone or laptop screen held to the camera, or a slide.</summary>
/// <param name="Rect">The region in picture space.</param>
/// <param name="TextBoxes">Text boxes whose centre lies inside the rect.</param>
/// <param name="TextCoverage">The text boxes' area over the rect's area, 0–1.</param>
/// <param name="Framed">True when a rectangle was found around the text; false for a dense text cluster without one.</param>
public sealed record FrameScreen(ClipEffectRect Rect, int TextBoxes, double TextCoverage, bool Framed);

/// <summary>Screens from rectangles and text boxes, twin of the Mac <c>FrameScreens</c> (pure, so tests feed fabricated
/// observations).</summary>
public static class FrameScreens
{
    /// <summary>A rectangle needs at least this many text boxes inside it...</summary>
    public const int MinimumBoxes = 3;
    /// <summary>...covering at least this share of it.</summary>
    public const double MinimumCoverage = 0.04;
    /// <summary>A rectangle smaller than this share of the frame is not a screen.</summary>
    public const double MinimumArea = 0.01;
    /// <summary>Text outside any rectangle is a screen only as a cluster of at least this many boxes.</summary>
    public const int ClusterBoxes = 8;

    /// <summary>The screens of one frame: rectangles holding dense text first, then clusters of the text no rectangle claimed.</summary>
    public static IReadOnlyList<FrameScreen> Detect(IReadOnlyList<ClipEffectRect> rectangles, IReadOnlyList<ClipEffectRect> texts)
    {
        var screens = new List<FrameScreen>();
        var claimed = new HashSet<int>();
        foreach (var rectangle in rectangles)
        {
            if (FrameRect.Area(rectangle) < MinimumArea) continue;
            var inside = Enumerable.Range(0, texts.Count).Where(index => Contains(rectangle, FrameRect.MidX(texts[index]), FrameRect.MidY(texts[index]))).ToArray();
            var covered = 0.0;
            foreach (var index in inside) covered += FrameRect.Area(texts[index]);
            var coverage = Math.Min(1, covered / FrameRect.Area(rectangle));
            if (inside.Length < MinimumBoxes || coverage < MinimumCoverage) continue;
            claimed.UnionWith(inside);
            screens.Add(new(FrameRect.Clamped(rectangle), inside.Length, coverage, true));
        }
        var unclaimed = Enumerable.Range(0, texts.Count).Where(index => !claimed.Contains(index)).Select(index => texts[index]).ToArray();
        foreach (var cluster in Clusters(unclaimed))
        {
            if (cluster.Count < ClusterBoxes) continue;
            var bounds = FrameRect.Union(cluster);
            var covered = 0.0;
            foreach (var box in cluster) covered += FrameRect.Area(box);
            screens.Add(new(FrameRect.Clamped(bounds), cluster.Count, Math.Min(1, covered / Math.Max(FrameRect.Area(bounds), 1e-9)), false));
        }
        return screens;
    }

    /// <summary>Single-link clusters of boxes that touch once each is grown by half its height on every side, in the order of
    /// their first box.</summary>
    internal static IReadOnlyList<IReadOnlyList<ClipEffectRect>> Clusters(IReadOnlyList<ClipEffectRect> boxes)
    {
        var parent = Enumerable.Range(0, boxes.Count).ToArray();
        int Root(int index)
        {
            while (parent[index] != index) index = parent[index];
            return index;
        }
        var grown = boxes.Select(box =>
        {
            var pad = box.Height / 2;
            return new ClipEffectRect(box.X - pad, box.Y - pad, box.Width + 2 * pad, box.Height + 2 * pad);
        }).ToArray();
        for (var first = 0; first < boxes.Count; first++)
            for (var second = first + 1; second < boxes.Count; second++)
                if (Overlaps(grown[first], grown[second])) parent[Root(second)] = Root(first);
        var groups = new Dictionary<int, List<ClipEffectRect>>();
        var order = new List<int>();
        for (var index = 0; index < boxes.Count; index++)
        {
            var key = Root(index);
            if (!groups.TryGetValue(key, out var group))
            {
                order.Add(key);
                groups[key] = group = [];
            }
            group.Add(boxes[index]);
        }
        return order.Select(key => (IReadOnlyList<ClipEffectRect>)groups[key]).ToArray();
    }

    private static bool Contains(ClipEffectRect rect, double x, double y) =>
        x >= rect.X && x <= rect.X + rect.Width && y >= rect.Y && y <= rect.Y + rect.Height;

    private static bool Overlaps(ClipEffectRect a, ClipEffectRect b) =>
        a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height;
}

/// <summary>The analysis of one clip, twin of the Mac <c>FrameAnalysis</c>: its sentence frames, its opening scan and how long
/// each took.</summary>
/// <param name="ContentKey">The source's content key.</param>
/// <param name="Sentences">One frame per sampled sentence, in time order (<see cref="FrameSampling.SentenceSamples"/>).</param>
/// <param name="Opening">10 fps over ±0.6 s at the clip's start (<see cref="FrameSampling.OpeningTimes"/>).</param>
/// <param name="Timings">Seconds spent, and how many frames came from the cache.</param>
public sealed record FrameAnalysis(string ContentKey, IReadOnlyList<FrameObservation> Sentences, IReadOnlyList<FrameObservation> Opening,
    FrameAnalysisTimings Timings)
{
    /// <summary>2: faces with continuous yaw and pitch (2026-11-08); a version-1 cache holds the Mac's coarse revision-2 pose and
    /// is never read.</summary>
    public const int CurrentVersion = 2;

    /// <summary>The version the analysis was made with.</summary>
    public int Version { get; init; } = CurrentVersion;

    /// <summary>The clip's own typical pitch (<see cref="FrameFace.PitchBaseline"/> over its sentence frames and opening scan), for
    /// a caller without the whole video's pass.</summary>
    public double? PitchBaseline => FrameFace.PitchBaseline(Sentences.Concat(Opening));
}

/// <summary>Seconds spent, and how many frames came from the cache.</summary>
public sealed record FrameAnalysisTimings(double SentenceSeconds = 0, double OpeningSeconds = 0, int CachedFrames = 0, int AnalyzedFrames = 0);

/// <summary>The Mac <c>ClipEffect.Rect</c> helpers the frame decisions use, on <see cref="ClipEffectRect"/>.</summary>
internal static class FrameRect
{
    internal static double MidX(ClipEffectRect rect) => rect.X + rect.Width / 2;
    internal static double MidY(ClipEffectRect rect) => rect.Y + rect.Height / 2;
    internal static double Area(ClipEffectRect rect) => Math.Max(0, rect.Width) * Math.Max(0, rect.Height);

    /// <summary>Every edge inside 0–1 and each side at least 0.01 (Mac <c>Rect.isValid</c>).</summary>
    internal static bool IsValid(ClipEffectRect rect) =>
        double.IsFinite(rect.X) && double.IsFinite(rect.Y) && double.IsFinite(rect.Width) && double.IsFinite(rect.Height)
        && rect.X >= 0 && rect.Y >= 0 && rect.Width >= 0.01 && rect.Height >= 0.01 && rect.X + rect.Width <= 1 + 1e-9 && rect.Y + rect.Height <= 1 + 1e-9;

    /// <summary>The rect moved and shrunk to lie inside the frame (Mac <c>Rect.clamped</c>).</summary>
    internal static ClipEffectRect Clamped(ClipEffectRect rect) => AskClaudeValidator.Clamped(rect);

    internal static ClipEffectRect Union(IReadOnlyList<ClipEffectRect> rects)
    {
        if (rects.Count == 0) return new(0, 0, 0, 0);
        var left = rects.Min(rect => rect.X);
        var top = rects.Min(rect => rect.Y);
        var right = rects.Max(rect => rect.X + rect.Width);
        var bottom = rects.Max(rect => rect.Y + rect.Height);
        return new(left, top, right - left, bottom - top);
    }

    internal static double IntersectionOverUnion(ClipEffectRect a, ClipEffectRect b)
    {
        double left = Math.Max(a.X, b.X), right = Math.Min(a.X + a.Width, b.X + b.Width);
        double top = Math.Max(a.Y, b.Y), bottom = Math.Min(a.Y + a.Height, b.Y + b.Height);
        if (!(right > left && bottom > top)) return 0;
        var overlap = (right - left) * (bottom - top);
        var total = Area(a) + Area(b) - overlap;
        return total > 0 ? overlap / total : 0;
    }
}
