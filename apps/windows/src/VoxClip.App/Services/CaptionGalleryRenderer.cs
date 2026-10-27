using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Captions;

namespace VoxClip.App.Services;

internal sealed class CaptionGalleryRenderer(string root)
{
    private readonly HarfBuzzGlyphShaper shaper = new(root);
    private readonly SkiaCaptionRasterizer rasterizer = new(root);
    private readonly CaptionCards cards = new(root);
    internal CaptionResources Resources => shaper.Resources;

    internal async Task<CardBitmap> RenderAsync(Project project, CaptionStyle style, CaptionGallerySample sample,
        PixelBuffer? frame, bool loading, int width, int height, (byte Blue, byte Green, byte Red) stage, CancellationToken ct)
    {
        var source = project.Media.Source.Video;
        var oriented = source is null ? new PixelSize(1920, 1080) : source.RotationDegrees is 90 or 270
            ? new(source.Height, source.Width) : new(source.Width, source.Height);
        var output = ExportPresets.OutputSize(oriented, project.Export.Aspect);
        var captions = project.Captions with { StyleId = style.Id, Overrides = style.Id == project.Captions.StyleId ? project.Captions.Overrides : default };
        CaptionTrack? track = null;
        try
        {
            track = await CaptionEngine.BuildAsync(new(style, captions, output, sample.Words,
                sample.Source == CaptionGallerySampleSource.Preview ? "en" : project.Transcript?.Language ?? "und", sample.Duration), shaper, null, ct);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is not OutOfMemoryException) { }
        var resolved = track?.Style ?? style;
        var backdrop = CaptionTileState.Backdrop(loading, frame is not null);
        var result = backdrop == CaptionTileBackdrop.Card ? cards.GalleryBackdrop(resolved, width, height) : new CardBitmap(new byte[width * height * 4], width, height);
        if (backdrop != CaptionTileBackdrop.Card)
        {
            for (var offset = 0; offset < result.Pixels.Length; offset += 4)
            {
                result.Pixels[offset] = stage.Blue;
                result.Pixels[offset + 1] = stage.Green;
                result.Pixels[offset + 2] = stage.Red;
                result.Pixels[offset + 3] = 255;
            }
            if (backdrop == CaptionTileBackdrop.FrameBand && frame is not null) DrawBand(result, frame, resolved.Position.Y, true);
        }
        if (loading || track is null) return result;
        try
        {
            var overlay = await rasterizer.RenderAsync(new(track, sample.Time, ReduceMotion: true, Scale: (double)width / output.Width), ct);
            DrawBand(result, overlay, resolved.Position.Y, false);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is not OutOfMemoryException) { }
        return result;
    }

    private static void DrawBand(CardBitmap target, PixelBuffer source, double position, bool dim)
    {
        var scaledHeight = source.Height * (double)target.Width / source.Width;
        var top = Math.Clamp(position * scaledHeight - target.Height / 2.0, 0, Math.Max(0, scaledHeight - target.Height));
        for (var vertical = 0; vertical < target.Height; vertical++)
        {
            var sourceRow = Math.Clamp((int)((vertical + top) * source.Width / target.Width), 0, source.Height - 1);
            for (var horizontal = 0; horizontal < target.Width; horizontal++)
            {
                var sourceColumn = Math.Min(source.Width - 1, horizontal * source.Width / target.Width);
                var input = sourceRow * source.Stride + sourceColumn * 4;
                var output = (vertical * target.Width + horizontal) * 4;
                var alpha = source.Pixels.Span[input + 3] / 255.0;
                for (var channel = 0; channel < 3; channel++)
                    target.Pixels[output + channel] = dim ? (byte)(source.Pixels.Span[input + channel] * 0.65)
                        : (byte)Math.Clamp(source.Pixels.Span[input + channel] + target.Pixels[output + channel] * (1 - alpha), 0, 255);
                target.Pixels[output + 3] = 255;
            }
        }
    }
}
