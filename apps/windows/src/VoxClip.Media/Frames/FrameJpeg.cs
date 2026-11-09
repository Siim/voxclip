using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Frames;

/// <summary>The frame sheet's JPEGs, twin of the Mac <c>FrameJPEG</c>: scaled so the long edge is the sheet's (never up), sRGB, quality
/// 0.7. Encoded with SkiaSharp, as the poster frames are.</summary>
public static class FrameJpeg
{
    /// <summary>The Mac's lossy compression quality, 0.7, on SkiaSharp's 0–100 scale.</summary>
    public const int Quality = 70;

    /// <summary>The JPEG of <paramref name="frame"/> (premultiplied BGRA, upright) with its long side at most <paramref name="edge"/>.</summary>
    public static byte[] Encode(PixelBuffer frame, int edge) => Encode(frame, edge, Quality);

    /// <summary>The JPEG of <paramref name="frame"/> with its long side at most <paramref name="edge"/>, at <paramref name="quality"/>
    /// (0–100; an export's cover is 90, the Mac's 0.9).</summary>
    public static unsafe byte[] Encode(PixelBuffer frame, int edge, int quality)
    {
        ArgumentNullException.ThrowIfNull(frame);
        ArgumentOutOfRangeException.ThrowIfLessThan(edge, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(quality, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(quality, 100);
        if (frame.Width <= 0 || frame.Height <= 0) throw Failed();
        var size = FfmpegFrameDecoder.Fit(frame.Width, frame.Height, edge);
        using var pin = frame.Pixels.Pin();
        using var source = SKImage.FromPixels(new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul, SKColorSpace.CreateSrgb()),
            (IntPtr)pin.Pointer, frame.Stride) ?? throw Failed();
        using var surface = SKSurface.Create(new SKImageInfo(size.Width, size.Height, SKColorType.Bgra8888, SKAlphaType.Premul, SKColorSpace.CreateSrgb()))
            ?? throw Failed();
        surface.Canvas.Clear(SKColors.Black);
        surface.Canvas.DrawImage(source, new SKRect(0, 0, size.Width, size.Height), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
        using var image = surface.Snapshot();
        using var data = image.Encode(SKEncodedImageFormat.Jpeg, quality) ?? throw Failed();
        return data.ToArray();
    }

    /// <summary>A JPEG's pixel size, or null when the bytes are not an image.</summary>
    public static PixelSize? Size(byte[] jpeg)
    {
        ArgumentNullException.ThrowIfNull(jpeg);
        if (jpeg.Length == 0) return null;
        var info = SKBitmap.DecodeBounds(jpeg);
        return info.Width > 0 && info.Height > 0 ? new PixelSize(info.Width, info.Height) : null;
    }

    private static VoxClipException Failed() =>
        new(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't make a small picture of a video frame.");
}
