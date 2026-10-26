using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Media.VoiceLab;

/// <summary>Existing caption-layout rectangle, in output pixels with a top-left origin.</summary>
public readonly record struct VoiceLabDisclosureCaptionBlock(double Start, double End, SKRect Bounds);

/// <summary>Reusable sRGB chip drawn after captions by the existing preview/export frame composer; Voice Lab §11.2.</summary>
public sealed class VoiceLabDisclosureOverlay : IDisposable
{
    private readonly bool required;
    private readonly double fadeSeconds;
    private readonly VoiceLabLabelInterval[] intervals;
    private readonly int width, height, chipWidth, chipHeight;
    private readonly byte[] pixels;
    private readonly (int X, int Y)[] origins;
    private bool disposed;

    /// <summary>Precompute one chip and one collision decision per Core disclosure interval.</summary>
    public VoiceLabDisclosureOverlay(VoiceLabDisclosurePlan plan, int width, int height, string fontPath,
        IReadOnlyList<VoiceLabDisclosureCaptionBlock> captionBlocks)
    {
        if (width <= 0 || height <= 0 || width > 16384 || height > 16384) throw new ArgumentOutOfRangeException(nameof(width));
        if (Path.GetFileName(fontPath) != "DMSans-Bold.ttf") throw new InvalidDataException("Expected bundled DM Sans Bold.");
        required = plan.Required; fadeSeconds = plan.FadeSeconds;
        intervals = plan.Intervals.Select(interval => new VoiceLabLabelInterval(interval.Start, interval.End)).ToArray();
        var position = plan.Position;
        this.width = width; this.height = height;
        using var typeface = SKTypeface.FromFile(fontPath) ?? throw new InvalidDataException("Bundled disclosure font unavailable.");
        var size = height * .024f;
        using var font = new SKFont(typeface, size);
        using var textPaint = new SKPaint { Color = SKColors.White, IsAntialias = true };
        var text = "AI MODIFIED";
        var textWidth = text.Sum(ch => font.MeasureText(ch.ToString(), textPaint)) + (text.Length - 1) * size * .06f;
        var metrics = font.Metrics;
        var horizontal = size * .6f; var vertical = size * .35f;
        chipWidth = (int)Math.Ceiling(textWidth + 2 * horizontal);
        chipHeight = (int)Math.Ceiling(metrics.Descent - metrics.Ascent + 2 * vertical);
        if (chipWidth > width || chipHeight > height) throw new ArgumentOutOfRangeException(nameof(width));
        using var bitmap = new SKBitmap(new SKImageInfo(chipWidth, chipHeight, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(bitmap))
        {
            canvas.Clear(SKColors.Transparent);
            using var background = new SKPaint { Color = new SKColor(0, 0, 0, 179), IsAntialias = true };
            canvas.DrawRoundRect(new SKRect(0, 0, chipWidth, chipHeight), size * .3f, size * .3f, background);
            var x = horizontal; var baseline = vertical - metrics.Ascent;
            foreach (var ch in text)
            {
                canvas.DrawText(ch.ToString(), x, baseline, font, textPaint);
                x += font.MeasureText(ch.ToString(), textPaint) + size * .06f;
            }
        }
        pixels = new byte[checked(chipWidth * chipHeight * 4)];
        System.Runtime.InteropServices.Marshal.Copy(bitmap.GetPixels(), pixels, 0, pixels.Length);
        var marginX = (int)Math.Round(width * .05); var marginY = (int)Math.Round(height * .05);
        var left = marginX; var right = width - marginX - chipWidth;
        var top = marginY; var bottom = height - marginY - chipHeight;
        if (left < 0 || right < 0 || top < 0 || bottom < 0 ||
            left + chipWidth > width || right + chipWidth > width ||
            top + chipHeight > height || bottom + chipHeight > height)
            throw new ArgumentOutOfRangeException(nameof(width), "The disclosure chip and margins do not fit.");
        origins = intervals.Select(interval =>
        {
            var preferred = position switch
            {
                VoiceLabLabelPosition.TopLeft => (X: left, Y: top),
                VoiceLabLabelPosition.TopRight => (X: right, Y: top),
                VoiceLabLabelPosition.BottomLeft => (X: left, Y: bottom),
                _ => (X: right, Y: bottom)
            };
            var rect = new SKRect(preferred.X, preferred.Y, preferred.X + chipWidth, preferred.Y + chipHeight);
            var collision = captionBlocks.Any(block => block.Start < interval.End && block.End > interval.Start &&
                rect.Left < block.Bounds.Right && rect.Right > block.Bounds.Left &&
                rect.Top < block.Bounds.Bottom && rect.Bottom > block.Bounds.Top);
            if (!collision) return preferred;
            return position is VoiceLabLabelPosition.TopLeft or VoiceLabLabelPosition.BottomLeft ? (right, top) : (left, top);
        }).ToArray();
    }

    /// <summary>Return Core's interval opacity at an edited-timeline time.</summary>
    public double OpacityAt(double time)
    {
        if (!required || !double.IsFinite(time)) return 0;
        foreach (var interval in intervals)
            if (time >= interval.Start && time < interval.End)
                return fadeSeconds > 0 ? Math.Clamp(Math.Min((time - interval.Start) / fadeSeconds,
                    (interval.End - time) / fadeSeconds), 0, 1) : 1;
        return 0;
    }

    /// <summary>Blend premultiplied chip bytes over the existing BGRA frame in gamma-encoded sRGB.</summary>
    public void Draw(PixelBuffer output, double time, CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var index = -1;
        for (var i = 0; i < intervals.Length; i++)
            if (time >= intervals[i].Start && time < intervals[i].End) { index = i; break; }
        if (index < 0) return;
        var opacity = OpacityAt(time);
        if (opacity <= 0) return;
        if (output.Width != width || output.Height != height || output.Stride < width * 4 ||
            output.Pixels.Length < output.Stride * height) throw new ArgumentException("Invalid disclosure BGRA frame.", nameof(output));
        var target = output.Pixels.Span;
        var (originX, originY) = origins[index];
        for (var y = 0; y < chipHeight; y++)
        {
            ct.ThrowIfCancellationRequested();
            var row = (originY + y) * output.Stride + originX * 4;
            var sourceRow = y * chipWidth * 4;
            for (var x = 0; x < chipWidth; x++)
            {
                var src = sourceRow + x * 4; var dst = row + x * 4;
                var alpha = pixels[src + 3] / 255d * opacity;
                if (alpha == 0) continue;
                var inverse = 1 - alpha;
                for (var channel = 0; channel < 3; channel++)
                    target[dst + channel] = (byte)Math.Clamp((int)Math.Round(pixels[src + channel] * opacity +
                        target[dst + channel] * inverse), 0, 255);
                target[dst + 3] = 255;
            }
        }
    }

    /// <summary>End use of this render-snapshot overlay.</summary>
    public void Dispose() => disposed = true;
}
