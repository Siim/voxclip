using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Autopilot;

/// <summary>What one frame shows: face boxes and text lines, in picture space (normalized to the upright frame, top-left origin).</summary>
public sealed record AskClaudeFrameFindings(IReadOnlyList<ClipEffectRect> Faces, IReadOnlyList<AskClaudeTextLine> Texts)
{
    /// <summary>Nothing found.</summary>
    public static AskClaudeFrameFindings None { get; } = new([], []);
}

/// <summary>One recognised line of text and its box.</summary>
public sealed record AskClaudeTextLine(string Text, ClipEffectRect Rect);

/// <summary>Looks at one frame of the source (ai.md §18.1). Windows answers with <c>Windows.Media.FaceAnalysis.FaceDetector</c> and
/// <c>Windows.Media.Ocr.OcrEngine</c> (the App's native observer); tests use a stub. Nothing leaves the PC.</summary>
public interface IAskClaudeVision
{
    /// <summary>The faces, and the text lines when <paramref name="text"/> is set, at source second <paramref name="time"/>.</summary>
    Task<AskClaudeFrameFindings> ObserveAsync(double time, bool text, CancellationToken ct);
}

/// <summary>Ask Claude's on-screen detections and tracks from any <see cref="IAskClaudeVision"/>, the rules of the Mac
/// <c>ClipEffectVision</c>: sampled frames, faces merged by overlap and text by its words, labels D1… in order of appearance; a track
/// sampled every 0.25 s that follows the nearest face and holds through frames with none, smoothed over three samples. Windows has no
/// saliency detector, so a box set to follow "the moving subject" holds still (<see cref="Follows"/>).</summary>
public static class AskClaudeVision
{
    /// <summary>Frames sampled for detections over a selection.</summary>
    public const int DetectionFrames = 4;
    /// <summary>Seconds between track samples (Mac <c>ClipEffect.trackInterval</c>).</summary>
    public const double TrackInterval = 0.25;
    /// <summary>The most samples a track stores (the contract's limit).</summary>
    public const int MaximumTrackSamples = 2401;

    /// <summary>Whether Windows traces <paramref name="tracking"/>: only faces; "none" and "saliency" hold the stored box.</summary>
    public static bool Follows(string? tracking) => tracking == "face";

    /// <summary>Faces and text seen in <paramref name="start"/>..<paramref name="end"/>, labelled D1, D2… by first appearance then left edge.</summary>
    public static async Task<IReadOnlyList<AskClaudeDetection>> DetectAsync(IAskClaudeVision vision, double start, double end, CancellationToken ct, int frames = DetectionFrames)
    {
        if (!(end > start) || frames <= 0) return [];
        var step = (end - start) / frames;
        var faces = new List<(ClipEffectRect Rect, double First, double Last)>();
        var texts = new Dictionary<string, (ClipEffectRect Rect, double First, double Last)>(StringComparer.Ordinal);
        var order = new List<string>();
        for (var frame = 0; frame < frames; frame++)
        {
            ct.ThrowIfCancellationRequested();
            var time = start + step * (frame + 0.5);
            var found = await vision.ObserveAsync(time, true, ct).ConfigureAwait(false);
            foreach (var face in found.Faces)
            {
                var best = -1;
                for (var index = 0; index < faces.Count; index++) if (best < 0 || Iou(faces[index].Rect, face) > Iou(faces[best].Rect, face)) best = index;
                if (best >= 0 && Iou(faces[best].Rect, face) > 0.25) faces[best] = faces[best] with { Last = time };
                else faces.Add((face, time, time));
            }
            foreach (var line in found.Texts)
            {
                var words = line.Text.Trim();
                if (words.Length == 0) continue;
                if (texts.TryGetValue(words, out var seen)) texts[words] = seen with { Last = time };
                else { order.Add(words); texts[words] = (line.Rect, time, time); }
            }
        }
        var half = step / 2;
        var detections = faces.Select(face => new AskClaudeDetection("", AskClaudeDetectionKind.Face, Math.Max(start, face.First - half), Math.Min(end, face.Last + half), face.Rect))
            .Concat(order.Select(words => new AskClaudeDetection("", AskClaudeDetectionKind.Text, Math.Max(start, texts[words].First - half), Math.Min(end, texts[words].Last + half), texts[words].Rect, words)))
            .OrderBy(detection => detection.Start).ThenBy(detection => detection.Rect.X).ToArray();
        return detections.Select((detection, index) => detection with { Label = "D" + AskClaudePrompt.Int(index + 1) }).ToArray();
    }

