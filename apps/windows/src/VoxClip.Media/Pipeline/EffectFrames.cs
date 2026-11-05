using System.Buffers;
using System.Collections.Concurrent;
using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Pipeline;

/// <summary>Draws a render's picture effects (ai.md §18.5; Mac EffectFrames) on the frame the composer builds, so preview and export
/// show the same pixels. Censors and pointers sit in picture space and go through the same crop as the video; titles, lower
/// thirds, stickers and the progress bar sit in the output frame. Overlays are rasterized once and reused. Coordinates here are
/// top-left; every Mac rule written for Core Image's bottom-left frame is mirrored.</summary>
internal sealed class EffectFrames : IDisposable
{
    /// <summary>VoxClip yellow, the accent of pointers and the progress bar: sRGB (1, 0.82, 0.04).</summary>
    internal static readonly SKColor Accent = new(255, 209, 10);
    private readonly string? sharedRoot;
    private readonly ConcurrentDictionary<string, Overlay?> overlays = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, EffectTextFont?> fonts = new(StringComparer.Ordinal);

    internal EffectFrames(ClipEffectsRenderInput input, string? sharedRoot)
    {
        Input = input; this.sharedRoot = sharedRoot;
        Picture = input.Picture;
    }

    internal ClipEffectsRenderInput Input { get; }
    private IReadOnlyList<ClipEffect> Picture { get; }
    /// <summary>True when there is anything to draw.</summary>
    internal bool HasPicture => Picture.Count > 0;

    internal sealed record Overlay(SKImage Image, SKRectI Box);

