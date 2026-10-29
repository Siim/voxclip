#if DEBUG
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace VoxClip.App.Services;

internal static class TranscriptNativeProbe
{
    internal static async Task RunAsync(MainWindow window, Project project, List<string> checks)
    {
        var failures = new List<Exception>();
        foreach (var theme in Ui.HighContrast ? new[] { ElementTheme.Default } : new[] { ElementTheme.Dark, ElementTheme.Light })
            try { await RunThemeAsync(window, project, checks, theme); }
            catch (Exception exception) { failures.Add(new InvalidOperationException(Name(theme) + " transcript", exception)); }
        if (failures.Count > 0) throw new AggregateException(failures);
    }
    private static string Name(ElementTheme theme) => Ui.HighContrast ? "HighContrast" : theme.ToString();
    private static async Task RunThemeAsync(MainWindow window, Project project, List<string> checks, ElementTheme theme)
    {
        var host = (Panel)window.Content;
        var transcript = new TranscriptView { Width = 780, Height = 300, HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top, RequestedTheme = theme };
        var rasterRoot = new Grid { Width = 1560, Height = 600, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        transcript.RenderTransform = new ScaleTransform { ScaleX = 2, ScaleY = 2 };
        rasterRoot.Children.Add(transcript);
        var model = new EditorViewModel(project with { Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [] } });
        model.Select(1); model.Select(5, true);
        Require(model.MakeClip() is not null, "transcript pixel fixture did not make a clip");
        model.Apply(new EditOperation.CutSelection([model.Words[1].Id, model.Words[2].Id, model.Words[5].Id]));
        model.Select(3); model.SourceTime = model.Words[4].Start;
        transcript.Attach(model);
        host.Children.Add(rasterRoot);
        try
        {
            transcript.Background = Ui.ThemeBrush(transcript, "VcBgSurfaceBrush");
            host.UpdateLayout();
            transcript.RefreshVisuals();
            await NextFrameAsync();
            host.UpdateLayout();
            transcript.RefreshVisuals();
            await NextFrameAsync();
            var cut = Bounds(transcript, 2);
            var outside = Bounds(transcript, 0);
            var selected = Bounds(transcript, 3);
            var playing = Bounds(transcript, 4);
            var bitmap = new RenderTargetBitmap();
            await bitmap.RenderAsync(rasterRoot);
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            if (Environment.GetEnvironmentVariable("VOXCLIP_UI_EVIDENCE_DIR") is { Length: > 0 } evidence)
            {
                Directory.CreateDirectory(evidence);
                await File.WriteAllTextAsync(Path.Combine(evidence, $"transcript-{Name(theme)}-geometry.json"),
                    System.Text.Json.JsonSerializer.Serialize(transcript.DebugGeometry, new System.Text.Json.JsonSerializerOptions { WriteIndented = true, IncludeFields = true }));
                using var stream = File.Create(Path.Combine(evidence, $"transcript-{Name(theme)}-raster.png"));
                var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
                encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                    (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
                await encoder.FlushAsync();
            }
            var selectionColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcSelectionTranscriptBrush")).Color;
            var playingColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcWordPlayingBackgroundBrush")).Color;
            Require(selectionColor != playingColor, "selection and playing fill tokens are equal");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, new(cut.X, cut.Y + cut.Height * 0.52 - 1, cut.Width, 3),
                ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcCutStrokeBrush")).Color), "cut strike pixels do not match cut.stroke within three levels");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, outside, ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcTextSecondaryBrush")).Color),
                "out-of-scope glyph pixels do not match text.secondary");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, selected, selectionColor), "selection fill pixels do not match selection.transcript");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, playing, playingColor), "playing fill pixels do not match word.playing.background");
            if (Ui.HighContrast)
            {
                var system = new UISettings();
                var highlight = system.UIElementColor(UIElementType.Highlight);
                var windowText = system.UIElementColor(UIElementType.WindowText);
                Require(SameColor(selectionColor, highlight), $"contrast-mode selection.transcript {selectionColor} is not the live Highlight {highlight}");
                Require(SameColor(playingColor, windowText), $"contrast-mode word.playing.background {playingColor} is not the live WindowText {windowText}");
                Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, selected, system.UIElementColor(UIElementType.HighlightText)),
                    "selected glyph pixels do not match the live HighlightText");
                Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, playing, system.UIElementColor(UIElementType.Window)),
                    "playing glyph pixels do not match the live Window colour");
            }
            foreach (var filler in new[] { 1, 5 })
            {
                var area = Bounds(transcript, filler);
                Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, new(area.X, area.Y + area.Height * 0.52 - 1, area.Width, 3),
                    ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcCutStrokeBrush")).Color), $"{model.Words[filler].Text} has no cut.stroke strike");
            }
            checks.Add(Ui.HighContrast
                ? $"High Contrast {Ui.HighContrastScheme} realized transcript raster: cut strike including um, and uh, out-of-scope glyph, Highlight selection and WindowText playing fills with their text matching the live system colours"
                : $"{theme} realized transcript raster: cut strike including um, and uh, out-of-scope glyph, distinct selection/playing fills and badge-aware highlight offsets");
            if (!Ui.HighContrast) await TranscriptAlignmentProbe.RunAsync(transcript, rasterRoot, model, checks);
        }
        finally { transcript.Detach(); host.Children.Remove(rasterRoot); }
    }
    private static Rect Bounds(TranscriptView transcript, int index) => transcript.DebugWordBounds(index)
        ?? throw new InvalidOperationException("Native transcript word was not realized.");
    private static bool SameColor(Windows.UI.Color left, Windows.UI.Color right) => left.R == right.R && left.G == right.G && left.B == right.B;
    private static bool Contains(byte[] pixels, int width, int height, Rect area, Windows.UI.Color color)
    {
        var left = Math.Clamp((int)Math.Floor(area.Left * 2), 0, width);
        var right = Math.Clamp((int)Math.Ceiling(area.Right * 2), 0, width);
        var top = Math.Clamp((int)Math.Floor(area.Top * 2), 0, height);
        var bottom = Math.Clamp((int)Math.Ceiling(area.Bottom * 2), 0, height);
        for (var row = top; row < bottom; row++)
            for (var column = left; column < right; column++)
            {
                var offset = (row * width + column) * 4;
                if (Math.Abs(pixels[offset] - color.B) <= 3 && Math.Abs(pixels[offset + 1] - color.G) <= 3 && Math.Abs(pixels[offset + 2] - color.R) <= 3) return true;
            }
        return false;
    }
    private static async Task NextFrameAsync()
    {
        var rendered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler<object>? handler = null;
        handler = (_, _) => { CompositionTarget.Rendering -= handler; rendered.TrySetResult(); };
        CompositionTarget.Rendering += handler;
        try { await rendered.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
        finally { CompositionTarget.Rendering -= handler; }
    }
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
#endif
