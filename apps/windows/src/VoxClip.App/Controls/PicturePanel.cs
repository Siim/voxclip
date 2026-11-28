using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using System.Runtime.InteropServices.WindowsRuntime;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Media.Pipeline;
using Windows.System;

namespace VoxClip.App.Controls;

/// <summary>The Picture tab (looks spec §3.7, mockup frame 4): a <see cref="ScrollViewer"/> with 16 epx padding holding Claude's line, the Look row with
/// Compare, Amount, the category chips, the look tiles of the clip's own frame, the Fine-tune fold with its four groups, the toning
/// row and Clear all color. Every control stays visible; a disabled one shows its reason on an inline tertiary line and as its
/// Narrator help. It renders <see cref="PicturePanelModel"/> and changes the project only through it.</summary>
internal sealed class PicturePanel : Grid
{
    private const double TileMinimum = 56;
    private const double TileGap = 6;

    private readonly EditorViewModel editor;
    private readonly StackPanel body = Ui.Stack(12);
    private readonly Grid claude = new() { ColumnSpacing = 8 };
    private readonly TextBlock claudeText = Ui.Text("");
    private readonly HyperlinkButton useIt = new() { Content = "Use it", Padding = new(0) };
    private readonly TextBlock lookValue = Ui.Text("", "BodyStrongTextBlockStyle");
    private readonly ToggleButton compare = new() { Content = "Compare", Padding = new(8, 2, 8, 2) };
    private readonly TextBlock compareWhy = Reason();
    private readonly Slider amount = new() { Minimum = 0, Maximum = 100, StepFrequency = 1, SmallChange = 1, LargeChange = 10 };
    private readonly TextBox amountBox = new() { Width = 64, TextAlignment = TextAlignment.Right };
    private readonly TextBlock amountWhy = Reason();
    private readonly FlowPanel chips = new() { Spacing = 6 };
    private readonly TextBlock previewNote = Reason();
    private readonly GridView tiles = new()
    {
        SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, Padding = new(0), IsSwipeEnabled = false,
    };
    private readonly Button fold = new() { HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new(0, 4, 0, 4), Background = null, BorderThickness = new(0) };
    private readonly HyperlinkButton backTo = new() { Padding = new(0) };
    private readonly TextBlock backToWhy = Reason();
    private readonly StackPanel fineTune = Ui.Stack(12);
    private readonly Dictionary<PictureGroupId, GroupRow> groups = [];
    private readonly Dictionary<PictureControl, SliderRow> sliders = [];
    private readonly Grid toning = new() { ColumnSpacing = 8 };
    private readonly TextBlock toningText = Ui.Text("");
    private readonly HyperlinkButton removeToning = new() { Content = "Remove", Padding = new(0) };
    private readonly StackPanel timed = Ui.Stack(4);
    private readonly HyperlinkButton clear = new() { Content = "Clear all color", Padding = new(0) };
    private readonly TextBlock clearWhy = Reason();
    private readonly TextBlock blocked = Reason();
    private readonly ScrollViewer scroller = new()
    {
        Padding = new(16), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hover;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer rest;
    private readonly Dictionary<string, ImageSource> thumbnails = new(StringComparer.Ordinal);
    private string? hovered;
    private string? thumbnailKey;
    private string tilesKey = "";
    private CancellationTokenSource? thumbnailWork;
    private bool syncing;
    private bool amountDragging;
    private bool compareByPointer;
    private bool shown;
    private string? block;

    /// <summary>The paused frame before the grade (<c>IPreviewEngine.StillBeforeGradeAsync</c>); null without a preview.</summary>
    internal Func<CancellationToken, Task<PixelBuffer>>? BeforeGrade { get; set; }
    /// <summary>Compare held down (true) or released (false); the page pauses playback for a hold and resumes after it.</summary>
    internal Func<bool, Task>? HoldCompare { get; set; }
    /// <summary>The looks test card (shared/looks/test-card.png), for tiles when the paused frame can't be read or the source is offline.</summary>
    internal Func<PixelBuffer?>? SamplePicture { get; set; }

    private PicturePanelModel Model => editor.Picture;

    internal Control FocusTarget => tiles.Items.Count > 0 ? tiles : compare;

    internal PicturePanel(EditorViewModel editor)
    {
        this.editor = editor;
        AutomationProperties.SetAutomationId(this, "Picture.Panel");
        AutomationProperties.SetName(this, "Picture");
        hover = DispatcherQueue.CreateTimer();
        hover.Interval = TimeSpan.FromMilliseconds(120);
        hover.IsRepeating = false;
        hover.Tick += (_, _) => { if (hovered is { } id) Model.PreviewLook(id); };
        rest = DispatcherQueue.CreateTimer();
        rest.Interval = TimeSpan.FromMilliseconds(500);
        rest.IsRepeating = false;
        rest.Tick += (_, _) => { thumbnailKey = null; _ = RefreshThumbnailsAsync(); };

        body.Children.Add(blocked);
        BuildClaude();
        BuildHeader();
        BuildChips();
        BuildTiles();
        BuildFineTune();
        body.Children.Add(timed);
        body.Children.Add(Stacked(clear, clearWhy));
        clear.Click += (_, _) => Model.Clear();
        AutomationProperties.SetAutomationId(clear, "Picture.Clear");
        scroller.Content = body;
        Children.Add(scroller);

        Model.Changed += ModelChanged;
        Model.Announced += Announced;
        editor.Changed += ModelChanged;
        Ui.EffectsChanged += EffectsChanged;
        LosingFocus += (_, args) => { if (args.NewFocusedElement is not DependencyObject next || !InputState.DescendsFrom(next, this)) EndCompareForFocus(); };
        Loaded += (_, _) => { shown = true; Model.Opened(); Render(); _ = RefreshThumbnailsAsync(); };
        Unloaded += (_, _) => { shown = false; hover.Stop(); rest.Stop(); thumbnailWork?.Cancel(); Model.EndPreview(); Model.EndCompare(); };
    }

    // MARK: Building

    private static TextBlock Reason()
    {
        var text = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        text.Foreground = (Brush)Application.Current.Resources["VcTextTertiaryBrush"];
        return text;
    }

    private static StackPanel Stacked(params UIElement[] children)
    {
        var stack = Ui.Stack(2);
        foreach (var child in children) stack.Children.Add(child);
        return stack;
    }

    private static TextBlock Label(string text)
    {
        var label = new TextBlock { Text = text, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Width = 64 };
        label.Foreground = (Brush)Application.Current.Resources["VcTextSecondaryBrush"];
        return label;
    }

    private void BuildClaude()
    {
        claude.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        claude.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        claudeText.FontSize = 12;
        claude.Children.Add(claudeText);
        Grid.SetColumn(useIt, 1); claude.Children.Add(useIt);
        useIt.VerticalAlignment = VerticalAlignment.Top;
        useIt.Click += (_, _) => Model.UseClaudeLook();
        AutomationProperties.SetAutomationId(useIt, "Picture.UseClaudesLook");
        AutomationProperties.SetName(useIt, "Use Claude's look");
        body.Children.Add(claude);
    }

    private void BuildHeader()
    {
        var look = new Grid { ColumnSpacing = 8 };
        look.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        look.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        look.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        look.Children.Add(Label("Look"));
        lookValue.TextTrimming = TextTrimming.CharacterEllipsis; lookValue.TextWrapping = TextWrapping.NoWrap; lookValue.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(lookValue, 1); look.Children.Add(lookValue);
        AutomationProperties.SetAutomationId(lookValue, "Picture.Look");
        Grid.SetColumn(compare, 2); look.Children.Add(compare);
        AutomationProperties.SetAutomationId(compare, "Picture.Compare");
        AutomationProperties.SetName(compare, PicturePanelModel.CompareName);
        ToolTipService.SetToolTip(compare, "Hold to compare with as filmed (\\)");
        // A press shows As filmed until release; a click without a press (Narrator's toggle, Enter) switches it.
        compare.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => { compareByPointer = true; _ = Hold(true); }), true);
        compare.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => _ = Hold(false)), true);
        compare.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => { if (compareByPointer) _ = Hold(false); }), true);
        compare.AddHandler(KeyDownEvent, new KeyEventHandler((_, args) =>
        {
            if (args.Key != VirtualKey.Space) return;
            if (!args.KeyStatus.WasKeyDown) { compareByPointer = true; _ = Hold(true); }
            args.Handled = true;
        }), true);
        compare.AddHandler(KeyUpEvent, new KeyEventHandler((_, args) => { if (args.Key == VirtualKey.Space) { _ = Hold(false); args.Handled = true; } }), true);
        // Narrator's Toggle and Enter switch it on until switched off; after a hold, the button's own toggle is put back.
        compare.Checked += (_, _) => _ = CompareToggledAsync(true);
        compare.Unchecked += (_, _) => _ = CompareToggledAsync(false);
        compare.Click += (_, _) => compareByPointer = false;
        body.Children.Add(Stacked(look, compareWhy));

        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(Label("Amount"));
        Grid.SetColumn(amount, 1); row.Children.Add(amount);
        Grid.SetColumn(amountBox, 2); row.Children.Add(amountBox);
        AutomationProperties.SetAutomationId(amount, "Picture.Amount");
        AutomationProperties.SetName(amount, PicturePanelModel.AmountName);
        AutomationProperties.SetAutomationId(amountBox, "Picture.AmountValue");
        AutomationProperties.SetName(amountBox, PicturePanelModel.AmountName + " in percent");
        amount.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => amountDragging = true), true);
        void AmountReleased() { if (!amountDragging) return; amountDragging = false; if (!Model.SetAmount((int)amount.Value)) { Model.EndPreview(); Render(); } }
        amount.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => AmountReleased()), true);
        amount.PointerCaptureLost += (_, _) => AmountReleased();
        amount.ValueChanged += (_, args) =>
        {
            if (syncing) return;
            if (amountDragging) Model.PreviewAmount((int)args.NewValue);
            else Model.SetAmount((int)args.NewValue);
        };
        amount.AddHandler(KeyDownEvent, new KeyEventHandler((_, args) => SliderKey(args, amount, value => Model.SetAmount(value), () => Model.SetAmount(100))), true);
        amount.DoubleTapped += (_, _) => Model.SetAmount(100);
        CommitOnEnter(amountBox, text => PicturePanelModel.ParseAmount(text) is { } value && Model.SetAmount(value));
        body.Children.Add(Stacked(row, amountWhy));
    }

    private void BuildChips()
    {
        AutomationProperties.SetName(chips, "Look categories");
        // One tab stop for the categories; ←/→ move between them.
        chips.TabFocusNavigation = KeyboardNavigationMode.Once;
        AutomationProperties.SetAutomationId(chips, "Picture.Categories");
        body.Children.Add(chips);
        body.Children.Add(previewNote);
    }

    private void BuildTiles()
    {
        AutomationProperties.SetAutomationId(tiles, "Picture.Tiles");
        // Square tiles in an ItemsWrapGrid, as many columns as fit (looks spec §3.7).
        tiles.ItemsPanel = (ItemsPanelTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(
            "<ItemsPanelTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><ItemsWrapGrid Orientation=\"Horizontal\"/></ItemsPanelTemplate>");
        // The panel scrolls; the grid shows every tile of its chip.
        ScrollViewer.SetVerticalScrollMode(tiles, ScrollMode.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(tiles, ScrollBarVisibility.Disabled);
        tiles.ItemClick += (_, args) => { if (args.ClickedItem is FrameworkElement { Tag: string id }) Apply(id); };
        tiles.PointerExited += (_, _) => { hovered = null; hover.Stop(); Model.EndPreview(); };
        tiles.AddHandler(KeyDownEvent, new KeyEventHandler((_, args) =>
        {
            if (args.Key == VirtualKey.Escape) { Model.EndPreview(); args.Handled = true; }
        }), true);
        tiles.SizeChanged += (_, _) => SizeTiles();
        tiles.Loaded += (_, _) => SizeTiles();
        body.Children.Add(tiles);
    }

    private void BuildFineTune()
    {
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        fold.Click += (_, _) => Model.ToggleFineTune();
        AutomationProperties.SetAutomationId(fold, "Picture.FineTune");
        header.Children.Add(fold);
        var back = Stacked(backTo, backToWhy);
        back.HorizontalAlignment = HorizontalAlignment.Right;
        backToWhy.TextAlignment = TextAlignment.Right;
        Grid.SetColumn(back, 1); header.Children.Add(back);
        backTo.Click += (_, _) => Model.BackTo();
        AutomationProperties.SetAutomationId(backTo, "Picture.BackTo");
        body.Children.Add(header);

        foreach (var group in Model.Groups)
        {
            var row = new GroupRow(group.Id);
            groups[group.Id] = row;
            var heading = new Grid { ColumnSpacing = 8 };
            heading.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            row.Heading.Text = group.Note is null ? group.Heading.ToUpperInvariant() : group.Heading.ToUpperInvariant() + " · " + group.Note;
            row.Heading.FontSize = 11; row.Heading.VerticalAlignment = VerticalAlignment.Center;
            row.Heading.Foreground = (Brush)Application.Current.Resources["VcTextTertiaryBrush"];
            AutomationProperties.SetName(row.Heading, group.SpokenHeading);
            AutomationProperties.SetHeadingLevel(row.Heading, AutomationHeadingLevel.Level3);
            heading.Children.Add(row.Heading);
            if (group.Id == PictureGroupId.Fix)
            {
                row.Auto = new HyperlinkButton { Content = "Auto", Padding = new(0) };
                row.Auto.Click += (_, _) => Model.Auto();
                AutomationProperties.SetAutomationId(row.Auto, "Picture.Auto");
                AutomationProperties.SetName(row.Auto, "Auto: fix light and color");
                Grid.SetColumn(row.Auto, 1); heading.Children.Add(row.Auto);
            }
            var id = group.Id;
            row.Reset.Click += (_, _) => Model.ResetGroup(id);
            AutomationProperties.SetAutomationId(row.Reset, "Picture.Reset." + id);
            AutomationProperties.SetName(row.Reset, group.ResetName);
            Grid.SetColumn(row.Reset, 2); heading.Children.Add(row.Reset);
            row.Panel.Children.Add(heading);
            row.Panel.Children.Add(row.Why);
            foreach (var slider in group.Sliders)
            {
                var item = new SliderRow(slider.Control, slider.Label);
                sliders[slider.Control] = item;
                BuildSlider(item);
                row.Panel.Children.Add(item.Panel);
            }
            if (group.Id == PictureGroupId.Effects)
            {
                toning.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
                toning.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
                toningText.FontSize = 12;
                toning.Children.Add(toningText);
                Grid.SetColumn(removeToning, 1); toning.Children.Add(removeToning);
                removeToning.Click += (_, _) => Model.RemoveToning();
                AutomationProperties.SetAutomationId(removeToning, "Picture.RemoveToning");
                AutomationProperties.SetName(removeToning, "Remove toning");
                row.Panel.Children.Add(toning);
            }
            fineTune.Children.Add(row.Panel);
        }
        body.Children.Add(fineTune);
    }

    private void BuildSlider(SliderRow row)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new() { Width = new(88) });
        grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var label = new TextBlock { Text = row.Label, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(label);
        var track = new Grid();
        track.Children.Add(row.Slider);
        track.Children.Add(row.Tick);
        Grid.SetColumn(track, 1); grid.Children.Add(track);
        Grid.SetColumn(row.Box, 2); grid.Children.Add(row.Box);
        AutomationProperties.SetName(row.Slider, row.Label);
        AutomationProperties.SetAutomationId(row.Slider, "Picture.Slider." + row.Control);
        AutomationProperties.SetName(row.Box, row.Label + " value");
        AutomationProperties.SetAutomationId(row.Box, "Picture.Value." + row.Control);
        var control = row.Control;
        row.Slider.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => row.Dragging = true), true);
        void Released() { if (!row.Dragging) return; row.Dragging = false; if (!Model.SetValue(control, (int)row.Slider.Value)) { Model.EndPreview(); Render(); } }
        row.Slider.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => Released()), true);
        row.Slider.PointerCaptureLost += (_, _) => Released();
        row.Slider.ValueChanged += (_, args) =>
        {
            if (syncing) return;
            if (row.Dragging) Model.PreviewValue(control, (int)args.NewValue);
            else Model.SetValue(control, (int)args.NewValue);
        };
        row.Slider.AddHandler(KeyDownEvent, new KeyEventHandler((_, args) =>
            SliderKey(args, row.Slider, value => Model.SetValue(control, value), () => Model.ResetValue(control))), true);
        row.Slider.DoubleTapped += (_, _) => Model.ResetValue(control);
        row.Slider.SizeChanged += (_, _) => PlaceTick(row);
        CommitOnEnter(row.Box, text => PicturePanelModel.Parse(control, text) is { } value && Model.SetValue(control, value));
        row.Panel.Children.Add(grid);
        row.Panel.Children.Add(row.Why);
    }

    /// <summary>Shift+arrows step ten, Delete and Backspace go back to the look's value; plain arrows are the slider's own one-point step.</summary>
    private void SliderKey(KeyRoutedEventArgs args, Slider slider, Func<int, bool> set, Func<bool> back)
    {
        if (!slider.IsEnabled) return;
        if (args.Key is VirtualKey.Delete or VirtualKey.Back) { back(); args.Handled = true; return; }
        if (args.Key is VirtualKey.Left or VirtualKey.Right && InputState.Down(VirtualKey.Shift))
        {
            set((int)Math.Clamp(slider.Value + (args.Key == VirtualKey.Right ? 10 : -10), slider.Minimum, slider.Maximum));
            args.Handled = true;
        }
    }

    private void CommitOnEnter(TextBox box, Func<string, bool> commit)
    {
        box.KeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Enter) { if (!commit(box.Text)) Render(); args.Handled = true; }
            else if (args.Key == VirtualKey.Escape) { Render(); args.Handled = true; }
        };
        box.LostFocus += (_, _) => Render();
    }

    // MARK: Rendering

    private void ModelChanged(object? sender, EventArgs args)
    {
        if (DispatcherQueue.HasThreadAccess) Render();
        else DispatcherQueue.TryEnqueue(Render);
    }

    private void EffectsChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(() => { tilesKey = ""; Render(); });

    private void Announced(object? sender, string text) => DispatcherQueue.TryEnqueue(() => Ui.Announce(this, text, "Picture"));

    private void Render()
    {
        if (!shown) return;
        Model.Opened();
        syncing = true;
        try
        {
            var model = Model;
            block = model.Blocked;
            Show(blocked, block);
            // Claude's line.
            if (model.ClaudeLine is { } line)
            {
                claude.Visibility = Visibility.Visible;
                claudeText.Text = "✦ " + line.Text + (line.Detail.Length > 0 ? " · " + line.Detail : "");
                useIt.Visibility = line.CanUse ? Visibility.Visible : Visibility.Collapsed;
            }
            else claude.Visibility = Visibility.Collapsed;
            // The Look row and Compare.
            lookValue.Text = model.LookText;
            AutomationProperties.SetName(lookValue, "Look " + model.LookText);
            compare.IsEnabled = model.CompareReason is null;
            compare.IsChecked = model.Comparing;
            AutomationProperties.SetItemStatus(compare, model.CompareStatus);
            Disabled(compare, compareWhy, model.CompareReason, null);
            // Amount.
            amount.IsEnabled = model.AmountReason is null;
            if (!amountDragging) amount.Value = model.Amount;
            if (!ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), amountBox)) amountBox.Text = model.AmountText;
            amountBox.IsEnabled = amount.IsEnabled;
            AutomationProperties.SetItemStatus(amount, model.AmountSpoken);
            Disabled(amount, amountWhy, model.AmountReason, PicturePanelModel.AmountHelp);
            RenderChips(model);
            Show(previewNote, model.PreviewNote);
            RenderTiles(model);
            RenderFineTune(model);
            RenderTimed(model);
            clear.IsEnabled = model.ClearReason is null;
            Disabled(clear, clearWhy, model.ClearReason, null);
        }
        finally { syncing = false; }
    }

    private static void Show(TextBlock text, string? value)
    {
        text.Text = value ?? "";
        text.Visibility = value is null ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>A disabled control's reason: the inline tertiary line, and its Narrator help (WinUI shows no tooltip when disabled). The
    /// reason the whole tab is blocked shows once, at the top, and only as help on each control.</summary>
    private void Disabled(Control control, TextBlock why, string? reason, string? help)
    {
        Show(why, reason == block ? null : reason);
        AutomationProperties.SetHelpText(control, reason ?? help ?? "");
    }

    private void RenderChips(PicturePanelModel model)
    {
        var list = model.Chips;
        if (chips.Children.Count != list.Count)
        {
            chips.Children.Clear();
            foreach (var chip in list)
            {
                var toggle = new ToggleButton { Content = chip.Label, CornerRadius = new(12), Padding = new(10, 3, 10, 3), Tag = chip.Id };
                AutomationProperties.SetAutomationId(toggle, "Picture.Category." + chip.Id);
                AutomationProperties.SetName(toggle, chip.Label + " looks");
                var id = chip.Id;
                toggle.Click += (_, _) => { model.SelectCategory(id); Render(); };
                toggle.KeyDown += (_, args) => ChipKey(args, toggle);
                chips.Children.Add(toggle);
            }
        }
        for (var index = 0; index < list.Count; index++)
            if (chips.Children[index] is ToggleButton toggle) toggle.IsChecked = list[index].Selected;
    }

    /// <summary>The categories are one stop: ←/→ move between them, Space or Enter selects.</summary>
    private void ChipKey(KeyRoutedEventArgs args, ToggleButton toggle)
    {
        if (args.Key is not (VirtualKey.Left or VirtualKey.Right)) return;
        var index = chips.Children.IndexOf(toggle) + (args.Key == VirtualKey.Right ? 1 : -1);
        if (index >= 0 && index < chips.Children.Count && chips.Children[index] is Control next) next.Focus(FocusState.Keyboard);
        args.Handled = true;
    }

    private void RenderTiles(PicturePanelModel model)
    {
        var list = model.Tiles;
        AutomationProperties.SetName(tiles, model.TilesName);
        AutomationProperties.SetItemStatus(tiles, model.TilesStatus);
        var key = model.Category + "|" + string.Join(",", list.Select(tile => tile.Look.Id + tile.Status)) + "|" + Ui.HighContrast + "|" + model.Playing + "|" + model.HoverReason;
        if (key == tilesKey) { UpdateThumbnails(); return; }
        tilesKey = key;
        // The same looks keep their items, so keyboard focus stays on the tile just applied.
        if (!tiles.Items.OfType<GridViewItem>().Select(item => item.Tag as string).SequenceEqual(list.Select(tile => tile.Look.Id)))
        {
            tiles.Items.Clear();
            foreach (var tile in list) tiles.Items.Add(NewTile(tile.Look.Id, model));
        }
        for (var index = 0; index < list.Count; index++) if (tiles.Items[index] is GridViewItem item) Fill(item, list[index], model);
        SizeTiles();
        UpdateThumbnails();
        _ = RefreshThumbnailsAsync();
    }

    private GridViewItem NewTile(string id, PicturePanelModel model)
    {
        var item = new GridViewItem { Tag = id, Padding = new(0), Margin = new(0, 0, TileGap, TileGap), MinWidth = TileMinimum, MinHeight = TileMinimum };
        AutomationProperties.SetAutomationId(item, "Picture.Tile." + id);
        item.PointerEntered += (_, args) =>
        {
            if (args.Pointer.PointerDeviceType != Microsoft.UI.Input.PointerDeviceType.Mouse) return;
            hovered = id; hover.Stop(); hover.Start();
        };
        // Arrows move focus and preview on the paused viewer; Enter or Space is the grid's item click.
        item.GotFocus += (_, _) => { if (item.FocusState == FocusState.Keyboard) model.PreviewLook(id); };
        return item;
    }

    private void Fill(GridViewItem item, PictureTile tile, PicturePanelModel model)
    {
        var highContrast = Ui.HighContrast;
        var picture = new Image { Stretch = Stretch.UniformToFill, Tag = tile.Look.Id };
        AutomationProperties.SetAccessibilityView(picture, AccessibilityView.Raw);
        var frame = new Grid { CornerRadius = new(6) };
        frame.Children.Add(new Border { CornerRadius = new(6), Background = (Brush)Application.Current.Resources["VcBgSunkenBrush"] });
        frame.Children.Add(picture);
        var ring = new Border { CornerRadius = new(6), BorderThickness = new(1), BorderBrush = (Brush)Application.Current.Resources["VcLineDefaultBrush"] };
        var accent = highContrast ? Highlight() : (Brush)Application.Current.Resources["VcAccentDefaultBrush"];
        if (tile.Applied && (!tile.Edited || highContrast)) { ring.BorderThickness = new(2); ring.BorderBrush = accent; }
        frame.Children.Add(ring);
        if (tile.Applied && tile.Edited && !highContrast)
            frame.Children.Add(new Rectangle { RadiusX = 6, RadiusY = 6, Stroke = accent, StrokeThickness = 1.5, StrokeDashArray = new DoubleCollection { 3, 2 } });
        if (tile.Applied) frame.Children.Add(Badge("✓", HorizontalAlignment.Left));
        if (tile.Claude) frame.Children.Add(Badge("✦", HorizontalAlignment.Right));
        var label = new TextBlock
        {
            Text = tile.Label(highContrast), FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
            HorizontalAlignment = HorizontalAlignment.Center, MaxLines = 1,
        };
        AutomationProperties.SetAccessibilityView(label, AccessibilityView.Raw);
        var stack = new StackPanel { Spacing = 2, Tag = tile.Look.Id };
        stack.Children.Add(frame);
        stack.Children.Add(label);
        item.Content = stack;
        AutomationProperties.SetName(item, tile.Name);
        AutomationProperties.SetItemStatus(item, tile.Status);
        AutomationProperties.SetHelpText(item, tile.Help);
        ToolTipService.SetToolTip(item, model.Playing ? PicturePanelModel.PauseToPreview : tile.Look.Label + ": " + tile.Help);
    }

    /// <summary>High contrast's selection colour for the applied ring (looks spec §3.9).</summary>
    private static Brush Highlight() =>
        Application.Current.Resources.TryGetValue("SystemColorHighlightColorBrush", out var value) && value is Brush brush ? brush
            : new SolidColorBrush(new Windows.UI.ViewManagement.UISettings().UIElementColor(Windows.UI.ViewManagement.UIElementType.Highlight));

    private static Border Badge(string glyph, HorizontalAlignment side) => new()
    {
        Child = new TextBlock { Text = glyph, FontSize = 10, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(160, 0, 0, 0)), CornerRadius = new(3), Padding = new(3, 0, 3, 1),
        HorizontalAlignment = side, VerticalAlignment = VerticalAlignment.Top, Margin = new(3), IsHitTestVisible = false,
    };

    private void Apply(string id)
    {
        hover.Stop();
        if (Model.Apply(id) == PictureApplyOutcome.FocusAmount) amount.Focus(FocusState.Keyboard);
    }

    /// <summary>Square tiles of at least 56 epx, as many columns as fit, 6 epx apart.</summary>
    private void SizeTiles()
    {
        var width = tiles.ActualWidth;
        if (width <= 0) return;
        var columns = Math.Max(1, (int)Math.Floor((width + TileGap) / (TileMinimum + TileGap)));
        var edge = Math.Floor((width - TileGap * columns) / columns);
        if (tiles.ItemsPanelRoot is ItemsWrapGrid wrap) { wrap.ItemWidth = edge + TileGap; wrap.MaximumRowsOrColumns = columns; }
        foreach (var item in tiles.Items.OfType<GridViewItem>())
        {
            item.Width = edge;
            if (Frame(item) is { } frame) { frame.Width = edge; frame.Height = edge; }
        }
    }

    private void RenderFineTune(PicturePanelModel model)
    {
        var open = model.FineTuneOpen;
        fold.Content = (open ? "Fine-tune ▾" : "Fine-tune ▸");
        AutomationProperties.SetName(fold, "Fine-tune");
        AutomationProperties.SetItemStatus(fold, open ? "Expanded" : "Collapsed");
        fineTune.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        backTo.Visibility = model.BackToLabel is null ? Visibility.Collapsed : Visibility.Visible;
        backTo.Content = model.BackToLabel ?? "";
        AutomationProperties.SetName(backTo, model.BackToLabel ?? "");
        backTo.IsEnabled = model.BackToReason is null;
        Disabled(backTo, backToWhy, model.BackToLabel is null ? null : model.BackToReason, null);
        foreach (var group in model.Groups)
        {
            var row = groups[group.Id];
            row.Reset.IsEnabled = group.ResetReason is null;
            // "Nothing to reset" stays help only: four lines of it would push the sliders down.
            Disabled(row.Reset, row.Why, group.ResetReason is "Nothing to reset" ? null : group.ResetReason, null);
            AutomationProperties.SetHelpText(row.Reset, group.ResetReason ?? "");
            if (row.Auto is { } auto)
            {
                auto.IsEnabled = model.AutoReason is null;
                AutomationProperties.SetHelpText(auto, model.AutoReason ?? "Sets exposure, temperature and tint from the picture");
                if (model.AutoReason is { } why && why != block) Show(row.Why, why);
            }
            foreach (var slider in group.Sliders) RenderSlider(sliders[slider.Control], slider);
        }
        if (model.ToningText is { } text)
        {
            toning.Visibility = Visibility.Visible;
            toningText.Text = text;
            removeToning.IsEnabled = model.Blocked is null;
        }
        else toning.Visibility = Visibility.Collapsed;
    }

    private void RenderSlider(SliderRow row, PictureSlider slider)
    {
        row.Slider.Minimum = slider.Minimum;
        row.Slider.Maximum = slider.Maximum;
        row.Slider.IsEnabled = slider.IsEnabled;
        row.Box.IsEnabled = slider.IsEnabled;
        if (!row.Dragging) row.Slider.Value = slider.Value;
        if (!ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), row.Box)) row.Box.Text = slider.ValueText;
        AutomationProperties.SetItemStatus(row.Slider, slider.Spoken);
        Disabled(row.Slider, row.Why, slider.Reason, slider.Help);
        row.LookValue = slider.LookValue;
        PlaceTick(row);
    }

    /// <summary>The accent tick at the look's own value on the slider's track.</summary>
    private static void PlaceTick(SliderRow row)
    {
        var width = row.Slider.ActualWidth;
        var span = row.Slider.Maximum - row.Slider.Minimum;
        row.Tick.Visibility = width > 0 && span > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (width <= 0 || span <= 0) return;
        // The thumb's travel is the track less the thumb (about 18 epx).
        const double thumb = 18;
        var x = thumb / 2 + (row.LookValue - row.Slider.Minimum) / span * Math.Max(0, width - thumb);
        row.Tick.Margin = new(x - 1, 0, 0, 0);
    }

    private void RenderTimed(PicturePanelModel model)
    {
        timed.Children.Clear();
        foreach (var look in model.TimedLooks)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var text = Ui.Text(look.Text); text.FontSize = 12; text.MaxWidth = 220;
            row.Children.Add(text);
            var play = new HyperlinkButton { Content = "▶", Padding = new(0) };
            AutomationProperties.SetName(play, "Play the timed look");
            play.Click += (_, _) => model.PlayTimedLook(look);
            var remove = new HyperlinkButton { Content = "Remove", Padding = new(0), IsEnabled = model.Blocked is null };
            AutomationProperties.SetName(remove, "Remove the timed look");
            remove.Click += (_, _) => model.RemoveTimedLook(look);
            row.Children.Add(play); row.Children.Add(remove);
            timed.Children.Add(row);
        }
        timed.Visibility = timed.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    // MARK: Compare

    private async Task Hold(bool down)
    {
        try
        {
            if (HoldCompare is { } hold) await hold(down);
            else if (down) Model.BeginCompare();
            else Model.EndCompare();
        }
        catch (Exception exception) when (exception is not OutOfMemoryException) { UiError.WriteFailure(exception, "Compare"); }
        if (!down) Render();
    }

    private async Task CompareToggledAsync(bool on)
    {
        if (syncing) return;
        if (compareByPointer) { DispatcherQueue.TryEnqueue(Render); return; }
        if (on != Model.Comparing) await Hold(on);
        Render();
        Ui.Announce(compare, Model.CompareStatus, "Picture.Compare");
    }

    private void EndCompareForFocus()
    {
        if (Model.Comparing) _ = Hold(false);
    }

    // MARK: Thumbnails

    /// <summary>The playhead moved while paused: the tiles follow once it has rested for half a second (looks spec §7.1).</summary>
    internal void PlayheadMoved()
    {
        if (!shown || Model.Playing) return;
        rest.Stop(); rest.Start();
    }

    private string ThumbnailKey(PicturePanelModel model, int edge)
    {
        var controls = model.Controls;
        var framing = controls is null ? "" : (new ClipColorState().Applied(controls) with { ColorGrade = controls.ColorGrade?.Fix is { IsNeutral: false } fix ? ClipColorGrade.Neutral.WithFix(fix) : null }).GetHashCode().ToString(System.Globalization.CultureInfo.InvariantCulture);
        return model.ClipId + "|" + framing + "|" + edge.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + model.StillState;
    }

    private async Task RefreshThumbnailsAsync()
    {
        var model = Model;
        if (!shown || model.ClipId is null || model.Playing || tiles.Items.Count == 0) return;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var first = tiles.Items.OfType<GridViewItem>().FirstOrDefault();
        var size = first is { Width: > 0 } ? first.Width : TileMinimum;
        var edge = (int)Math.Clamp(Math.Round(size * scale), 32, 144);
        var key = ThumbnailKey(model, edge);
        if (key == thumbnailKey) { await RenderMissingAsync(edge); return; }
        thumbnailKey = key;
        thumbnails.Clear();
        still = null;
        thumbnailWork?.Cancel();
        thumbnailWork = new();
        await RenderMissingAsync(edge);
    }

    private PixelBuffer? still;

    private async Task RenderMissingAsync(int edge)
    {
        var model = Model;
        thumbnailWork ??= new();
        var token = thumbnailWork.Token;
        var wanted = model.Tiles.Where(tile => !thumbnails.ContainsKey(tile.Look.Id)).ToArray();
        if (wanted.Length == 0) { UpdateThumbnails(); return; }
        try
        {
            still ??= await ReadStillAsync(token);
            if (still is not { } source || token.IsCancellationRequested) return;
            var square = PicturePanelModel.TileSquare(source.Width, source.Height);
            foreach (var tile in wanted)
            {
                if (model.TileColour(tile.Look) is not { } colour) continue;
                var pixels = await Task.Run(() => ClipLookTiles.Render(source, square, edge, colour, token), token);
                if (token.IsCancellationRequested) return;
                thumbnails[tile.Look.Id] = Bitmap(pixels);
                UpdateThumbnails();
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is not OutOfMemoryException) { UiError.WriteFailure(exception, "Look tiles"); }
    }

    /// <summary>The paused frame before the grade, or the test card with the reason line when it can't be read (looks spec §7.7).</summary>
    private async Task<PixelBuffer?> ReadStillAsync(CancellationToken ct)
    {
        if (editor.IsReadOnly || BeforeGrade is null)
        {
            Model.SetStillState(editor.IsReadOnly ? PictureStillState.Offline : PictureStillState.Unreadable);
            return SamplePicture?.Invoke();
        }
        try
        {
            var frame = await BeforeGrade(ct);
            Model.SetStillState(PictureStillState.Ready);
            return frame;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) when (exception is InvalidOperationException or NotSupportedException or IOException or Core.Domain.Shared.VoxClipException)
        {
            Model.SetStillState(PictureStillState.Unreadable);
            return SamplePicture?.Invoke();
        }
    }

    private void UpdateThumbnails()
    {
        foreach (var item in tiles.Items.OfType<GridViewItem>())
            if (Frame(item)?.Children.OfType<Image>().FirstOrDefault() is { Tag: string id } image) image.Source = thumbnails.GetValueOrDefault(id);
    }

    private static Grid? Frame(GridViewItem item) => item.Content is StackPanel stack && stack.Children.Count > 0 ? stack.Children[0] as Grid : null;

    internal static WriteableBitmap Bitmap(PixelBuffer pixels)
    {
        var image = new WriteableBitmap(pixels.Width, pixels.Height);
        using (var stream = image.PixelBuffer.AsStream())
        {
            if (pixels.Stride == pixels.Width * 4) stream.Write(pixels.Pixels.Span);
            else for (var row = 0; row < pixels.Height; row++) stream.Write(pixels.Pixels.Span.Slice(row * pixels.Stride, pixels.Width * 4));
        }
        image.Invalidate();
        return image;
    }

    private sealed class GroupRow(PictureGroupId id)
    {
        internal PictureGroupId Id { get; } = id;
        internal StackPanel Panel { get; } = Ui.Stack(6);
        internal TextBlock Heading { get; } = new();
        internal HyperlinkButton Reset { get; } = new() { Content = "Reset", Padding = new(0) };
        internal HyperlinkButton? Auto { get; set; }
        internal TextBlock Why { get; } = Reason();
    }

    private sealed class SliderRow(PictureControl control, string label)
    {
        internal PictureControl Control { get; } = control;
        internal string Label { get; } = label;
        internal StackPanel Panel { get; } = Ui.Stack(0);
        internal Slider Slider { get; } = new() { Minimum = -100, Maximum = 100, StepFrequency = 1, SmallChange = 1, LargeChange = 10 };
        internal TextBox Box { get; } = new() { Width = 72, TextAlignment = TextAlignment.Right };
        internal Rectangle Tick { get; } = new()
        {
            Width = 2, Height = 10, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false,
            Fill = (Brush)Application.Current.Resources["VcAccentDefaultBrush"],
        };
        internal TextBlock Why { get; } = Reason();
        internal bool Dragging { get; set; }
        internal int LookValue { get; set; }
    }
}
