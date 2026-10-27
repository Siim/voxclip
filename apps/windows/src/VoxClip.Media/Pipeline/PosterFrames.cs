using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>Poster frames for Home tiles and sidebar rows (design §5.4.7). The shipped FFmpeg decodes them in software,
/// never the Windows shell, which answers MKV and WEBM with a file-type icon.</summary>
public static class PosterFrames
{
    /// <summary>The times to try, in order: the scope's first kept word, then 1 s and 3 s later, then 10% into the scope.</summary>
    public static IReadOnlyList<double> Candidates(double firstKeptSeconds, double scopeStartSeconds, double scopeSeconds, double sourceSeconds)
    {
        var last = double.IsFinite(sourceSeconds) && sourceSeconds > 0 ? Math.Max(0, sourceSeconds - 0.05) : double.MaxValue;
        static double Finite(double value) => double.IsFinite(value) ? Math.Max(0, value) : 0;
        var first = Finite(firstKeptSeconds);
        return new[] { first, first + 1, first + 3, Finite(scopeStartSeconds) + Finite(scopeSeconds) * 0.1 }
            .Select(time => Math.Min(time, last)).Distinct().ToArray();
    }

    /// <summary>Decode the first candidate that is not black, turn it upright and encode a JPEG just large enough to cover
    /// <paramref name="coverWidth"/> × <paramref name="coverHeight"/>; null when every candidate is black.</summary>
    public static Task<byte[]?> ReadJpegAsync(string mediaPath, IReadOnlyList<double> candidates, int rotationDegrees, int coverWidth, int coverHeight, CancellationToken ct)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(coverWidth, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(coverHeight, 1);
        if (candidates.Count == 0) throw new ArgumentException("Choose at least one poster time.", nameof(candidates));
        return MediaThread.Run("vc-poster", () => Read(mediaPath, candidates, ((rotationDegrees % 360) + 360) % 360 / 90 * 90, coverWidth, coverHeight, ct), ct);
    }

    private static byte[]? Read(string path, IReadOnlyList<double> candidates, int rotation, int coverWidth, int coverHeight, CancellationToken ct)
    {
        FfmpegLoader.InitializeAsync(ct).GetAwaiter().GetResult();
        using var decoder = new VideoDecoder(path, hardware: false);
        foreach (var time in candidates)
        {
            ct.ThrowIfCancellationRequested();
            var frame = decoder.ReadAt(time, false, ct);
            if (!IsBlack(frame)) return Encode(frame, rotation, coverWidth, coverHeight);
        }
        return null;
    }

    /// <summary>The §5.4.7 test on a 32 × 18 sample of the frame: mean luma under 0.06 and standard deviation under 0.02.</summary>
    public static bool IsBlack(PixelBuffer frame)
    {
        if (frame.Width <= 0 || frame.Height <= 0) return true;
        var pixels = frame.Pixels.Span;
        double sum = 0, squares = 0;
        const int columns = 32, rows = 18;
        for (var row = 0; row < rows; row++)
        {
            var y = (int)((row + 0.5) * frame.Height / rows);
            for (var column = 0; column < columns; column++)
            {
                var index = y * frame.Stride + (int)((column + 0.5) * frame.Width / columns) * 4;
                var luma = (0.0722 * pixels[index] + 0.7152 * pixels[index + 1] + 0.2126 * pixels[index + 2]) / 255; // BT.709 from BGRA
                sum += luma;
                squares += luma * luma;
            }
        }
        var mean = sum / (columns * rows);
        var deviation = Math.Sqrt(Math.Max(0, squares / (columns * rows) - mean * mean));
        return mean < 0.06 && deviation < 0.02;
    }

    private static unsafe byte[] Encode(PixelBuffer frame, int rotation, int coverWidth, int coverHeight)
    {
        var quarter = rotation is 90 or 270;
        var (width, height) = quarter ? (frame.Height, frame.Width) : (frame.Width, frame.Height);
        var scale = Math.Min(1, Math.Max(coverWidth / (double)width, coverHeight / (double)height));
        var outputWidth = Math.Max(1, (int)Math.Round(width * scale));
        var outputHeight = Math.Max(1, (int)Math.Round(height * scale));
        using var pin = frame.Pixels.Pin();
        using var source = SKImage.FromPixels(new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Opaque), (IntPtr)pin.Pointer, frame.Stride)
            ?? throw Failed();
        using var surface = SKSurface.Create(new SKImageInfo(outputWidth, outputHeight, SKColorType.Bgra8888, SKAlphaType.Opaque)) ?? throw Failed();
        var canvas = surface.Canvas;
        canvas.Translate(outputWidth / 2f, outputHeight / 2f);
        canvas.RotateDegrees(rotation);
        var drawWidth = (float)(frame.Width * scale);
        var drawHeight = (float)(frame.Height * scale);
        canvas.DrawImage(source, new SKRect(-drawWidth / 2, -drawHeight / 2, drawWidth / 2, drawHeight / 2), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
        using var image = surface.Snapshot();
        using var data = image.Encode(SKEncodedImageFormat.Jpeg, 85) ?? throw Failed();
        return data.ToArray();
    }

    private static VoxClipException Failed() =>
        new(VoxClipErrorCode.DecodeFailed, "VoxClip couldn't make a thumbnail for this video. Your edits are saved.");
}
