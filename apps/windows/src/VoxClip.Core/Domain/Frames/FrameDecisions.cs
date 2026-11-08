using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>Where the clip opens: the first frame the viewer sees (ADR-R48, design.md "Opens on a clear look at you").</summary>
/// <param name="Shift">Seconds to move the clip's start: 0 or negative, into the silence before its first word.</param>
/// <param name="Time">The source second of the chosen frame, the clip's start plus <paramref name="Shift"/>.</param>
public sealed record OpeningFrameChoice(double Shift, double Time);

/// <summary>The opening frame, twin of the Mac <c>OpeningFrame</c>.</summary>
public static class OpeningFrame
{
    /// <summary>Frames this close to the clip's start count as its current opening frame.</summary>
    public const double StartTolerance = 0.05;
    /// <summary>Capture quality is relative and dim footage scores 0.30–0.44 throughout. So quality alone moves a start only to a
    /// frame at least this much better, and a frame with open eyes facing the camera counts from
    /// <see cref="FrameFace.GoodQuality"/> minus this.</summary>
    public const double QualityMargin = 0.15;

    /// <summary>The opening for <paramref name="clip"/> from the opening scan. The start moves only for a fault there: no face, eyes
    /// shut, a face turned away, or (eyes open, facing the camera) a capture clearly worse than one in the silence before it. A
    /// clear look or an open look of similar quality keeps the start. The shift goes to the earliest acceptable frame in the
    /// silence before the first word, no earlier than <see cref="FrameSampling.OpeningSpan"/> before it and never inside the
    /// transcript item before it (<see cref="FrameClip.LeadInFloor"/>). Null when no frame there is acceptable; the start then
    /// stays. Facing is judged against <paramref name="pitchBaseline"/>, the recording's typical pitch.</summary>
    public static OpeningFrameChoice? Choose(FrameClip clip, IEnumerable<FrameObservation> scan, double? pitchBaseline)
    {
        var start = clip.Start;
        var earliest = start - FrameSampling.OpeningSpan - 1e-9;
        var floor = Math.Max(clip.LeadInFloor, Math.Max(0, earliest));
        var ordered = scan.Where(frame => double.IsFinite(frame.Time)).OrderBy(frame => frame.Time).ToArray();
        FrameObservation? current = null;
        foreach (var frame in ordered)
        {
            if (Math.Abs(frame.Time - start) > StartTolerance) continue;
            if (current is not null && Math.Abs(current.Time - start) <= Math.Abs(frame.Time - start)) continue;
            current = frame;
        }
        if (current?.IsClearLook(pitchBaseline) == true) return new(0, start);
        // The quality a candidate needs: clearly better than an open look, or merely usable instead of a fault.
        var needed = current is not null && IsOpenLook(current, pitchBaseline)
            ? Math.Max(FrameFace.GoodQuality, Quality(current) + QualityMargin)
            : FrameFace.GoodQuality - QualityMargin;
        foreach (var frame in ordered)
        {
            var inSilence = frame.Time >= floor - 1e-9 && frame.Time <= start + 1e-9;
            if (!inSilence || !IsOpenLook(frame, pitchBaseline) || Quality(frame) < needed - 1e-9) continue;
            var time = Math.Min(start, Math.Max(floor, frame.Time));
            return new(time - start, time);
        }
        return null;
    }

    /// <summary>A face with open eyes that, when measured, faces the camera.</summary>
    internal static bool IsOpenLook(FrameObservation frame, double? pitchBaseline) =>
        frame.Face is { } face && face.Eyes == FrameEyes.Open && face.FacesCamera(pitchBaseline) != false;

    internal static double Quality(FrameObservation frame) => frame.Face?.CaptureQuality ?? 0;
}

