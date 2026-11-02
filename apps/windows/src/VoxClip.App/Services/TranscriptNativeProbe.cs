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
        transcript.SetDisplay(true, true);
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
            var caret = transcript.DebugPlayheadBounds ?? throw new InvalidOperationException("Native source playhead caret was not realized.");
            Require(Math.Abs(caret.Width - 2) <= 0.01, "source playhead is not two epx wide");
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
            var selectionColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, Ui.HighContrast ? "VcSelectionTranscriptBrush" : "VcTintSelectionBrush")).Color;
            selectionColor = Composite(selectionColor, ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcBgSurfaceBrush")).Color);
            var caretColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcAccentTextBrush")).Color;
            Require(selectionColor != caretColor, "selection fill and source playhead tokens are equal");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, new(cut.X, cut.Y + cut.Height * 0.52 - 1, cut.Width, 3),
                ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcWordGoneBrush")).Color), "cut strike pixels do not match cut.stroke within three levels");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, outside, ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcWordOutsideBrush")).Color),
                "out-of-scope glyph pixels do not match word.outside");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, selected, selectionColor), "selection fill pixels do not match selection.transcript");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, caret, caretColor), "source playhead pixels do not match accent.text");
            if (Ui.HighContrast)
            {
                var system = new UISettings();
                var highlight = system.UIElementColor(UIElementType.Highlight);

                Require(SameColor(selectionColor, highlight), $"contrast-mode selection.transcript {selectionColor} is not the live Highlight {highlight}");
                Require(SameColor(caretColor, highlight), $"contrast-mode source playhead {caretColor} is not the live Highlight {highlight}");
                Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, selected, system.UIElementColor(UIElementType.HighlightText)),
                    "selected glyph pixels do not match the live HighlightText");
            }
            foreach (var filler in new[] { 1, 5 })
            {
                var area = Bounds(transcript, filler);
                Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, new(area.X, area.Y + area.Height * 0.52 - 1, area.Width, 3),
                    ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcWordGoneBrush")).Color), $"{model.Words[filler].Text} has no cut.stroke strike");
            }
            transcript.DebugHideGlyphs(retainDecorations: true);
            await NextFrameAsync();
            await bitmap.RenderAsync(rasterRoot);
            var decorationPixels = (await bitmap.GetPixelsAsync()).ToArray();
            var strikeColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcWordGoneBrush")).Color;
            void CheckStrikes(byte[] sample)
            {
                foreach (var index in new[] { 1, 2, 5 })
                {
                    var area = Bounds(transcript, index);
                    Require(Contains(sample, bitmap.PixelWidth, bitmap.PixelHeight,
                        new(area.X, area.Y + area.Height * 0.52 - 1, area.Width, 3), strikeColor),
                        $"Isolated cut strike is absent for {model.Words[index].Text}");
                }
            }
            void CheckCaret(byte[] sample) => Require(Contains(sample, bitmap.PixelWidth, bitmap.PixelHeight, caret, caretColor),
                "Isolated source playhead caret is absent");
            CheckStrikes(decorationPixels);
            CheckCaret(decorationPixels);
            foreach (var strikeMutation in new[] { true, false })
            {
                // Deliberately break the actual painted visual, then require the
                // very same positive assertion to reject it. Restore after each.
                transcript.DebugRemovePaint(strikeMutation);
                await NextFrameAsync();
                await bitmap.RenderAsync(rasterRoot);
                var broken = (await bitmap.GetPixelsAsync()).ToArray();
                var rejected = false;
                try { if (strikeMutation) CheckStrikes(broken); else CheckCaret(broken); }
                catch (InvalidOperationException) { rejected = true; }
                Require(rejected, "Decoration assertion accepted deliberately missing " + (strikeMutation ? "strike" : "source playhead caret"));
                transcript.DebugEndGlyph();
                await NextFrameAsync();
                transcript.DebugHideGlyphs(retainDecorations: true);
                await NextFrameAsync();
                await bitmap.RenderAsync(rasterRoot);
                var restored = (await bitmap.GetPixelsAsync()).ToArray();
                CheckStrikes(restored); CheckCaret(restored);
                checks.Add($"{Name(theme)} isolated {(strikeMutation ? "cut strike" : "source playhead caret")}: missing-paint mutation rejected; restored paint passes");
            }
            transcript.DebugEndGlyph();
            checks.Add(Ui.HighContrast
                ? $"High Contrast {Ui.HighContrastScheme} realized transcript raster: cut strike including um, and uh, out-of-scope glyph, Highlight selection and source caret matching the live system colours"
                : $"{theme} realized transcript raster: cut strike including um, and uh, out-of-scope glyph, distinct selection and two-epx source caret at the realized word bounds");
            if (!Ui.HighContrast) await TranscriptAlignmentProbe.RunAsync(transcript, rasterRoot, model, checks);
        }
        finally { transcript.Detach(); host.Children.Remove(rasterRoot); }
    }
    private static Rect Bounds(TranscriptView transcript, int index) => transcript.DebugWordBounds(index)
        ?? throw new InvalidOperationException("Native transcript word was not realized.");
    private static Windows.UI.Color Composite(Windows.UI.Color foreground, Windows.UI.Color background)
    {
        var alpha = foreground.A / 255.0;
        return Windows.UI.Color.FromArgb(255, (byte)Math.Round(foreground.R * alpha + background.R * (1 - alpha)),
            (byte)Math.Round(foreground.G * alpha + background.G * (1 - alpha)), (byte)Math.Round(foreground.B * alpha + background.B * (1 - alpha)));
    }
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
