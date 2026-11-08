using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Domain.Frames;

/// <summary>The frames a plan request shows the AI (ADR-R48), twin of the Mac <c>FrameSheet</c>: one small JPEG per sentence, each
/// labelled with its time, and a compact text summary of what was measured on each. A connector that takes images gets both; one
/// that cannot gets the summary only (ai.md §19.3), the same text on both platforms.</summary>
public sealed class FrameSheet
{
    /// <summary>The long edge of each frame, in pixels.</summary>
    public const int FrameEdge = 320;
    /// <summary>At most this many frames per clip.</summary>
    public const int MaximumFrames = FrameSampling.MaximumSentences;
    /// <summary>Anthropic's image token estimate: width × height / 750, rounded up. The estimate is for the send line, not billing.</summary>
    public const double PixelsPerToken = 750.0;
    /// <summary>The summary's first line. It names the Mac on both platforms, so a connector reads the same text from either
    /// (shared/fixtures/autopilot/plan-frames-cases.json pins it).</summary>
    public const string SummaryHeader = "Frames measured on this Mac (one per sentence; rects are x,y,w,h of the picture, top-left origin):";

    /// <summary>A sheet of at most <see cref="MaximumFrames"/> frames.</summary>
    public FrameSheet(IEnumerable<FrameSheetFrame> frames) => Frames = frames.Take(MaximumFrames).ToArray();

    /// <summary>The sheet's frames, in order.</summary>
    public IReadOnlyList<FrameSheetFrame> Frames { get; }

    /// <summary>The images as the request carries them.</summary>
    public IReadOnlyList<LlmImage> Images => Frames.Select(frame => frame.Image).ToArray();

    /// <summary>The summary block: a header line, then one line per frame, facing judged against <paramref name="pitchBaseline"/>.
    /// Empty for an empty sheet.</summary>
    public string Summary(double? pitchBaseline) =>
        Frames.Count == 0 ? "" : string.Join("\n", Frames.Select(frame => frame.SummaryLine(pitchBaseline)).Prepend(SummaryHeader));

    /// <summary>The JPEG bytes the images add to a request (before base64).</summary>
    public int ImageBytes => Frames.Sum(frame => frame.Image.Data.Length);

    /// <summary>The estimated input tokens of the images.</summary>
    public int EstimatedImageTokens => Frames.Sum(frame => ImageTokens(frame.Image.Width, frame.Image.Height));

    /// <summary>The estimated input tokens of the summary (2.2 UTF-8 bytes per token, the Mac's <c>AITokenPolicy</c>).</summary>
    public int EstimatedSummaryTokens(double? pitchBaseline) => SummaryTokens(Summary(pitchBaseline));

    internal static int SummaryTokens(string summary) => (int)Math.Ceiling(Encoding.UTF8.GetByteCount(summary) / 2.2);

    /// <summary>Anthropic's estimate of one image's input tokens.</summary>
    public static int ImageTokens(int width, int height) => (int)Math.Ceiling((double)Math.Max(0, width) * Math.Max(0, height) / PixelsPerToken);
}

/// <summary>One frame of the sheet, twin of the Mac <c>FrameSheetFrame</c>.</summary>
public sealed class FrameSheetFrame
{
    /// <summary>Frame <paramref name="index"/> (from 1) with its measured observation and its small JPEG.</summary>
    public FrameSheetFrame(int index, FrameObservation observation, byte[] jpeg, int width, int height)
    {
        Index = index;
        Observation = observation;
        Image = new(Label(index, observation.Time), "image/jpeg", jpeg, width, height);
    }

    /// <summary>The frame's number, from 1 ("Frame 3").</summary>
    public int Index { get; }
    /// <summary>What was measured on the frame.</summary>
    public FrameObservation Observation { get; }
    /// <summary>The small JPEG, labelled.</summary>
    public LlmImage Image { get; }

    /// <summary>"Frame 3 at 12.40 s".</summary>
    public static string Label(int index, double time) => $"Frame {index} at {Fixed(time)} s";

    /// <summary>"F3 12.40 s: face at 0.42,0.18,0.20,0.36, eyes open, quality 0.62, facing camera; screen with text at …", facing
    /// judged against <paramref name="pitchBaseline"/>.</summary>
    public string SummaryLine(double? pitchBaseline) => SummaryLine(Index, Observation, pitchBaseline);