/// <summary>The 9:16 or 1:1 crop that follows the face (design.md "9:16 follows your face"), twin of the Mac
/// <c>FaceFollowPlan</c>.</summary>
/// <param name="CropWidth">The crop window's width as a share of the source picture's width.</param>
/// <param name="CropHeight">The crop window's height as a share of the source picture's height.</param>
/// <param name="CenterX">One centre for the whole clip: the median face centre, clamped so the crop stays inside the picture.</param>
/// <param name="CenterY">The vertical twin of <paramref name="CenterX"/>.</param>
/// <param name="Path">The smoothed centre at each sample time, for a renderer that moves the crop.</param>
public sealed record FaceFollowPlan(double CropWidth, double CropHeight, double CenterX, double CenterY, IReadOnlyList<FaceFollowPoint> Path)
{
    /// <summary>True when the path never moves.</summary>
    public bool IsStatic => Path.All(point => Math.Abs(point.X - Path[0].X) < 1e-9 && Math.Abs(point.Y - Path[0].Y) < 1e-9);
}

/// <summary>The crop's centre at source second <paramref name="T"/>.</summary>
public readonly record struct FaceFollowPoint(double T, double X, double Y);

/// <summary>One sample of the face-follow crop: a source second and the face there, if any.</summary>
public readonly record struct FaceFollowSample(double Time, ClipEffectRect? Face);

/// <summary>The face-follow crop, twin of the Mac <c>FaceFollowCrop</c>.</summary>
public static class FaceFollowCrop
{
    /// <summary>The centre holds while the face stays within this share of the crop's size of it (a dead zone).</summary>
    public const double DeadZone = 0.15;
    /// <summary>The centre moves at most this share of the crop's size per second, so a move is a slow pan, never a jump.</summary>
    public const double MaximumSpeed = 0.5;
    /// <summary>Samples a median runs over, so one wrong detection never moves the crop.</summary>
    public const int MedianWindow = 5;

    /// <summary>The crop for a picture of <paramref name="sourceAspect"/> (display width over height) cut to
    /// <paramref name="targetAspect"/> (9/16 or 1). Samples without a face hold the previous centre (the next face's before the
    /// first one); without any face the crop is centred. Null for a non-positive aspect.</summary>
    public static FaceFollowPlan? Plan(IEnumerable<FaceFollowSample> samples, double sourceAspect, double targetAspect)
    {
        if (!double.IsFinite(sourceAspect) || !double.IsFinite(targetAspect) || sourceAspect <= 0 || targetAspect <= 0) return null;
        var cropWidth = Math.Min(1, targetAspect / sourceAspect);
        var cropHeight = Math.Min(1, sourceAspect / targetAspect);
        var ordered = samples.Where(sample => double.IsFinite(sample.Time)).OrderBy(sample => sample.Time).ToArray();
        var faces = ordered.Where(sample => sample.Face is not null).Select(sample => sample.Face!.Value).ToArray();
        if (faces.Length == 0)
            return new(cropWidth, cropHeight, 0.5, 0.5, ordered.Select(sample => new FaceFollowPoint(sample.Time, 0.5, 0.5)).ToArray());
        double heldX = FrameRect.MidX(faces[0]), heldY = FrameRect.MidY(faces[0]);
        var xs = new double[ordered.Length];
        var ys = new double[ordered.Length];
        for (var index = 0; index < ordered.Length; index++)
        {
            if (ordered[index].Face is { } face) { heldX = FrameRect.MidX(face); heldY = FrameRect.MidY(face); }
            xs[index] = heldX;
            ys[index] = heldY;
        }
        var centerX = Clamp(Median(xs), cropWidth);
        var centerY = Clamp(Median(ys), cropHeight);
        var targetX = RunningMedian(xs);
        var targetY = RunningMedian(ys);
        var times = ordered.Select(sample => sample.Time).ToArray();
        // The moving crop starts on the first smoothed face, not on the clip's median.
        var pathX = Follow(targetX, times, cropWidth, Clamp(targetX[0], cropWidth));
        var pathY = Follow(targetY, times, cropHeight, Clamp(targetY[0], cropHeight));
        var path = times.Select((time, index) => new FaceFollowPoint(time, pathX[index], pathY[index])).ToArray();
        return new(cropWidth, cropHeight, centerX, centerY, path);
    }

