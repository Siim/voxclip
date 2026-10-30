#if DEBUG
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using Windows.Foundation;

namespace VoxClip.App.Services;

internal static class TranscriptAlignmentProbe
{
    internal static async Task RunAsync(TranscriptView transcript, Grid rasterRoot, EditorViewModel model, List<string> checks)
    {
        var evidence = new List<object>();
        foreach (var scale in new[] { 1.0, 1.25, 1.5 })
        {
            transcript.RenderTransform = new ScaleTransform { ScaleX = scale, ScaleY = scale };
            rasterRoot.Width = 780 * scale; rasterRoot.Height = 300 * scale;
            rasterRoot.UpdateLayout();
            for (var index = 0; index < model.Words.Count; index++)
            {
                model.Select(index);
                model.SourceTime = -1;
                transcript.RefreshVisuals();
                _ = await RasterAsync(rasterRoot);
                transcript.DebugGlyphOnly(index);
                await FrameAsync();
                var glyph = await RasterAsync(rasterRoot);
                if (index == 0) await SaveAsync(glyph, $"{transcript.ActualTheme}-{scale:0.##}-glyph");
                var rectangle = transcript.DebugWordBounds(index) ?? throw new InvalidOperationException($"Alignment word {index} at {scale} is not realized.");
                transcript.DebugEndGlyph();
                var glyphBounds = PixelBounds(glyph, (blue, green, red) => green > red + 24 && green > blue + 24, $"word {index} glyph at {scale}");
                Require(Covers(Scaled(rectangle, scale), glyphBounds, 1), $"word {index} overlay rectangle does not cover glyph bounds within 1 px at {scale}");
                transcript.RefreshVisuals();
                await FrameAsync();
                transcript.DebugHideGlyphs();
                var selected = await RasterAsync(rasterRoot);
                var selectionColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcSelectionTranscriptBrush")).Color;
                var selectionBounds = FillBounds(selected, selectionColor, Scaled(rectangle, scale), $"word {index} selection at {scale}");
                Require(Covers(selectionBounds, glyphBounds, 1), $"word {index} selection {selectionBounds} does not cover glyphs {glyphBounds} within 1 px at {scale}");
                Require(Math.Abs(selectionBounds.Left - rectangle.Left * scale) <= 1 && Math.Abs(selectionBounds.Right - rectangle.Right * scale) <= 1,
                    $"word {index} selection {selectionBounds} is offset from native word geometry {rectangle} at {scale}");
                transcript.DebugEndGlyph();
                model.SourceTime = model.Words[index].Start;
                transcript.RefreshVisuals();
                await FrameAsync();
                transcript.DebugHideGlyphs();
                var playing = await RasterAsync(rasterRoot);
                var playingColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcWordPlayingBackgroundBrush")).Color;
                var playingBounds = FillBounds(playing, playingColor, Scaled(rectangle, scale), $"word {index} playing at {scale}");
                Require(Covers(playingBounds, glyphBounds, 1), $"word {index} playing fill does not cover glyphs within 1 px at {scale}");
                Require(Math.Abs(playingBounds.Left - (rectangle.Left - 2) * scale) <= 1 && Math.Abs(playingBounds.Right - (rectangle.Right + 2) * scale) <= 1,
                    $"word {index} playing fill {playingBounds} is offset from native word geometry {rectangle} at {scale}");
                evidence.Add(new { Word = model.Words[index].Text, scale, rectangle, glyphBounds, selectionBounds, playingBounds });
                transcript.DebugEndGlyph();
            }
            checks.Add($"{transcript.ActualTheme} transcript at {scale * 100:0}%: every word overlay, selection and playing fill covers independently rasterized glyph bounds within 1 px");
        }
        if (Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") is { Length: > 0 } directory)
            await File.WriteAllTextAsync(Path.Combine(directory, $"transcript-{transcript.ActualTheme}-alignment.json"),
                JsonSerializer.Serialize(new { NativeScale = transcript.XamlRoot.RasterizationScale, ScaledRender = true, Words = evidence }, new JsonSerializerOptions { WriteIndented = true }));
    }
    private sealed record Raster(byte[] Pixels, int Width, int Height);
    private static async Task<Raster> RasterAsync(Grid rasterRoot)
    {
        await Task.Delay(40);
        rasterRoot.UpdateLayout();
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(rasterRoot);
        return new((await bitmap.GetPixelsAsync()).ToArray(), bitmap.PixelWidth, bitmap.PixelHeight);
    }
    private static async Task SaveAsync(Raster raster, string name)
    {
        if (Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") is not { Length: > 0 } output) return;
        using var stream = File.Create(Path.Combine(output, "alignment-" + name + ".png"));
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
            (uint)raster.Width, (uint)raster.Height, 96, 96, raster.Pixels);
        await encoder.FlushAsync();
    }
    private static Rect PixelBounds(Raster raster, Func<int, int, int, bool> match, string label)
    {
        var left = raster.Width; var right = -1; var top = raster.Height; var bottom = -1;
        for (var row = 0; row < raster.Height; row++)
            for (var column = 0; column < raster.Width; column++)
            {
                var offset = (row * raster.Width + column) * 4;
                if (!match(raster.Pixels[offset], raster.Pixels[offset + 1], raster.Pixels[offset + 2])) continue;
                left = Math.Min(left, column); right = Math.Max(right, column); top = Math.Min(top, row); bottom = Math.Max(bottom, row);
            }
        Require(right >= left && bottom >= top, $"Alignment raster has no matching pixels: {label}.");
        return new(left, top, right - left + 1, bottom - top + 1);
    }
    private static Rect Scaled(Rect rectangle, double scale) => new(rectangle.X * scale, rectangle.Y * scale, rectangle.Width * scale, rectangle.Height * scale);
    private static Rect FillBounds(Raster raster, Windows.UI.Color color, Rect word, string label)
    {
        var visited = new bool[raster.Width * raster.Height];
        var pending = new Queue<int>();
        var best = new Rect();
        var bestCount = 0;
        for (var pixel = 0; pixel < visited.Length; pixel++)
        {
            if (visited[pixel] || !Matches(pixel)) continue;
            pending.Enqueue(pixel); visited[pixel] = true;
            var left = raster.Width; var right = -1; var top = raster.Height; var bottom = -1; var count = 0;
            while (pending.TryDequeue(out var current))
            {
                var column = current % raster.Width; var row = current / raster.Width;
                left = Math.Min(left, column); right = Math.Max(right, column); top = Math.Min(top, row); bottom = Math.Max(bottom, row); count++;
                if (column > 0) Add(current - 1);
                if (column + 1 < raster.Width) Add(current + 1);
                if (row > 0) Add(current - raster.Width);
                if (row + 1 < raster.Height) Add(current + raster.Width);
            }
            var bounds = new Rect(left, top, right - left + 1, bottom - top + 1);
            if (bounds.Left < word.Right && bounds.Right > word.Left && bounds.Top < word.Bottom && bounds.Bottom > word.Top && count > bestCount)
            { best = bounds; bestCount = count; }
        }
        Require(bestCount > 0, "Alignment raster has no matching fill component: " + label);
        return best;
        bool Matches(int pixel) => Match(raster.Pixels[pixel * 4], raster.Pixels[pixel * 4 + 1], raster.Pixels[pixel * 4 + 2], color);
        void Add(int pixel)
        {
            if (visited[pixel]) return;
            visited[pixel] = true;
            if (Matches(pixel)) pending.Enqueue(pixel);
        }
    }
    private static bool Covers(Rect outer, Rect inner, double tolerance) => outer.Left <= inner.Left + tolerance && outer.Top <= inner.Top + tolerance
        && outer.Right >= inner.Right - tolerance && outer.Bottom >= inner.Bottom - tolerance;
    private static bool Match(int blue, int green, int red, Windows.UI.Color color) => Math.Abs(blue - color.B) <= 3 && Math.Abs(green - color.G) <= 3 && Math.Abs(red - color.R) <= 3;
    private static async Task FrameAsync()
    {
        await Task.Yield();
    }
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
#endif
