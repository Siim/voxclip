using System.Runtime.InteropServices.WindowsRuntime;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Thumbnails;
using Windows.Graphics.Imaging;
using Windows.Media.FaceAnalysis;
using Windows.Media.Ocr;

namespace VoxClip.App.Services;

/// <summary>Ask Claude's eyes on Windows (ai.md §18.1): the shipped FFmpeg decodes the upright frame (at most 1280 on its long side), then
/// <see cref="FaceDetector"/> finds faces and <see cref="OcrEngine"/> reads text lines, in picture space. On-device only; nothing leaves
/// the PC. No source (a demo, a missing file, an audio-only take) answers with nothing, and the request goes without detections.</summary>
internal sealed class WindowsAskClaudeVision(Func<(string Path, int Rotation, PixelSize Oriented)?> source) : IAskClaudeVision
{
    private const int LongSide = 1280;
    private FaceDetector? faces;
    private OcrEngine? reader;

    public async Task<AskClaudeFrameFindings> ObserveAsync(double time, bool text, CancellationToken ct)
    {
        if (source() is not { } media || media.Oriented.Width <= 0 || media.Oriented.Height <= 0) return AskClaudeFrameFindings.None;
        var scale = Math.Min(1, (double)LongSide / Math.Max(media.Oriented.Width, media.Oriented.Height));
        var size = new PixelSize(Math.Max(2, (int)Math.Round(media.Oriented.Width * scale) / 2 * 2), Math.Max(2, (int)Math.Round(media.Oriented.Height * scale) / 2 * 2));
        var frame = await CurrentFrames.ReadAsync(media.Path, Math.Max(0, time), media.Rotation, size, size, ct, preserveSource: true);
        ct.ThrowIfCancellationRequested();
        var packed = Packed(frame);
        using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(packed.AsBuffer(), BitmapPixelFormat.Bgra8, frame.Width, frame.Height, BitmapAlphaMode.Ignore);
        var found = new List<ClipEffectRect>();
        if (FaceDetector.IsSupported)
        {
            faces ??= await FaceDetector.CreateAsync();
            using var gray = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Gray8);
            foreach (var face in await faces.DetectFacesAsync(gray))
                found.Add(Rect(face.FaceBox.X, face.FaceBox.Y, face.FaceBox.Width, face.FaceBox.Height, frame.Width, frame.Height));
        }
        var lines = new List<AskClaudeTextLine>();
        if (text && (reader ??= OcrEngine.TryCreateFromUserProfileLanguages()) is { } ocr)
        {
            var result = await ocr.RecognizeAsync(bitmap);
            foreach (var line in result.Lines)
            {
                if (line.Words.Count == 0 || line.Text.Trim().Length == 0) continue;
                var left = line.Words.Min(word => word.BoundingRect.X);
                var top = line.Words.Min(word => word.BoundingRect.Y);
                var right = line.Words.Max(word => word.BoundingRect.X + word.BoundingRect.Width);
                var bottom = line.Words.Max(word => word.BoundingRect.Y + word.BoundingRect.Height);
                lines.Add(new(line.Text.Trim(), Rect(left, top, right - left, bottom - top, frame.Width, frame.Height)));
            }
        }
        return new(found, lines);
    }

    /// <summary>The frame's rows without padding, as <see cref="SoftwareBitmap.CreateCopyFromBuffer(Windows.Storage.Streams.IBuffer, BitmapPixelFormat, int, int, BitmapAlphaMode)"/> reads them.</summary>
    private static byte[] Packed(VoxClip.Core.Domain.Captions.PixelBuffer frame)
    {
        var row = frame.Width * 4;
        if (frame.Stride == row) return frame.Pixels.ToArray();
        var packed = new byte[row * frame.Height];
        var pixels = frame.Pixels.Span;
        for (var y = 0; y < frame.Height; y++) pixels.Slice(y * frame.Stride, row).CopyTo(packed.AsSpan(y * row, row));
        return packed;
    }

    private static ClipEffectRect Rect(double x, double y, double width, double height, int frameWidth, int frameHeight) =>
        AskClaudeValidator.Clamped(new(x / frameWidth, y / frameHeight, width / frameWidth, height / frameHeight));
}