    /// <summary>The smoothed track for a face-following box from <paramref name="first"/>: every sample picks the face (grown by a quarter)
    /// nearest the previous rect, a frame with none holds it. Empty for any other tracking.</summary>
    public static async Task<IReadOnlyList<ClipEffectTrackSample>> TrackAsync(IAskClaudeVision vision, string? tracking, double start, double end, ClipEffectRect first, CancellationToken ct)
    {
        if (!Follows(tracking)) return [];
        var previous = first;
        var raw = new List<ClipEffectTrackSample>();
        foreach (var time in TrackTimes(start, end))
        {
            ct.ThrowIfCancellationRequested();
            var found = await vision.ObserveAsync(time, false, ct).ConfigureAwait(false);
            var candidates = found.Faces.Select(face => Grown(face, 0.25)).ToArray();
            if (candidates.Length > 0) previous = AskClaudeValidator.Clamped(candidates.MinBy(candidate => Distance(candidate, previous)));
            raw.Add(new(time, previous));
        }
        return Smoothed(raw);
    }

    /// <summary>The sample times over <paramref name="start"/>..<paramref name="end"/>: every <see cref="TrackInterval"/> from the start, and the end.</summary>
    public static IReadOnlyList<double> TrackTimes(double start, double end)
    {
        if (!double.IsFinite(start) || !double.IsFinite(end) || end <= start) return [];
        var count = (int)Math.Floor((end - start) / TrackInterval);
        var times = Enumerable.Range(0, Math.Min(count, MaximumTrackSamples - 2) + 1).Select(index => start + index * TrackInterval).ToList();
        if (end - times[^1] > 1e-6) times.Add(end);
        return times;
    }

    /// <summary>A centred three-sample average, each rect kept inside the frame.</summary>
    public static IReadOnlyList<ClipEffectTrackSample> Smoothed(IReadOnlyList<ClipEffectTrackSample> samples)
    {
        if (samples.Count <= 2) return samples.Select(sample => sample with { Rect = AskClaudeValidator.Clamped(sample.Rect) }).ToArray();
        return samples.Select((sample, index) =>
        {
            if (index == 0 || index == samples.Count - 1) return sample with { Rect = AskClaudeValidator.Clamped(sample.Rect) };
            var (a, b, c) = (samples[index - 1].Rect, sample.Rect, samples[index + 1].Rect);
            return sample with { Rect = AskClaudeValidator.Clamped(new((a.X + b.X + c.X) / 3, (a.Y + b.Y + c.Y) / 3, (a.Width + b.Width + c.Width) / 3, (a.Height + b.Height + c.Height) / 3)) };
        }).ToArray();
    }

    /// <summary>A box grown about its centre by <paramref name="fraction"/>, kept inside the frame.</summary>
    public static ClipEffectRect Grown(ClipEffectRect rect, double fraction)
    {
        var width = rect.Width * (1 + fraction);
        var height = rect.Height * (1 + fraction);
        return AskClaudeValidator.Clamped(new(rect.X + rect.Width / 2 - width / 2, rect.Y + rect.Height / 2 - height / 2, width, height));
    }

    private static double Distance(ClipEffectRect a, ClipEffectRect b) =>
        Math.Sqrt(Math.Pow(a.X + a.Width / 2 - (b.X + b.Width / 2), 2) + Math.Pow(a.Y + a.Height / 2 - (b.Y + b.Height / 2), 2));

    /// <summary>Intersection over union.</summary>
    public static double Iou(ClipEffectRect a, ClipEffectRect b)
    {
        double left = Math.Max(a.X, b.X), right = Math.Min(a.X + a.Width, b.X + b.Width);
        double top = Math.Max(a.Y, b.Y), bottom = Math.Min(a.Y + a.Height, b.Y + b.Height);
        if (right <= left || bottom <= top) return 0;
        var overlap = (right - left) * (bottom - top);
        return overlap / (a.Width * a.Height + b.Width * b.Height - overlap);
    }
}
