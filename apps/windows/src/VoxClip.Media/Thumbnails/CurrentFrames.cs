using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Thumbnails;

/// <summary>Undecorated current frames, preserving black content and export framing.</summary>
public static class CurrentFrames
{
    /// <summary>Decode one frame without the poster-selection black-frame heuristic.</summary>
    public static Task<PixelBuffer> ReadAsync(string mediaPath, double time, int rotation, PixelSize output, PixelSize exportFrame, CancellationToken ct) =>
        MediaThread.Run("vc-current-frame", () =>
        {
            FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
            using var decoder = new VideoDecoder(mediaPath, hardware: false);
            var frame = decoder.ReadAt(time, false, ct);
            return Transform(frame, rotation, output, exportFrame);
        }, ct);

    /// <summary>Orient and centre-crop using the preview/export source rectangle.</summary>
    public static unsafe PixelBuffer Transform(PixelBuffer frame, int rotation, PixelSize output, PixelSize? exportFrame = null)
    {
        rotation = ((rotation % 360) + 360) % 360;
        var quarter = rotation is 90 or 270;
        var orientedWidth = quarter ? frame.Height : frame.Width;
        var orientedHeight = quarter ? frame.Width : frame.Height;
        using var pin = frame.Pixels.Pin();
        using var source = SKImage.FromPixels(new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Opaque), (IntPtr)pin.Pointer, frame.Stride)
            ?? throw new InvalidOperationException("Unable to read the current video frame.");
        using var oriented = new SKBitmap(new SKImageInfo(orientedWidth, orientedHeight, SKColorType.Bgra8888, SKAlphaType.Opaque));
        using (var canvas = new SKCanvas(oriented))
        {
            canvas.Translate(orientedWidth / 2f, orientedHeight / 2f);
            canvas.RotateDegrees(rotation);
            canvas.DrawImage(source, -frame.Width / 2f, -frame.Height / 2f);
        }
        var crop = ExportPresets.CenterCrop(new(orientedWidth, orientedHeight), exportFrame ?? output);
        var left = (int)Math.Floor(crop.X); var top = (int)Math.Floor(crop.Y);
        var width = Math.Clamp((int)Math.Round(crop.Width), 1, orientedWidth - left);
        var height = Math.Clamp((int)Math.Round(crop.Height), 1, orientedHeight - top);
        using var bitmap = new SKBitmap(new SKImageInfo(output.Width, output.Height, SKColorType.Bgra8888, SKAlphaType.Opaque));
        using (var canvas = new SKCanvas(bitmap))
            canvas.DrawBitmap(oriented, new SKRect(left, top, left + width, top + height), new SKRect(0, 0, output.Width, output.Height));
        return new(bitmap.Bytes, bitmap.Width, bitmap.Height, bitmap.RowBytes);
    }
}
