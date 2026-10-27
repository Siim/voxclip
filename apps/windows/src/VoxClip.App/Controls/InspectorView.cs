using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Captions;

namespace VoxClip.App.Controls;

/// <summary>The caption style gallery. Clips live in the pane and Find clips in its flyout (design §3.4, §6.2).</summary>
internal sealed class InspectorView : UserControl
{
    private readonly EditorViewModel model;
    private readonly CancellationToken ct;
    private readonly StackPanel body = Ui.Stack(16);
    private readonly InfoBar notice = Ui.Notice();
    private RadioButtons gallery = new();
    private bool syncing;
    private ImageSource? still;
    private readonly SemaphoreSlim tileJobs = new(1, 1);
    internal IReadOnlyList<CaptionStyle> Styles { get; private set; } = [];
    internal Control FocusTarget => gallery;

    internal InspectorView(EditorViewModel model, Func<EditState?, Task<ComposeSnapshot>> snapshot, CancellationToken ct)
    {
        this.model = model; this.ct = ct;
        IsTabStop = false;
        body.Children.Add(notice);
        Content = new Grid { Padding = new Thickness(16), Children = { new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled } } };
        model.Changed += ModelChanged;
    }
    internal async Task InitializeAsync()
    {
        await Ui.RunAsync(notice, async () => Styles = await App.Services.ReadStylesAsync(ct), "Inspector");
        RenderCaptions();
    }
    internal void UpdateStill(PixelBuffer frame)
    {
        if (still is not null || frame.Width <= 0 || frame.Height <= 0) return;
        const int width = 128, height = 80;
        var image = new WriteableBitmap(width, height);
        using (var target = image.PixelBuffer.AsStream())
        {
            var row = new byte[width * 4];
            for (var y = 0; y < height; y++)
            {
                var sourceY = y * frame.Height / height;
                for (var x = 0; x < width; x++)
                {
                    var sourceX = x * frame.Width / width;
                    var offset = sourceY * frame.Stride + sourceX * 4;
                    for (var channel = 0; channel < 3; channel++) row[x * 4 + channel] = (byte)(frame.Pixels.Span[offset + channel] * 0.85);
                    row[x * 4 + 3] = 255;
                }
                target.Write(row);
            }
        }
        image.Invalidate(); still = image;
        RenderCaptions();
    }
    private void RenderCaptions()
    {
        while (body.Children.Count > 1) body.Children.RemoveAt(1);
        body.Children.Add(Ui.Text("Caption style", "SubtitleTextBlockStyle"));
        body.Children.Add(Ui.Text("Burned into the video at export. Your source stays untouched.", "HelperText"));
        gallery = new RadioButtons { MaxColumns = 2 };
        AutomationProperties.SetName(gallery, "Caption style");
        void AddStyle(string id, string name, CaptionStyle? style)
        {
            var tile = Ui.Stack(4);
            var preview = new Grid { Width = 128, Height = 80, Background = Ui.ThemeBrush(this, "VcBgMutedBrush") };
            if (still is not null) preview.Children.Add(new Image { Source = still, Stretch = Stretch.UniformToFill });
            if (style is not null) _ = RenderTileAsync(style, preview);
            tile.Children.Add(preview);
            tile.Children.Add(new TextBlock { Text = id == "off" ? "Off · Just the video" : name, TextWrapping = TextWrapping.Wrap, MaxWidth = 128 });
            var item = new RadioButton { Content = tile, Tag = id, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetName(item, id == "off" ? "Off, just the video" : name);
            gallery.Items.Add(item);
        }
        AddStyle("off", "Off", null);
        foreach (var style in Styles) AddStyle(style.Id, style.Name, style);
        gallery.SelectedItem = gallery.Items.OfType<RadioButton>().FirstOrDefault(item => (string)item.Tag == model.Project.Captions.StyleId);
        var shown = gallery;
        shown.SelectionChanged += (_, _) => { if (!syncing && shown.SelectedItem is RadioButton item) model.SetCaptionStyle((string)item.Tag); };
        body.Children.Add(gallery);
        if (Styles.Count == 0) Ui.Show(notice, "Caption styles aren't available. Your media and edits are still here.", InfoBarSeverity.Warning);
    }
    private async Task RenderTileAsync(CaptionStyle style, Grid tile)
    {
        try
        {
            if (App.Services.SharedRoot is not { } root) return;
            var words = style.Preview.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Select((word, index) => new CaptionWord($"preview-{index}", word, index * 0.4, index * 0.4 + 0.35)).ToArray();
            var sampleTime = style.Preview.ActiveWord * 0.4 + Math.Min(style.Preview.Progress, 0.98) * 0.35;
            await tileJobs.WaitAsync(ct);
            PixelBuffer overlay;
            try
            {
                overlay = await Task.Run(async () =>
                {
                    var tileCaptions = new ProjectCaptions(style.Id, System.Text.Json.JsonSerializer.SerializeToElement(new Dictionary<string, object>()), null, new Dictionary<string, CaptionPosition>());
                    var track = await CaptionEngine.BuildAsync(new(style, tileCaptions, new(1280, 800), words,
                        "en", words.Length * 0.4 + 0.5), new HarfBuzzGlyphShaper(root), null, ct);
                    return await new SkiaCaptionRasterizer(root).RenderAsync(new(track, sampleTime, ReduceMotion: true, Scale: 0.1), ct);
                }, ct);
            }
            finally { tileJobs.Release(); }
            if (overlay.Width != 128 || overlay.Height != 80) throw new InvalidDataException("Caption tile size is invalid.");
            var image = new WriteableBitmap(128, 80);
            using (var stream = image.PixelBuffer.AsStream()) stream.Write(overlay.Pixels.Span);
            image.Invalidate();
            tile.Children.Add(new Image { Source = image, Stretch = Stretch.Fill });
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { Ui.Show(notice, UiError.Message(exception, "Caption preview"), InfoBarSeverity.Warning); }
    }
    /// <summary>Undo and redo can change the style; the gallery follows without adding an edit of its own.</summary>
    private void ModelChanged(object? sender, EventArgs args)
    {
        var current = gallery.Items.OfType<RadioButton>().FirstOrDefault(item => (string)item.Tag == model.Project.Captions.StyleId);
        if (ReferenceEquals(gallery.SelectedItem, current)) return;
        syncing = true;
        try { gallery.SelectedItem = current; }
        finally { syncing = false; }
    }
    internal void Detach() => model.Changed -= ModelChanged;
}