    /// <summary>The centre the crop shows over time: it holds while the target stays in the dead zone, then moves towards it no
    /// faster than <see cref="MaximumSpeed"/>, and stays inside the picture.</summary>
    internal static double[] Follow(double[] targets, double[] times, double size, double start)
    {
        if (!(size < 1 - 1e-9)) return targets.Select(_ => 0.5).ToArray();
        var current = start;
        var previousTime = times.Length > 0 ? times[0] : 0;
        var path = new double[targets.Length];
        var zone = DeadZone * size;
        for (var index = 0; index < targets.Length; index++)
        {
            var elapsed = Math.Max(0, times[index] - previousTime);
            previousTime = times[index];
            var offset = targets[index] - current;
            if (Math.Abs(offset) > zone)
            {
                var wanted = offset - (offset > 0 ? zone : -zone);
                var limit = MaximumSpeed * size * elapsed;
                current += Math.Max(-limit, Math.Min(limit, wanted));
            }
            current = Clamp(current, size);
            path[index] = current;
        }
        return path;
    }

    internal static double[] RunningMedian(double[] values)
    {
        const int half = MedianWindow / 2;
        return values.Select((_, index) =>
        {
            var low = Math.Max(0, index - half);
            var high = Math.Min(values.Length - 1, index + half);
            return Median(values[low..(high + 1)]);
        }).ToArray();
    }

    internal static double Median(IReadOnlyList<double> values)
    {
        var sorted = values.ToArray();
        if (sorted.Length == 0) return 0.5;
        Array.Sort(sorted);
        var middle = sorted.Length / 2;
        return sorted.Length % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
    }

    /// <summary>A centre that keeps a crop of <paramref name="size"/> inside 0–1.</summary>
    internal static double Clamp(double value, double size)
    {
        var half = Math.Min(0.5, size / 2);
        return Math.Min(1 - half, Math.Max(half, double.IsFinite(value) ? value : 0.5));
    }
}

/// <summary>The cover: the frame the export's poster and <c>cover.jpg</c> show (design.md "Cover frame chosen").</summary>
public sealed record CoverFrameChoice(double Time, double Score);

/// <summary>The cover frame, twin of the Mac <c>CoverFrame</c>.</summary>
public static class CoverFrame
{
    /// <summary>A neighbour this close in time with closed eyes makes a frame part of a blink.</summary>
    public const double BlinkWindow = 0.25;
    /// <summary>The weight of the capture quality; the four weights sum to 1.</summary>
    public const double QualityWeight = 0.4;
    /// <summary>The weight of how centred the face is.</summary>
    public const double CentredWeight = 0.3;
    /// <summary>The weight of how open the eyes are.</summary>
    public const double EyesWeight = 0.2;
    /// <summary>The weight of facing the camera.</summary>
    public const double FacingWeight = 0.1;

    /// <summary>The score of a frame, 0–1, or null when it cannot be a cover: no face, eyes not open, or a closed-eye neighbour
    /// within <see cref="BlinkWindow"/> (<paramref name="neighbours"/> are the other frames). Facing is judged against
    /// <paramref name="pitchBaseline"/>.</summary>
    public static double? Score(FrameObservation frame, IEnumerable<FrameObservation> neighbours, double? pitchBaseline)
    {
        if (frame.Face is not { } face || face.Eyes != FrameEyes.Open) return null;
        var blinking = neighbours.Any(other =>
            other.Time != frame.Time && Math.Abs(other.Time - frame.Time) <= BlinkWindow && other.Face?.Eyes == FrameEyes.Closed);
        if (blinking) return null;
        var quality = Math.Min(1, Math.Max(0, face.CaptureQuality ?? 0));
        var offset = double.Hypot(FrameRect.MidX(face.Rect) - 0.5, FrameRect.MidY(face.Rect) - 0.5);
        var centred = Math.Max(0, 1 - 2 * offset);
        var count = 0;
        var total = 0.0;
        foreach (var ratio in new[] { face.LeftEyeAspect, face.RightEyeAspect })
        {
            if (ratio is not { } value) continue;
            total += value;
            count++;
        }
        var mean = count == 0 ? EyeAspect.ClosedBelow : total / count;
        var openness = Math.Min(1, Math.Max(0, (mean - EyeAspect.ClosedBelow) / 0.15));
        double facing = face.FacesCamera(pitchBaseline) == false ? 0 : 1;
        var weighted = QualityWeight * quality + CentredWeight * centred;
        return weighted + EyesWeight * openness + FacingWeight * facing;
    }

