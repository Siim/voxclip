using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Pipeline;

/// <summary>Picture's look tiles (looks spec §7.3 and §7.4): a square of the clip's frame before the grade, graded by the export's
/// own grade, so a tile shows what the export renders for that look.</summary>
public static class ClipLookTiles
{
    /// <summary>A <paramref name="edge"/> × <paramref name="edge"/> tile of <paramref name="still"/> (<see cref="Core.Services.Media.IPreviewEngine.StillBeforeGradeAsync"/>,
    /// at the export's size): <paramref name="square"/>, in the still's
    /// pixels, scaled to the tile (copied as it is when it already has the tile's size), then graded with
    /// <paramref name="colour"/>'s look, adjustments and grade through the Fix, the look, the adjustments, tone and Amount. The
    /// vignette sits on the tile itself and there is no grain: 2-pixel grain vanishes at tile size.</summary>
    public static PixelBuffer Render(PixelBuffer still, RectD square, int edge, ProjectClipControls colour, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(still);
        ArgumentNullException.ThrowIfNull(colour);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(edge);
        ct.ThrowIfCancellationRequested();
        var tile = Cut(still, square, edge);
        var recipe = ClipGradeRecipe.For(colour);
        ClipPicture.Grade(tile, recipe, ct);
        ClipPicture.Finish(tile, recipe, 0, null, ct, grain: false);
        return tile;
    }

    private static unsafe PixelBuffer Cut(PixelBuffer still, RectD square, int edge)
    {
        var pixels = new byte[checked(edge * edge * 4)];
        var left = (int)square.X;
        var top = (int)square.Y;
        if (left == square.X && top == square.Y && square.Width == edge && square.Height == edge && left >= 0 && top >= 0 &&
            left + edge <= still.Width && top + edge <= still.Height)
        {
            for (var row = 0; row < edge; row++)
                still.Pixels.Span.Slice((top + row) * still.Stride + left * 4, edge * 4).CopyTo(pixels.AsSpan(row * edge * 4));
            return new(pixels, edge, edge, edge * 4);
        }
        using var pin = still.Pixels.Pin();
        using var source = SKImage.FromPixels(new SKImageInfo(still.Width, still.Height, SKColorType.Bgra8888, SKAlphaType.Opaque), (IntPtr)pin.Pointer, still.Stride)
            ?? throw new InvalidOperationException("Could not read the still for its tiles.");
        fixed (byte* target = pixels)
        {
            using var surface = SKSurface.Create(new SKImageInfo(edge, edge, SKColorType.Bgra8888, SKAlphaType.Opaque), (IntPtr)target, edge * 4)
                ?? throw new InvalidOperationException("Could not draw a look tile.");
            surface.Canvas.DrawImage(source, new SKRect((float)square.X, (float)square.Y, (float)(square.X + square.Width), (float)(square.Y + square.Height)),
                new SKRect(0, 0, edge, edge), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), null);
            surface.Canvas.Flush();
        }
        return new(pixels, edge, edge, edge * 4);
    }
}
