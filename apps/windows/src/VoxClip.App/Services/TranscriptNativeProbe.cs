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

namespace VoxClip.App.Services;

internal static class TranscriptNativeProbe
{
    internal static async Task RunAsync(MainWindow window, Project project, List<string> checks)
    {
        if (Ui.HighContrast) { checks.Add("transcript pixel gate requires a normal theme; contrast-mode tokens intentionally share selection/playing fills"); return; }
        var host = (Panel)window.Content;
        var transcript = new TranscriptView { Width = 780, Height = 300, HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top, RequestedTheme = ElementTheme.Dark };
        var model = new EditorViewModel(project with { Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [] } });
        model.Select(1); model.Select(5, true);
        Require(model.MakeClip() is not null, "transcript pixel fixture did not make a clip");
        model.Apply(new EditOperation.CutSelection([model.Words[2].Id]));
        model.Select(3); model.SourceTime = model.Words[4].Start;
        transcript.Attach(model);
        host.Children.Add(transcript);
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
            await bitmap.RenderAsync(transcript, 1560, 600);
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            var selectionColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcSelectionTranscriptBrush")).Color;
            var playingColor = ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcWordPlayingBackgroundBrush")).Color;
            Require(selectionColor != playingColor, "normal-theme selection and playing fill tokens are equal");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, new(cut.X, cut.Y + cut.Height * 0.52 - 1, cut.Width, 3),
                ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcCutStrokeBrush")).Color), "cut strike pixels do not match cut.stroke within three levels");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, outside, ((SolidColorBrush)Ui.ThemeBrush(transcript, "VcTextSecondaryBrush")).Color),
                "out-of-scope glyph pixels do not match text.secondary");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, selected, selectionColor), "selection fill pixels do not match selection.transcript");
            Require(Contains(pixels, bitmap.PixelWidth, bitmap.PixelHeight, playing, playingColor), "playing fill pixels do not match word.playing.background");
            checks.Add("realized transcript raster: cut strike, out-of-scope glyph, distinct selection/playing fills and badge-aware highlight offsets");
        }
        finally { transcript.Detach(); host.Children.Remove(transcript); }
    }
    private static Rect Bounds(TranscriptView transcript, int index) => transcript.DebugWordBounds(index)
        ?? throw new InvalidOperationException("Native transcript word was not realized.");
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
