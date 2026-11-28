using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;

namespace VoxClip.Media.Frames;

/// <summary>The small pictures the light facts and Auto read (looks spec §5.9, §9.3), twin of the Mac <c>FrameLightSampling</c>: a frame
/// scaled so its long side is the edge (never up), drawn into 8-bit sRGB with SkiaSharp and read as RGB bytes, rows from the top, with
/// the frame's face box.</summary>
public static class FrameLightSampling
{
    /// <summary><paramref name="frame"/> (premultiplied BGRA, upright) at <paramref name="edge"/> pixels on the long side, with
    /// <paramref name="face"/> (picture space, top-left origin); null when it can't be drawn.</summary>
    public static unsafe ClipFrameSample? Sample(PixelBuffer frame, int edge, ClipEffectRect? face)
    {
        ArgumentNullException.ThrowIfNull(frame);
        if (frame.Width <= 0 || frame.Height <= 0 || edge <= 0) return null;
        using var pin = frame.Pixels.Pin();
        using var source = SKImage.FromPixels(new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul, SKColorSpace.CreateSrgb()),
            (IntPtr)pin.Pointer, frame.Stride);
        return source is null ? null : Sample(source, edge, face);
    }

    /// <summary>A sheet JPEG at <paramref name="edge"/> pixels on the long side, with <paramref name="face"/>; null when the bytes are not
    /// an image.</summary>
    public static ClipFrameSample? Sample(byte[] jpeg, int edge, ClipEffectRect? face)
    {
        ArgumentNullException.ThrowIfNull(jpeg);
        if (jpeg.Length == 0 || edge <= 0) return null;
        using var source = SKImage.FromEncodedData(jpeg);
        return source is null ? null : Sample(source, edge, face);
    }

    /// <summary>The Fix Auto measures on a clip's sheet frames (<see cref="ClipColorFix.Measure"/>): up to <c>Auto.Frames</c> of them,
    /// spread evenly over the clip, each at <c>Auto.FrameSize</c>. Null when no frame could be read, so no measurement exists.</summary>
    public static ClipColorFix? Fix(IReadOnlyList<FrameSheetFrame> frames, ClipColorMeasure measure)
    {
        ArgumentNullException.ThrowIfNull(frames);
        ArgumentNullException.ThrowIfNull(measure);
        var limit = Math.Max(1, measure.Auto.Frames);
        var chosen = frames.Count <= limit ? frames
            : Enumerable.Range(0, limit).Select(index => frames[index * (frames.Count - 1) / Math.Max(1, limit - 1)]).ToArray();
        var samples = chosen.Select(frame => Sample(frame.Image.Data, measure.Auto.FrameSize, frame.Observation.Face?.Rect))
            .OfType<ClipFrameSample>().ToArray();
        return samples.Length == 0 ? null : ClipColorFix.Measure(samples, measure.Auto);
    }

    private static ClipFrameSample? Sample(SKImage source, int edge, ClipEffectRect? face)
    {
        var size = FfmpegFrameDecoder.Fit(source.Width, source.Height, edge);
        var info = new SKImageInfo(size.Width, size.Height, SKColorType.Rgba8888, SKAlphaType.Opaque, SKColorSpace.CreateSrgb());
        using var surface = SKSurface.Create(info);
        if (surface is null) return null;
        surface.Canvas.Clear(SKColors.Black);
        surface.Canvas.DrawImage(source, new SKRect(0, 0, size.Width, size.Height), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
        var rgba = new byte[size.Width * size.Height * 4];
        unsafe
        {
            fixed (byte* pointer = rgba)
            {
                if (!surface.ReadPixels(info, (IntPtr)pointer, size.Width * 4, 0, 0)) return null;
            }
        }
        var rgb = new byte[size.Width * size.Height * 3];
        for (var pixel = 0; pixel < size.Width * size.Height; pixel++)
        {
            rgb[pixel * 3] = rgba[pixel * 4];
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1];
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2];
        }
        return new ClipFrameSample(size.Width, size.Height, rgb, face);
    }
}