    /// <summary>Blurs, pixelates and points at regions of <paramref name="frame"/>, the output frame filled from <paramref name="crop"/>
    /// of the oriented source picture (<paramref name="sourceWidth"/> × <paramref name="sourceHeight"/>, after the controls' flip and
    /// turn) at source time <paramref name="time"/>. Regions are stored as filmed; <paramref name="controls"/> maps them
    /// (<see cref="ClipControlsRendering.MapRect"/>) so a blur stays on the face it covers.</summary>
    internal unsafe void DrawPicture(PixelBuffer frame, int sourceWidth, int sourceHeight, RectD crop, double time, ProjectClipControls? controls,
        CancellationToken ct)
    {
        var active = Picture.Where(effect => effect.UsesRect && time >= effect.Start && time < effect.End).ToArray();
        if (active.Length == 0 || crop.Width <= 0 || crop.Height <= 0) return;
        var scaleX = frame.Width / crop.Width;
        var scaleY = frame.Height / crop.Height;
        SKRectI Mapped(ClipEffectRect filmed)
        {
            var rect = controls.MapRect(filmed);
            var left = (rect.X * sourceWidth - crop.X) * scaleX;
            var top = (rect.Y * sourceHeight - crop.Y) * scaleY;
            var right = left + rect.Width * sourceWidth * scaleX;
            var bottom = top + rect.Height * sourceHeight * scaleY;
            return new((int)Math.Floor(left), (int)Math.Floor(top), (int)Math.Ceiling(right), (int)Math.Ceiling(bottom));
        }
        var bounds = new SKRectI(0, 0, frame.Width, frame.Height);
        foreach (var effect in active.Where(effect => effect.Kind is "blur" or "pixelate"))
        {
            ct.ThrowIfCancellationRequested();
            if (effect.RectAt(time) is not { } rect) continue;
            var region = SKRectI.Intersect(Mapped(rect), bounds);
            if (region.Width < 1 || region.Height < 1) continue;
            Censor(frame, region, effect.Kind == "pixelate");
        }
        var pointers = active.Where(effect => effect.Kind is "arrow" or "circle").ToArray();
        if (pointers.Length == 0) return;
        using var pin = frame.Pixels.Pin();
        using var surface = SKSurface.Create(new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul), (IntPtr)pin.Pointer, frame.Stride)
            ?? throw new InvalidOperationException("Could not wrap the effect frame.");
        foreach (var effect in pointers)
        {
            if (effect.RectAt(time) is not { } rect) continue;
            var opacity = effect.OpacityAt(time);
            if (opacity <= 0) continue;
            var region = Mapped(rect);
            WithOpacity(surface.Canvas, opacity, canvas => DrawPointer(canvas, effect.Kind, region, frame.Width, frame.Height));
        }
        surface.Canvas.Flush();
    }

    /// <summary>Titles, lower thirds, stickers and the progress bar over the finished frame at source time <paramref name="time"/>
    /// and edited output time <paramref name="outputTime"/>; <paramref name="mapTime"/> maps source to edited seconds.</summary>
    internal unsafe void DrawFrame(PixelBuffer frame, double time, double outputTime, Func<double, double> mapTime, CancellationToken ct)
    {
        var active = Picture.Where(effect => effect.UsesPosition && time >= effect.Start && time < effect.End).ToArray();
        if (active.Length == 0) return;
        using var pin = frame.Pixels.Pin();
        using var surface = SKSurface.Create(new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul), (IntPtr)pin.Pointer, frame.Stride)
            ?? throw new InvalidOperationException("Could not wrap the effect frame.");
        var canvas = surface.Canvas;
        foreach (var effect in active)
        {
            ct.ThrowIfCancellationRequested();
            var opacity = effect.OpacityAt(time);
            if (opacity <= 0) continue;
            if (effect.Kind == "progress")
            {
                var start = mapTime(effect.Start);
                var end = mapTime(effect.End);
                var fraction = end > start ? Math.Clamp((outputTime - start) / (end - start), 0, 1) : 1;
                WithOpacity(canvas, opacity, target => DrawProgress(target, fraction, effect.Position ?? "bottom", frame.Width, frame.Height));
            }
            else if (OverlayFor(effect, frame.Width, frame.Height) is { } overlay)
            {
                using var paint = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255)) };
                canvas.DrawImage(overlay.Image, overlay.Box.Left, overlay.Box.Top, paint);
            }
        }
        canvas.Flush();
    }

    private static void WithOpacity(SKCanvas canvas, double opacity, Action<SKCanvas> draw)
    {
        if (opacity >= 1) { draw(canvas); return; }
        using var paint = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(Math.Max(0, opacity) * 255)) };
        canvas.SaveLayer(paint);
        draw(canvas);
        canvas.Restore();
    }

    // MARK: Censors

    /// <summary>A strong blur, or large square pixels, over <paramref name="region"/>. Both scale with the region, so a small face
    /// and a whole screen are equally unreadable. Edges clamp to the frame, as Core Image's clampedToExtent does.</summary>
    internal static unsafe void Censor(PixelBuffer frame, SKRectI region, bool pixelate)
    {
        var side = Math.Min(region.Width, region.Height);
        var block = pixelate ? Math.Max(8, Math.Round(side / 8.0, MidpointRounding.AwayFromZero)) : 0;
        var sigma = pixelate ? block / 2 : Math.Min(80, Math.Max(10, side * 0.2));
        var margin = (int)Math.Ceiling(sigma * 3) + (pixelate ? (int)block : 0);
        var area = SKRectI.Intersect(SKRectI.Inflate(region, margin, margin), new SKRectI(0, 0, frame.Width, frame.Height));
        var info = new SKImageInfo(area.Width, area.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        var blurred = ArrayPool<byte>.Shared.Rent(area.Width * area.Height * 4);
        try
        {
            using (var pin = frame.Pixels.Pin())
            fixed (byte* output = blurred)
            {
                var origin = (IntPtr)((byte*)pin.Pointer + area.Top * frame.Stride + area.Left * 4);
                using var source = SKImage.FromPixelCopy(info, origin, frame.Stride) ?? throw new InvalidOperationException("Could not copy the censored region.");
                using var surface = SKSurface.Create(info, (IntPtr)output, area.Width * 4) ?? throw new InvalidOperationException("Could not blur the censored region.");
                using var filter = SKImageFilter.CreateBlur((float)sigma, (float)sigma, SKShaderTileMode.Clamp);
                using var paint = new SKPaint { ImageFilter = filter, BlendMode = SKBlendMode.Src };
                surface.Canvas.DrawImage(source, 0, 0, paint);
                surface.Canvas.Flush();
            }
            var pixels = frame.Pixels.Span;
            for (var row = region.Top; row < region.Bottom; row++)
                for (var column = region.Left; column < region.Right; column++)
                {
                    int x = column, y = row;
                    if (pixelate)
                    {
                        // Core Image's pixellate grid starts at the region's bottom-left corner and samples each block's centre.
                        var blockX = Math.Floor((column + 0.5 - region.Left) / block);
                        var blockY = Math.Floor((region.Bottom - row - 0.5) / block);
                        x = Math.Clamp((int)Math.Floor(region.Left + (blockX + 0.5) * block), 0, frame.Width - 1);
                        y = Math.Clamp((int)Math.Floor(region.Bottom - (blockY + 0.5) * block), 0, frame.Height - 1);
                    }
                    var from = ((Math.Clamp(y, area.Top, area.Bottom - 1) - area.Top) * area.Width + Math.Clamp(x, area.Left, area.Right - 1) - area.Left) * 4;
                    blurred.AsSpan(from, 4).CopyTo(pixels.Slice(row * frame.Stride + column * 4, 4));
                }
        }
        finally { ArrayPool<byte>.Shared.Return(blurred); }
    }

    // MARK: Pointers

    /// <summary>A ring around <paramref name="region"/>, or an arrow whose tip touches it from the side facing the frame's centre.</summary>
    internal static void DrawPointer(SKCanvas canvas, string kind, SKRectI region, int width, int height)
    {
        var line = (float)Math.Max(4, Math.Min(width, height) * 0.012);
        var shadow = new SKColor(0, 0, 0, 115);
        using var paint = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke };
        if (kind == "circle")
        {
            var ring = SKRect.Inflate(region, region.Width * 0.12f + line, region.Height * 0.12f + line);
            paint.StrokeWidth = line * 1.8f; paint.Color = shadow; canvas.DrawOval(ring, paint);
            paint.StrokeWidth = line; paint.Color = Accent; canvas.DrawOval(ring, paint);
            return;
        }
        var target = new SKPoint(region.MidX, region.MidY);
        var centre = new SKPoint(width / 2f, height / 2f);
        double dx = centre.X - target.X, dy = centre.Y - target.Y;
        // Mac points down-left (Core Image's −1, −1) when the region sits at the centre: −1, +1 with y down.
        if (Math.Sqrt(dx * dx + dy * dy) < Math.Min(width, height) * 0.1) { dx = -1; dy = 1; }
        var length = Math.Sqrt(dx * dx + dy * dy);
        var unit = (X: dx / length, Y: dy / length);
        var reachX = unit.X == 0 ? double.PositiveInfinity : region.Width / 2.0 / Math.Abs(unit.X);
        var reachY = unit.Y == 0 ? double.PositiveInfinity : region.Height / 2.0 / Math.Abs(unit.Y);
        var edge = Math.Min(reachX, reachY);
        var tip = (X: target.X + unit.X * (edge + line), Y: target.Y + unit.Y * (edge + line));
        var arrowLength = Math.Min(width, height) * 0.22;
        var tail = (X: tip.X + unit.X * arrowLength, Y: tip.Y + unit.Y * arrowLength);
        var head = line * 4.5;
        var normal = (X: -unit.Y, Y: unit.X);
        var basePoint = (X: tip.X + unit.X * head, Y: tip.Y + unit.Y * head);
        using var shaft = new SKPath();
        shaft.MoveTo((float)tail.X, (float)tail.Y); shaft.LineTo((float)basePoint.X, (float)basePoint.Y);
        using var arrowHead = new SKPath();
        arrowHead.MoveTo((float)tip.X, (float)tip.Y);
        arrowHead.LineTo((float)(basePoint.X + normal.X * head * 0.6), (float)(basePoint.Y + normal.Y * head * 0.6));
        arrowHead.LineTo((float)(basePoint.X - normal.X * head * 0.6), (float)(basePoint.Y - normal.Y * head * 0.6));
        arrowHead.Close();
        paint.StrokeCap = SKStrokeCap.Round;
        paint.StrokeWidth = line * 1.9f; paint.Color = shadow; canvas.DrawPath(shaft, paint);
        paint.StrokeWidth = line * 0.9f; canvas.DrawPath(arrowHead, paint);
        paint.StrokeWidth = line; paint.Color = Accent; canvas.DrawPath(shaft, paint);
        paint.Style = SKPaintStyle.Fill; canvas.DrawPath(arrowHead, paint);
    }

    // MARK: Output frame

    internal static void DrawProgress(SKCanvas canvas, double fraction, string position, int width, int height)
    {
        var barHeight = (float)Math.Max(6, Math.Round(height * 0.008, MidpointRounding.AwayFromZero));
        var top = position == "top" ? 0 : height - barHeight;
        using var paint = new SKPaint { Color = new SKColor(255, 255, 255, 64) };
        canvas.DrawRect(new SKRect(0, top, width, top + barHeight), paint);
        paint.Color = Accent;
        canvas.DrawRect(new SKRect(0, top, (float)Math.Round(width * fraction, MidpointRounding.AwayFromZero), top + barHeight), paint);
    }

    private Overlay? OverlayFor(ClipEffect effect, int width, int height)
    {
        var key = $"{effect.Kind}|{effect.Text}|{effect.Position}|{effect.Scale ?? 1}|{width}x{height}";
        return overlays.GetOrAdd(key, _ => effect.Kind switch
        {
            "title" => Title(effect.Text ?? "", effect.Position ?? "top", width, height),
            "lowerThird" => LowerThird(effect.Text ?? "", effect.Position ?? "bottomLeft", width, height),
            "sticker" => Sticker(effect.Text ?? "", effect.Position ?? "topRight", effect.Scale ?? 1, width, height),
            _ => null
        });
    }

    internal const string TitleFontPath = "fonts/roboto/Roboto-Black.ttf";
    internal const string LowerThirdFontPath = "fonts/dm-sans/DMSans-Bold.ttf";

    /// <summary>A bundled font for overlay text, measured from its own tables (<see cref="EffectTextFont"/>); null without the
    /// shared folder or the file.</summary>
    internal EffectTextFont? TextFont(string relative) => fonts.GetOrAdd(relative, path => sharedRoot is null ? null
        : EffectTextFont.Load(Path.Combine(sharedRoot, path.Replace('/', Path.DirectorySeparatorChar))));

    private static SKRectI Integral(double x, double y, double width, double height)
        => new((int)Math.Floor(x), (int)Math.Floor(y), (int)Math.Ceiling(x + width), (int)Math.Ceiling(y + height));

    private static Overlay? Raster(SKRectI box, int width, int height, Action<SKCanvas> draw)
    {
        var clipped = SKRectI.Intersect(box, new SKRectI(0, 0, width, height));
        if (clipped.Width < 1 || clipped.Height < 1) return null;
        using var surface = SKSurface.Create(new SKImageInfo(clipped.Width, clipped.Height, SKColorType.Bgra8888, SKAlphaType.Premul));
        if (surface is null) return null;
        surface.Canvas.Clear(SKColors.Transparent);
        surface.Canvas.Translate(-clipped.Left, -clipped.Top);
        draw(surface.Canvas);
        surface.Canvas.Flush();
        return new(surface.Snapshot(), clipped);
    }

    /// <summary>How <paramref name="text"/> sets as a title (Mac titleLayout); null without the bundled font.</summary>
    internal EffectTitleLayout? TitleLayout(string text, string position, int width, int height)
        => TextFont(TitleFontPath) is { } font ? EffectTitleLayout.Make(font, text, position, width, height) : null;

    /// <summary>Big centred text on a dark rounded box: top, centre or bottom of the frame, a long one in up to three balanced
    /// lines (<see cref="EffectTitleLayout"/>).</summary>
    internal Overlay? Title(string text, string position, int width, int height)
    {
        if (TextFont(TitleFontPath) is not { } font) return null;
        var layout = EffectTitleLayout.Make(font, text, position, width, height);
        var box = layout.Box;
        var radius = (layout.LineHeight + layout.PadY * 2) * 0.22f;
        return Raster(box, width, height, canvas =>
        {
            using var fill = new SKPaint { IsAntialias = true, Color = new SKColor(0, 0, 0, 158) };
            canvas.DrawRoundRect(new SKRect(box.Left, box.Top, box.Right, box.Bottom), radius, radius, fill);
            canvas.Save();
            canvas.ClipRect(new SKRect(box.Left + layout.PadX * 0.5f, box.Top, box.Right - layout.PadX * 0.5f, box.Bottom));
            using var ink = new SKPaint { IsAntialias = true, Color = SKColors.White };
            if (layout.Lines.Count == 1)
            {
                var line = layout.Lines[0];
                font.Draw(canvas, line, layout.Size, box.MidX - line.Width / 2, font.Baseline(box.MidY, layout.Size), ink);
            }
            else
            {
                // Lines share the font's cap height, so a line with descenders sits on the same rhythm as one without.
                var capHeight = font.CapHeightAt(layout.Size);
                for (var index = 0; index < layout.Lines.Count; index++)
                {
                    var line = layout.Lines[index];
                    var centre = box.Top + layout.PadY + layout.LineHeight * (index + 0.5f);
                    font.Draw(canvas, line, layout.Size, box.MidX - line.Width / 2, centre + capHeight / 2, ink);
                }
            }
            canvas.Restore();
        });
    }

    /// <summary>A name strip near the bottom: an accent bar and white text on a dark box, left or right.</summary>
    internal Overlay? LowerThird(string text, string position, int width, int height)
    {
        if (TextFont(LowerThirdFontPath) is not { } font) return null;
        var shortSide = Math.Min(width, height);
        var size = (float)Math.Round(shortSide * 0.045, MidpointRounding.AwayFromZero);
        var line = font.Shape(text, size);
        var bar = Math.Max(4, size * 0.18f);
        var pad = size * 0.5f;
        var boxWidth = Math.Min(width * 0.86, line.Width + pad * 2 + bar);
        var boxHeight = size * 1.2 + pad * 1.2;
        var margin = shortSide * 0.05;
        var x = position == "bottomRight" ? width - margin - boxWidth : margin;
        var box = Integral(x, height * 0.84 - boxHeight, boxWidth, boxHeight);
        return Raster(box, width, height, canvas =>
        {
            using var fill = new SKPaint { Color = new SKColor(18, 18, 18, 209) };
            canvas.DrawRect(new SKRect(box.Left, box.Top, box.Right, box.Bottom), fill);
            fill.Color = Accent;
            canvas.DrawRect(new SKRect(box.Left, box.Top, box.Left + bar, box.Bottom), fill);
            canvas.Save();
            canvas.ClipRect(new SKRect(box.Left + bar, box.Top, box.Right - bar, box.Bottom));
            using var ink = new SKPaint { IsAntialias = true, Color = SKColors.White };
            font.Draw(canvas, line, size, box.Left + bar + pad, font.Baseline(box.MidY, size), ink);
            canvas.Restore();
        });
    }

    /// <summary>One bundled Noto emoji (shared/fonts/noto-emoji/png128) in a corner or the centre; null when it is not bundled.</summary>
    internal Overlay? Sticker(string text, string position, double scale, int width, int height)
    {
        if (sharedRoot is null) return null;
        var code = string.Join('_', text.EnumerateRunes().Where(rune => rune.Value is not (0xFE0F or 0xFE0E)).Select(rune => rune.Value.ToString("x")));
        if (code.Length == 0) return null;
        var file = Path.Combine(sharedRoot, "fonts", "noto-emoji", "png128", $"emoji_u{code}.png");
        if (!File.Exists(file)) return null;
        using var image = SKImage.FromEncodedData(file);
        if (image is null) return null;
        var shortSide = Math.Min(width, height);
        var side = Math.Round(shortSide * 0.16 * scale, MidpointRounding.AwayFromZero);
        var margin = shortSide * 0.06;
        var x = position switch { "topLeft" or "bottomLeft" => margin, "center" or "top" or "bottom" => (width - side) / 2, _ => width - margin - side };
        var y = position switch { "bottomLeft" or "bottomRight" => height * 0.8 - side, "center" => (height - side) / 2, _ => margin };
        var box = Integral(x, y, side, side);
        return Raster(box, width, height, canvas =>
            canvas.DrawImage(image, new SKRect(box.Left, box.Top, box.Right, box.Bottom), new SKSamplingOptions(SKCubicResampler.Mitchell)));
    }

    public void Dispose()
    {
        foreach (var overlay in overlays.Values) overlay?.Image.Dispose();
        overlays.Clear();
        foreach (var font in fonts.Values) font?.Dispose();
        fonts.Clear();
    }
}
