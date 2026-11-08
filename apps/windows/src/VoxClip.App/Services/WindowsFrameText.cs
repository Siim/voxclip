using System.Runtime.InteropServices.WindowsRuntime;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace VoxClip.App.Services;

/// <summary>Text lines in a frame from <see cref="OcrEngine"/> (ADR-R48 Windows, W4): one engine for the user profile's
/// languages, made once and reused, its recognitions one at a time. Each line's box is the min and max over its words
/// (<see cref="FrameTextLines.LineBox"/>), as Ask Claude's eyes make them. The recognised strings never leave this method: it
/// returns rects only. On-device; nothing leaves the PC. With no OCR language installed it finds no text.</summary>
internal sealed class WindowsFrameText : IFrameTextLines, IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private OcrEngine? engine;
    private bool created;

    public async Task<IReadOnlyList<ClipEffectRect>> LinesAsync(PixelBuffer frame, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(frame);
        if (frame.Width <= 0 || frame.Height <= 0) return [];
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!created)
            {
                engine = OcrEngine.TryCreateFromUserProfileLanguages();
                created = true;
            }
            if (engine is null) return [];
            using var bitmap = SoftwareBitmap.CreateCopyFromBuffer(Packed(frame).AsBuffer(), BitmapPixelFormat.Bgra8, frame.Width, frame.Height, BitmapAlphaMode.Ignore);
            var result = await engine.RecognizeAsync(bitmap);
            ct.ThrowIfCancellationRequested();
            var boxes = new List<ClipEffectRect>(result.Lines.Count);
            foreach (var line in result.Lines)
            {
                if (LineBox(line, frame.Width, frame.Height) is { } box) boxes.Add(box);
            }
            return boxes;
        }
        finally
        {
            gate.Release();
        }
    }

    public void Dispose() => gate.Dispose();

    /// <summary>A recognised line's box, or null for a line with no words or only blank text (the rule Ask Claude's eyes keep).</summary>
    internal static ClipEffectRect? LineBox(OcrLine line, int frameWidth, int frameHeight)
    {
        if (line.Words.Count == 0 || line.Text.Trim().Length == 0) return null;
        var words = line.Words.Select(word => new OcrWordBox(word.BoundingRect.X, word.BoundingRect.Y, word.BoundingRect.Width, word.BoundingRect.Height)).ToArray();
        return FrameTextLines.LineBox(words, frameWidth, frameHeight);
    }

    /// <summary>The frame's rows without padding, as <see cref="SoftwareBitmap.CreateCopyFromBuffer(Windows.Storage.Streams.IBuffer, BitmapPixelFormat, int, int, BitmapAlphaMode)"/> reads them.</summary>
    internal static byte[] Packed(PixelBuffer frame)
    {
        var row = frame.Width * 4;
        if (frame.Stride == row) return frame.Pixels.ToArray();
        var packed = new byte[row * frame.Height];
        var pixels = frame.Pixels.Span;
        for (var y = 0; y < frame.Height; y++) pixels.Slice(y * frame.Stride, row).CopyTo(packed.AsSpan(y * row, row));
        return packed;
    }
}