    /// <summary>The best-scoring frame; the earlier one on a tie. Null when no frame can be a cover.</summary>
    public static CoverFrameChoice? Pick(IReadOnlyList<FrameObservation> frames, double? pitchBaseline)
    {
        CoverFrameChoice? best = null;
        foreach (var frame in frames.OrderBy(frame => frame.Time))
        {
            if (Score(frame, frames, pitchBaseline) is not { } value) continue;
            if (best is null || value > best.Score + 1e-12) best = new(frame.Time, value);
        }
        return best;
    }
}

/// <summary>A stretch of the clip where a screen with text is visible: a blur suggestion (design.md "Blurred the phone screen
/// at …").</summary>
/// <param name="Start">Source seconds, padded.</param>
/// <param name="End">Source seconds, padded.</param>
/// <param name="Rect">The union of the screen's rects over the span.</param>
/// <param name="Frames">Frames the screen was seen in.</param>
public sealed record FrameBlurSpan(double Start, double End, ClipEffectRect Rect, int Frames);

/// <summary>Screens merged over time, twin of the Mac <c>FrameBlurSpans</c>.</summary>
public static class FrameBlurSpans
{
    /// <summary>Screens in two frames are one screen when their rects overlap at least this much (intersection over union).</summary>
    public const double MinimumOverlap = 0.2;

    private sealed class Open(double first, ClipEffectRect rect)
    {
        public double First { get; } = first;
        public double Last { get; set; } = first;
        public ClipEffectRect LastRect { get; set; } = rect;
        public ClipEffectRect Union { get; set; } = rect;
        public int Frames { get; set; } = 1;
    }

    /// <summary>Screens merged over time: a screen seen within <paramref name="maxGap"/> seconds of a matching one extends its span,
    /// and the span grows by <paramref name="pad"/> seconds on each side. Spans are in start order.</summary>
    public static IReadOnlyList<FrameBlurSpan> Merge(IEnumerable<FrameObservation> frames, double maxGap, double pad = 0)
    {
        var spans = new List<Open>();
        foreach (var frame in frames.OrderBy(frame => frame.Time))
        {
            foreach (var screen in frame.Screens)
            {
                // The open span with the best overlap; the first of equals.
                Open? match = null;
                foreach (var span in spans)
                {
                    if (frame.Time - span.Last > maxGap + 1e-9) continue;
                    if (match is null || FrameRect.IntersectionOverUnion(match.LastRect, screen.Rect) < FrameRect.IntersectionOverUnion(span.LastRect, screen.Rect))
                        match = span;
                }
                if (match is not null && FrameRect.IntersectionOverUnion(match.LastRect, screen.Rect) >= MinimumOverlap)
                {
                    match.Last = frame.Time;
                    match.LastRect = screen.Rect;
                    match.Union = FrameRect.Union([match.Union, screen.Rect]);
                    match.Frames += 1;
                }
                else
                {
                    spans.Add(new(frame.Time, screen.Rect));
                }
            }
        }
        return spans.Select(span => new FrameBlurSpan(Math.Max(0, span.First - pad), span.Last + pad, FrameRect.Clamped(span.Union), span.Frames))
            .OrderBy(span => span.Start).ToArray();
    }
}
