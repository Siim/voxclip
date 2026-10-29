using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using System.ComponentModel;
using System.Text.Json.Nodes;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Controls;

internal sealed class CaptionsPanel : UserControl
{
    private readonly EditorViewModel model;
    private readonly CancellationToken ct;
    private readonly Func<string?> mediaPath;
    private bool readingFrame;
    private long lastFrameRead;
    private string frameKey = "";
    private string frameContext = "";
    private readonly Grid body = new() { RowSpacing = 8, Padding = new Thickness(16, 12, 16, 8) };
    private readonly InfoBar notice = Ui.Notice();
    private readonly Dictionary<string, Tile> tiles = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim tileJobs = new(1, 1);
    private readonly GridView gallery = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = false };
    private readonly ToggleSwitch enabled = new() { OnContent = "", OffContent = "", HorizontalAlignment = HorizontalAlignment.Right };
    private readonly Expander fineTune = new() { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock styleName = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock summary = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly Image chip = new() { Width = 64, Height = 36, Stretch = Stretch.Fill };
    private readonly TextBlock off = new() { Text = "Off", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private string fineTuneKey = "";
    private string fineTuneShape = "";
    private Action? syncFineTune;
    private readonly HashSet<Tile> visible = [];
    private string? rememberedStyle;
    private string? scope = "<initial>";
    private double tileWidth = 140;
    private CaptionGalleryRenderer? renderer;
    private CaptionGalleryViewModel? samples;
    private PixelBuffer? still;
    private bool loading;
    private bool syncing;
    private double playhead;
    internal IReadOnlyList<CaptionStyle> Styles { get; private set; } = [];
    internal Control FocusTarget
    {
        get
        {
            if (gallery.IsEnabled && gallery.ActualHeight > 0 && gallery.SelectedItem is { } selected)
            {
                gallery.ScrollIntoView(selected, ScrollIntoViewAlignment.Leading);
                gallery.UpdateLayout();
                if (gallery.ContainerFromItem(selected) is Control target &&
                    !Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.CreatePeerForElement(target).IsOffscreen()) return target;
            }
            return enabled;
        }
    }
    private sealed class Tile(CaptionStyle style) : INotifyPropertyChanged
    {
        internal CaptionStyle Style { get; } = style;
        internal LatestTileRender Request { get; } = new();
        internal string SampleKey { get; set; } = "";
        public string Name => Style.Name;
        public string Description => Style.Name + ": " + Style.Description;
        private ImageSource? bitmap;
        public ImageSource? Bitmap { get => bitmap; set { bitmap = value; PropertyChanged?.Invoke(this, new(nameof(Bitmap))); } }
        private Visibility selected = Visibility.Collapsed;
        public Visibility Selected { get => selected; set { selected = value; PropertyChanged?.Invoke(this, new(nameof(Selected))); } }
        public event PropertyChangedEventHandler? PropertyChanged;
    }

    private sealed record Group(string Name, IReadOnlyList<Tile> Items);

    internal CaptionsPanel(EditorViewModel model, Func<string?> mediaPath, CancellationToken ct)
    {
        this.model = model;
        this.mediaPath = mediaPath;
        this.ct = ct;
        IsTabStop = false;
        AutomationProperties.SetAutomationId(enabled, "Captions.Toggle");
        AutomationProperties.SetAutomationId(styleName, "Captions.StyleName");
        AutomationProperties.SetAutomationId(summary, "Captions.Summary");
        AutomationProperties.SetAutomationId(gallery, "Captions.Gallery");
        gallery.UseSystemFocusVisuals = true;
        Content = body;
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = GridLength.Auto });
        body.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        ActualThemeChanged += (_, _) => { summary.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush"); RenderVisible(true); };
        Loaded += (_, _) => Ui.EffectsChanged += EffectsChanged;
        Unloaded += (_, _) => Ui.EffectsChanged -= EffectsChanged;
        model.Changed += ModelChanged;
        model.PropertyChanged += ModelPropertyChanged;
    }
    private void EffectsChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() =>
    {
        summary.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush"); RenderVisible(true);
    });

    internal async Task InitializeAsync()
    {
        await Ui.RunAsync(notice, async () => Styles = await App.Services.ReadStylesAsync(ct), "Captions");
        if (App.Services.SharedRoot is { } root)
        {
            renderer = new(root);
            samples = new(model, renderer.Resources, () => App.Services.ShowPlaceholderWords);
            samples.Changed += (_, _) => RenderVisible(true);
        }
        loading = !model.IsReadOnly && model.Project.Media.Source.Video is not null;
        RenderCaptions();
    }

    internal void UpdateStill(PixelBuffer frame)
    {
        if (frame.Width <= 0 || frame.Height <= 0) return;
        still = frame;
        loading = false;
        RenderVisible(true);
    }

    internal void UpdatePosition(double editedTime, double sourceTime)
    {
        playhead = editedTime;
        RenderVisible(false);
        var next = $"{mediaPath()}:{model.Project.Media.Source.ContentKey}:{model.Project.Export.Aspect}:{model.Project.Edits.ActiveClipId}:{Math.Floor(sourceTime * 4)}";
        if (!model.IsReadOnly && mediaPath() is { } path && !readingFrame && Environment.TickCount64 - lastFrameRead >= 250 && next != frameKey)
        {
            frameKey = next;
            _ = ReadFrameAsync(path, sourceTime);
        }
    }

    private async Task ReadFrameAsync(string path, double time)
    {
        readingFrame = true;
        lastFrameRead = Environment.TickCount64;
        var project = model.Project;
        try
        {
            var frame = await CaptionGalleryFrames.ReadAsync(project, path, time, ct);
            if (ct.IsCancellationRequested || model.IsReadOnly || mediaPath() != path || model.Project.Media.Source.ContentKey != project.Media.Source.ContentKey || model.Project.Export.Aspect != project.Export.Aspect || model.Project.Edits.ActiveClipId != project.Edits.ActiveClipId) return;
            still = frame;
            loading = false;
            RenderVisible(true);
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            if (mediaPath() != path || model.Project.Media.Source.ContentKey != project.Media.Source.ContentKey || model.Project.Export.Aspect != project.Export.Aspect || model.Project.Edits.ActiveClipId != project.Edits.ActiveClipId) return;
            still = null; loading = false; RenderVisible(true);
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "captions", $"action=GalleryFrame code={exception.GetType().Name}");
        }
        finally { readingFrame = false; }
    }

    internal void MediaUnavailable()
    {
        still = null;
        loading = false;
        ModelChanged(this, EventArgs.Empty);
        RenderVisible(true);
    }

    private void RenderCaptions()
    {
        foreach (var tile in tiles.Values) tile.Request.Dispose();
        tiles.Clear();
        body.Children.Clear();
        body.Children.Add(notice);
        var header = new Grid { Height = 36 };
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = "Captions", VerticalAlignment = VerticalAlignment.Center, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        Grid.SetColumn(enabled, 1); header.Children.Add(enabled);
        AutomationProperties.SetName(enabled, "Show captions");
        enabled.Toggled += (_, _) =>
        {
            if (syncing) return;
            if (!enabled.IsOn) { rememberedStyle = model.Project.Captions.StyleId; model.SetCaptionStyle("off"); }
            else model.SetCaptionStyle(CaptionFineTune.TurnOn(rememberedStyle, App.Services.Get("captions.defaultStyleId", "vox-highlight")));
        };
        Grid.SetRow(header, 1); body.Children.Add(header);
        var styleRow = new Grid { ColumnSpacing = 8 };
        styleRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        styleRow.ColumnDefinitions.Add(new());
        var chipContent = new Grid(); chipContent.Children.Add(chip); chipContent.Children.Add(off);
        styleRow.Children.Add(new Border { CornerRadius = new(6), Background = Ui.ThemeBrush(this, "VcBgMutedBrush"), Child = chipContent });
        var labels = Ui.Stack(2); labels.Children.Add(styleName); labels.Children.Add(summary);
        labels.Children.Add(new TextBlock { Text = "Fine tune", FontSize = 12, TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(labels, 1); styleRow.Children.Add(labels);
        fineTune.Header = styleRow;
        Grid.SetRow(fineTune, 2); body.Children.Add(fineTune);
        gallery.ItemsPanel = (ItemsPanelTemplate)XamlReader.Load("<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ItemsWrapGrid Orientation='Horizontal' MaximumRowsOrColumns='2'/></ItemsPanelTemplate>");
        gallery.ItemTemplate = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><StackPanel Spacing='4' AutomationProperties.Name='{Binding Description}'><Grid><Border CornerRadius='10' Background='{ThemeResource VcStageBrush}'><Image Source='{Binding Bitmap}' Stretch='Fill'/></Border><Border Visibility='{Binding Selected}' Margin='-2' BorderBrush='{ThemeResource VcAccentTextBrush}' BorderThickness='2' CornerRadius='12'/><Border Visibility='{Binding Selected}' Width='18' Height='18' CornerRadius='9' Background='{ThemeResource VcChipMediaBackgroundBrush}' HorizontalAlignment='Right' VerticalAlignment='Top' Margin='6'><FontIcon Glyph='&#xE73E;' FontSize='10' Foreground='{ThemeResource VcChipMediaForegroundBrush}'/></Border></Grid><TextBlock Text='{Binding Name}' FontSize='12' Foreground='{ThemeResource VcTextSecondaryBrush}' TextTrimming='CharacterEllipsis'/></StackPanel></DataTemplate>");
        gallery.GroupStyle.Add(new GroupStyle { HeaderTemplate = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><TextBlock Text='{Binding Name}' FontSize='11' FontWeight='SemiBold' Foreground='{ThemeResource VcTextSecondaryBrush}' Margin='4,12,0,4'/></DataTemplate>") });
        var itemStyle = new Style(typeof(GridViewItem));
        gallery.Padding = new Thickness(0);
        itemStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        itemStyle.Setters.Add(new Setter(Control.MarginProperty, new Thickness(0, 0, 0, 2)));
        itemStyle.Setters.Add(new Setter(Control.MinWidthProperty, 0.0));
        gallery.Resources["GridViewItemSelectionCheckMarkVisualEnabled"] = false;
        var clear = ((SolidColorBrush)Ui.ThemeBrush(this, "VcBgSurfaceBrush")).Color; clear.A = 0;
        gallery.Resources["GridViewItemBackgroundSelected"] = new SolidColorBrush(clear);
        gallery.Resources["GridViewItemBackgroundSelectedPointerOver"] = Ui.ThemeBrush(this, "VcBgMutedBrush");
        itemStyle.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        gallery.ItemContainerStyle = itemStyle;
        AutomationProperties.SetName(gallery, "Caption style");
        foreach (var style in Styles)
        {
            if (style.Id != "off") tiles.Add(style.Id, new(style));
        }
        var groups = tiles.Values.GroupBy(tile => CaptionFineTune.Group(tile.Style)).OrderBy(group => CaptionFineTune.GroupOrder(group.Key))
            .Select(group => new Group(group.Key, group.OrderBy(tile => tile.Style.Order).ToArray())).ToArray();
        var source = new CollectionViewSource { IsSourceGrouped = true, ItemsPath = new PropertyPath("Items"), Source = groups };
        gallery.ItemsSource = source.View;
        gallery.SelectionChanged += (_, _) => { if (!syncing && gallery.SelectedItem is Tile tile) model.SetCaptionStyle(tile.Style.Id); };
        gallery.ContainerContentChanging += (sender, args) =>
        {
            if (args.Item is not Tile tile) return;
            if (args.InRecycleQueue) { visible.Remove(tile); tile.Request.Dispose(); return; }
            visible.Add(tile);
            AutomationProperties.SetAutomationId(args.ItemContainer, "CaptionStyle." + tile.Style.Id);
            AutomationProperties.SetName(args.ItemContainer, tile.Description);
            SizeTile(args.ItemContainer);
            _ = RenderTileAsync(tile, true);
        };
        gallery.SizeChanged += (_, _) => SizeTiles();
        Grid.SetRow(gallery, 3); body.Children.Add(gallery);
        ModelChanged(this, EventArgs.Empty);
    }

    private void SizeTile(SelectorItem item)
    {
        if (item.ContentTemplateRoot is not StackPanel panel || panel.Children[0] is not Grid image) return;
        panel.Width = tileWidth;
        image.Height = Math.Round(tileWidth * 0.45);
        if (item.Content is Tile tile && panel.Children[1] is TextBlock name)
        {
            var order = Styles.Where(style => CaptionFineTune.Group(style) == CaptionFineTune.Group(tile.Style)).OrderBy(style => style.Order).ToList().FindIndex(style => style.Id == tile.Style.Id);
            panel.Margin = order % 2 == 0 ? new Thickness(0, 0, 4, 0) : new Thickness(4, 0, 0, 0);
            var selected = tile.Style.Id == model.Project.Captions.StyleId;
            name.Text = tile.Style.Name + (selected && CaptionFineTune.Edited(model.Project) ? " · Edited" : "");
            name.FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
            name.Foreground = Ui.ThemeBrush(this, selected ? "VcTextPrimaryBrush" : "VcTextSecondaryBrush");
        }
    }

    private void SizeTiles()
    {
        tileWidth = CaptionFineTune.TileWidth(gallery.ActualWidth);
        if (gallery.ItemsPanelRoot is ItemsWrapGrid panel) panel.ItemWidth = (gallery.ActualWidth > 8 ? gallery.ActualWidth : 8) / 2;
        foreach (var tile in visible)
            if (gallery.ContainerFromItem(tile) is SelectorItem container) SizeTile(container);
        RenderVisible(true);
    }

    private void RenderVisible(bool force)
    {
        foreach (var tile in visible.ToArray()) _ = RenderTileAsync(tile, force);
        if (tiles.TryGetValue(model.Project.Captions.StyleId, out var selected) && !visible.Contains(selected)) _ = RenderTileAsync(selected, force);
    }

    private async Task RenderTileAsync(Tile tile, bool force)
    {
        if (renderer is null || samples is null) return;
        var sample = samples.Sample(tile.Style, playhead);
        var key = sample.Time.ToString("R", System.Globalization.CultureInfo.InvariantCulture) + string.Join("|", sample.Words.Select(word => word.Id + word.Text));
        if (!force && tile.SampleKey == key) return;
        tile.SampleKey = key;
        var project = model.Project;
        var frame = still;
        var isLoading = loading;
        var stage = ((SolidColorBrush)Ui.ThemeBrush(this, "VcStageBrush")).Color;
        var width = Math.Max(1, (int)Math.Round(tileWidth));
        var height = Math.Max(1, (int)Math.Round(tileWidth * 0.45));
        try
        {
            await tile.Request.RunAsync(async token =>
            {
                await tileJobs.WaitAsync(token);
                try { return await Task.Run(() => renderer.RenderAsync(project, tile.Style, sample, frame, isLoading, width, height, (stage.B, stage.G, stage.R), token), token); }
                finally { tileJobs.Release(); }
            }, pixels =>
            {
                var image = new WriteableBitmap(pixels.Width, pixels.Height);
                using (var stream = image.PixelBuffer.AsStream()) stream.Write(pixels.Pixels);
                image.Invalidate();
                tile.Bitmap = image;
                if (tile.Style.Id == model.Project.Captions.StyleId) chip.Source = image;
            }, ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "captions", $"action=Gallery code={exception.GetType().Name}"); }
    }

    private void ModelPropertyChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(EditorViewModel.IsReadOnly) or nameof(EditorViewModel.Busy)) ModelChanged(sender, EventArgs.Empty);
    }
    private void ModelChanged(object? sender, EventArgs args)
    {
        syncing = true;
        try
        {
            var project = model.Project;
            var context = $"{mediaPath()}:{project.Media.Source.ContentKey}:{project.Export.Aspect}:{project.Edits.ActiveClipId}";
            if (frameContext != context)
            {
                frameContext = context; frameKey = ""; still = null;
                loading = !model.IsReadOnly && mediaPath() is not null && project.Media.Source.Video is not null;
            }
            enabled.IsOn = project.Captions.StyleId != "off";
            enabled.IsEnabled = !model.IsReadOnly && !model.Busy;
            var selected = tiles.GetValueOrDefault(project.Captions.StyleId);
            gallery.SelectedItem = selected;
            foreach (var tile in tiles.Values) tile.Selected = tile == selected ? Visibility.Visible : Visibility.Collapsed;
            foreach (var tile in visible)
                if (gallery.ContainerFromItem(tile) is SelectorItem container) SizeTile(container);
            off.Visibility = enabled.IsOn ? Visibility.Collapsed : Visibility.Visible;
            chip.Source = selected?.Bitmap;
            styleName.Text = selected is null ? "Off" : selected.Style.Name + (CaptionFineTune.Edited(project) ? " · Edited" : "");
            summary.Text = selected is null ? "Just the video" : CaptionFineTune.Summary(selected.Style, project);
            summary.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush");
            styleName.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            fineTune.IsEnabled = selected is not null && !model.Busy;
            var shape = CaptionFineTune.Shape(project, model.IsReadOnly);
            var key = shape + "|" + CaptionFineTune.Preset(project) + "|" + System.Text.Json.JsonSerializer.Serialize(project.Captions) + "|" + model.Busy;
            if (key != fineTuneKey && selected is not null)
            {
                fineTuneKey = key;
                if (shape != fineTuneShape) { fineTuneShape = shape; BuildFineTune(selected.Style); }
                else syncFineTune?.Invoke();
            }
            if (scope != project.Edits.ActiveClipId)
            {
                scope = project.Edits.ActiveClipId;
                if (selected is not null) gallery.ScrollIntoView(selected, ScrollIntoViewAlignment.Leading);
            }
            gallery.IsEnabled = !model.IsReadOnly && !model.Busy;
        }
        finally { syncing = false; }
    }

    private void BuildFineTune(CaptionStyle style)
    {
        var controls = Ui.Stack(12);
        controls.Margin = new Thickness(0, 8, 0, 0);
        var initial = CaptionFineTune.Values(style, model.Project);
        var syncs = new List<Action<CaptionFineTune.FineTuneValues>>();
        void Options(string label, string[] choices, Func<CaptionFineTune.FineTuneValues, int> selected, Action<int> choose, bool available = true)
        {
            var section = Ui.Stack(4); section.Children.Add(Ui.Text(label));
            var segment = new CommunityToolkit.WinUI.Controls.Segmented { SelectedIndex = selected(initial), IsEnabled = available && (!model.IsReadOnly || label == "Position"), HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var choice in choices) segment.Items.Add(new CommunityToolkit.WinUI.Controls.SegmentedItem { Content = choice, MinWidth = 0, Padding = new(8, 4, 8, 4) });
            segment.SelectedIndex = selected(initial);
            AutomationProperties.SetName(segment, label);
            AutomationProperties.SetAutomationId(segment, "FineTune." + label);
            segment.SelectionChanged += (_, _) => { if (!syncing && segment.SelectedIndex >= 0) choose(segment.SelectedIndex); };
            syncs.Add(now => segment.SelectedIndex = selected(now));
            section.Children.Add(segment); controls.Children.Add(section);
        }
        void Change(string section, params (string Key, JsonNode? Value)[] values) => model.SetCaptionOverrides(CaptionFineTune.Change(model.Project.Captions, section, values));
        Options("Size", ["S", "M", "L", "XL"], now => now.Size,
            index => Change("font", ("sizeScale", index == 1 ? null : JsonValue.Create(new[] { 0.8, 1, 1.2, 1.45 }[index]))));
        Options("Case", ["As said", "ALL CAPS"], now => now.Case, index => Change("text", ("transform", JsonValue.Create(index == 0 ? "none" : "uppercase"))), style.Text.UserOverridable);
        Options("Words on screen", ["1", "Phrase", "Line"], now => now.Words,
            index => Change("layout", ("maxWords", index == 1 ? null : JsonValue.Create(index == 0 ? 1 : 16)), ("maxLines", index == 1 ? null : JsonValue.Create(1))));
        var punctuation = new ToggleSwitch { Header = "Keep punctuation", IsEnabled = style.Text.UserOverridable && !model.IsReadOnly, IsOn = initial.Punctuation };
        AutomationProperties.SetAutomationId(punctuation, "FineTune.Punctuation");
        punctuation.Toggled += (_, _) => { if (!syncing) Change("text", ("punctuation", JsonValue.Create(punctuation.IsOn ? "keep" : "strip-keep-numeric"))); };
        syncs.Add(now => punctuation.IsOn = now.Punctuation);
        controls.Children.Add(punctuation);
        if (style.Accent is not null)
        {
            controls.Children.Add(Ui.Text("Colour"));
            var swatches = new MeasuredRow { Gap = 6 };
            var firstColors = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var lastColors = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            swatches.Children.Add(firstColors); swatches.Children.Add(lastColors);
            foreach (var color in CaptionFineTune.Colors)
            {
                var rgb = Convert.ToUInt32(color.Value[1..], 16);
                var brush = new SolidColorBrush(Windows.UI.Color.FromArgb(byte.MaxValue, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
                var button = new Button { IsEnabled = !model.IsReadOnly, Width = 32, Height = 32, Padding = new Thickness(3), Content = new Border { Background = brush, Width = 18, Height = 18, CornerRadius = new(9) } };
                AutomationProperties.SetName(button, color.Name); ToolTipService.SetToolTip(button, color.Name);
                AutomationProperties.SetAutomationId(button, "FineTune.Colour." + color.Name);
                button.Click += (_, _) => Change("", ("accent", JsonValue.Create(color.Value)));
                (firstColors.Children.Count < 3 ? firstColors : lastColors).Children.Add(button);
            }
            controls.Children.Add(swatches);
        }
        Options("Position", ["Top", "Middle", "Bottom"], now => now.Position, model.MoveCaptionPosition, style.Position.UserDraggable);
        controls.Children.Add(Ui.Text("Drag captions on the video to move them.", "HelperText"));
        var reset = new HyperlinkButton { IsEnabled = !model.IsReadOnly, Content = "Reset to Style", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(0) };
        AutomationProperties.SetAutomationId(reset, "FineTune.Reset");
        reset.Click += (_, _) => model.SetCaptions(CaptionFineTune.Reset(model.Project.Captions));
        controls.Children.Add(reset);
        void Describe(CaptionFineTune.FineTuneValues now) => ToolTipService.SetToolTip(fineTune,
            $"Size {now.Scale:0.##}× · {CaptionFineTune.Summary(style, model.Project)} · Position {(now.Stored is { } stored ? $"{stored.X:0.##}, {stored.Y:0.##}" : "Bottom")}");
        Describe(initial); syncs.Add(Describe);
        syncFineTune = () => { var now = CaptionFineTune.Values(style, model.Project); foreach (var sync in syncs) sync(now); };
        fineTune.Content = new ScrollViewer { Content = controls, MaxHeight = 300, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    internal void RefreshSamples() => samples?.Refresh();

#if DEBUG
    internal IReadOnlyList<string> DebugFitGalleryIds()
    {
        var choices = new List<string>();
        if (gallery.ItemsPanelRoot is not ItemsWrapGrid panel || panel.FirstVisibleIndex < 0) return choices;
        for (var index = panel.FirstVisibleIndex; index <= panel.LastVisibleIndex; index++)
        {
            if (index >= gallery.Items.Count || gallery.Items[index] is not Tile tile) return [];
            choices.Add("CaptionStyle." + tile.Style.Id);
        }
        return choices;
    }

    internal void DebugFitRealizeGallery()
    {
        if (DebugFitGalleryIds().Count == 0 && tiles.Values.FirstOrDefault() is { } first)
        {
            gallery.ScrollIntoView(first, ScrollIntoViewAlignment.Leading);
            gallery.UpdateLayout();
        }
    }

    internal bool DebugFitRealizeChoice(string id)
    {
        var tile = tiles.Values.FirstOrDefault(item => "CaptionStyle." + item.Style.Id == id);
        if (tile is null) return false;
        gallery.ScrollIntoView(tile, ScrollIntoViewAlignment.Leading);
        gallery.UpdateLayout();
        return true;
    }

    internal async Task DebugFitStatesAsync(Func<string, Task> inspect)
    {
        var original = model.Project.Captions;
        var expanded = fineTune.IsExpanded;
        var message = notice.Message;
        try
        {
            await inspect("captions");
            model.SetCaptionStyle("vox-highlight");
            fineTune.IsExpanded = true;
            await inspect("fine-tune");
            fineTune.IsExpanded = false;
            model.SetCaptionStyle("off");
            await inspect("captions-off");
            notice.Message = "Couldn't load caption styles. Try again.";
            notice.IsOpen = true;
            await inspect("caption-error");
        }
        finally
        {
            notice.IsOpen = false; notice.Message = message;
            model.SetCaptions(original); fineTune.IsExpanded = expanded;
        }
    }
#endif

    internal void Detach()
    {
        model.PropertyChanged -= ModelPropertyChanged;
        model.Changed -= ModelChanged;
        samples?.Dispose();
        foreach (var tile in tiles.Values) tile.Request.Dispose();
    }
}