    internal static string SummaryLine(int index, FrameObservation frame, double? pitchBaseline)
    {
        var parts = new List<string>();
        if (frame.Face is { } face)
        {
            var facePart = "face at " + RectText(face.Rect);
            if (frame.FaceCount > 1) facePart += $" (largest of {frame.FaceCount.ToString(CultureInfo.InvariantCulture)})";
            parts.Add(facePart);
            parts.Add("eyes " + FrameJson.EyesName(face.Eyes));
            if (face.CaptureQuality is { } quality) parts.Add("quality " + Fixed(quality));
            if (face.FacesCamera(pitchBaseline) is { } facing) parts.Add(facing ? "facing camera" : "turned away");
        }
        else
        {
            parts.Add("no face");
        }
        foreach (var screen in frame.Screens)
            parts.Add($"{(screen.Framed ? "screen" : "dense text")} with {screen.TextBoxes.ToString(CultureInfo.InvariantCulture)} text boxes at {RectText(screen.Rect)}");
        if (frame.Screens.Count == 0 && frame.TextRects.Count > 0) parts.Add($"{frame.TextRects.Count.ToString(CultureInfo.InvariantCulture)} text boxes");
        return $"F{index.ToString(CultureInfo.InvariantCulture)} {Fixed(frame.Time)} s: " + string.Join(", ", parts);
    }

    /// <summary>Two decimals as the Mac's <c>String(format: "%.2f")</c> writes them: the exact binary value rounded half to even
    /// ("F2"; the custom "0.00" rounds 1.005 up, printf does not).</summary>
    internal static string Fixed(double value) => value.ToString("F2", CultureInfo.InvariantCulture);

    /// <summary>"x,y,w,h", two decimals each.</summary>
    internal static string RectText(ClipEffectRect rect) => string.Join(",", Fixed(rect.X), Fixed(rect.Y), Fixed(rect.Width), Fixed(rect.Height));
}

/// <summary>The candidates of a clip's frames, twin of the Mac <c>ClipFrameCandidates</c>: blur candidates <c>B1…</c> and cover
/// candidates <c>C1…C3</c>, which a plan request lists so the reply can pick among them by id (ai.md §19.6).</summary>
public static class ClipFrameCandidates
{
    /// <summary>Sentence frames are one per sentence, seconds apart: a screen seen again within this many seconds is the same one.</summary>
    public const double BlurMaxGap = 8.0;
    /// <summary>Each blur span reaches this far past the first and last frame that saw its screen, into the time between frames.</summary>
    public const double BlurPad = 1.0;
    /// <summary>At most this many cover candidates.</summary>
    public const int MaximumCovers = 3;

    /// <summary><c>B1…</c> in start order: the screens merged over the frames, each span padded and kept inside the clip.</summary>
    public static IReadOnlyList<ClipAutopilotFrames.BlurCandidate> Blur(IEnumerable<FrameObservation> frames, double clipStart, double clipEnd)
    {
        var result = new List<ClipAutopilotFrames.BlurCandidate>();
        foreach (var span in FrameBlurSpans.Merge(frames, BlurMaxGap, BlurPad))
        {
            var start = Math.Max(span.Start, clipStart);
            var end = Math.Min(span.End, clipEnd);
            if (!(end > start) || !FrameRect.IsValid(span.Rect)) continue;
            result.Add(new($"B{(result.Count + 1).ToString(CultureInfo.InvariantCulture)}", start, end, span.Rect, span.Frames));
        }
        return result;
    }

    /// <summary><c>C1…C3</c>: the best frames by <see cref="CoverFrame.Score"/>, best first; the earlier frame wins a tie.</summary>
    public static IReadOnlyList<ClipAutopilotFrames.CoverCandidate> Cover(IReadOnlyList<FrameSheetFrame> frames, double? pitchBaseline)
    {
        var observations = frames.Select(frame => frame.Observation).ToArray();
        var scored = new List<(FrameSheetFrame Frame, double Score)>();
        foreach (var frame in frames)
            if (CoverFrame.Score(frame.Observation, observations, pitchBaseline) is { } score) scored.Add((frame, score));
        // Best first; within 1e-12 the earlier frame first. An insertion sort applies the Mac's comparator as written.
        var ranked = new List<(int Offset, FrameSheetFrame Frame, double Score)>();
        for (var offset = 0; offset < scored.Count; offset++)
        {
            var item = (offset, scored[offset].Frame, scored[offset].Score);
            var position = ranked.Count;
            while (position > 0 && Better(item, ranked[position - 1])) position--;
            ranked.Insert(position, item);
        }
        return ranked.Take(MaximumCovers).Select((item, rank) =>
            new ClipAutopilotFrames.CoverCandidate($"C{(rank + 1).ToString(CultureInfo.InvariantCulture)}", item.Frame.Index, item.Frame.Observation.Time, item.Score)).ToArray();

        static bool Better((int Offset, FrameSheetFrame Frame, double Score) left, (int Offset, FrameSheetFrame Frame, double Score) right) =>
            Math.Abs(left.Score - right.Score) > 1e-12 ? left.Score > right.Score : left.Offset < right.Offset;
    }
}
