using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Frames;

/// <summary>Where text is in a frame, one box per text line, in picture space (normalized, top-left origin), the Windows
/// stand-in for Vision's fast text observations (ADR-R48 Windows, W4). Positions only: the recognised strings never leave the
/// implementation. The App reads <c>Windows.Media.Ocr</c>; tests and the analyzer stub it.</summary>
public interface IFrameTextLines
{
    /// <summary>The text lines' boxes in <paramref name="frame"/>, premultiplied BGRA as <c>CurrentFrames</c> decodes it, upright.
    /// Empty when no text is found or no OCR language is installed.</summary>
    Task<IReadOnlyList<ClipEffectRect>> LinesAsync(PixelBuffer frame, CancellationToken ct);
}

/// <summary>One OCR word's box in frame pixels, top-left origin.</summary>
public readonly record struct OcrWordBox(double X, double Y, double Width, double Height);

/// <summary>OCR words to line boxes, shared by Ask Claude's eyes and the frame analyzer on Windows. A line's box is the min and
/// max over its words, so the 3-box and 8-box screen rules count lines, as they count Vision's fast observations.</summary>
public static class FrameTextLines
{
    /// <summary>The box around a line's <paramref name="words"/>, normalized to a frame of <paramref name="frameWidth"/> ×
    /// <paramref name="frameHeight"/> pixels and clamped inside it (<see cref="AskClaudeValidator.Clamped"/>). Null for a line
    /// without words or a frame without pixels.</summary>
    public static ClipEffectRect? LineBox(IReadOnlyList<OcrWordBox> words, int frameWidth, int frameHeight)
    {
        ArgumentNullException.ThrowIfNull(words);
        if (words.Count == 0 || frameWidth <= 0 || frameHeight <= 0) return null;
        var left = words.Min(word => word.X);
        var top = words.Min(word => word.Y);
        var right = words.Max(word => word.X + word.Width);
        var bottom = words.Max(word => word.Y + word.Height);
        return AskClaudeValidator.Clamped(new(left / frameWidth, top / frameHeight, (right - left) / frameWidth, (bottom - top) / frameHeight));
    }
}
