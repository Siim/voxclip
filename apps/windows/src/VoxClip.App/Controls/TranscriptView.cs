using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using Windows.UI.Text;

namespace VoxClip.App.Controls;

public sealed class TranscriptView : UserControl
{
    private readonly ItemsRepeater repeater;
    private readonly Dictionary<Grid, ParagraphVisual> realized = [];
    private EditorViewModel? model;
    private bool dragging;
    private bool showCuts = true;
    private bool showPauses = true;
    private double fontSize = 16;
    private readonly Popup correction = new() { IsLightDismissEnabled = true };
    private sealed record WordRun(int Index, Run Run);
    private sealed record PauseRun(Pause Pause, Run Run);
    private sealed record ParagraphVisual(RichTextBlock Text, List<WordRun> Runs, List<PauseRun> Pauses)
    {
        internal int[] HighlightStarts { get; set; } = [];
    }
    public bool CorrectionOpen => correction.IsOpen;
    public event EventHandler? SeekRequested;
    public event EventHandler? MakeClipRequested;
    public event EventHandler? PlayRequested;

    public TranscriptView()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        AutomationProperties.SetName(this, "Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.");
        repeater = new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 12 },
            ItemTemplate = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Grid ColumnSpacing='12' Padding='0,4'><Grid.ColumnDefinitions><ColumnDefinition Width='64'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions><TextBlock FontSize='12' VerticalAlignment='Top' Margin='0,5,0,0' TextWrapping='Wrap'/><RichTextBlock Grid.Column='1' IsTextSelectionEnabled='False' TextWrapping='Wrap' MaxWidth='680' HorizontalAlignment='Left'/></Grid></DataTemplate>")
        };
        repeater.ElementPrepared += Prepared;
        repeater.ElementClearing += (_, args) => { if (args.Element is Grid grid) realized.Remove(grid); };
        Content = new ScrollViewer { Content = repeater, Padding = new Thickness(24), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        ActualThemeChanged += (_, _) => RefreshVisuals();
        Unloaded += (_, _) => correction.IsOpen = false;
    }

    public void Attach(EditorViewModel viewModel)
    {
        fontSize = Math.Clamp(App.Services.Get("general.transcriptTextSize", 16d), 13, 28);
        if (model is not null) { model.Changed -= ModelChanged; model.SelectionChanged -= ModelChanged; model.Announcement -= Announce; }
        model = viewModel;
        model.Changed += ModelChanged;
        model.SelectionChanged += ModelChanged;
        model.Announcement += Announce;
        repeater.ItemsSource = model.Paragraphs;
    }
    public void Detach()
    {
        if (model is not null) { model.Changed -= ModelChanged; model.SelectionChanged -= ModelChanged; model.Announcement -= Announce; }
        correction.IsOpen = false;
    }
    public void SetDisplay(bool cutWords, bool pauses)
    {
        showCuts = cutWords;
        showPauses = pauses;
        repeater.ItemsSource = null;
        repeater.ItemsSource = model?.Paragraphs;
    }
    public void Zoom(double delta, bool reset = false)
    {
        fontSize = reset ? 16 : Math.Clamp(fontSize + delta, 13, 28);
        foreach (var visual in realized.Values) { visual.Text.FontSize = fontSize; visual.Text.LineHeight = fontSize * 26 / 16; }
    }
    public void ApplySettings()
    {
        fontSize = Math.Clamp(App.Services.Get("general.transcriptTextSize", 16d), 13, 28);
        Zoom(0); RefreshVisuals();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new TranscriptPeer(this);
    private sealed class TranscriptPeer(TranscriptView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override string GetClassNameCore() => "VoxClipTranscript";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Document;
    }
    private void ModelChanged(object? sender, EventArgs args) => RefreshVisuals();
    private void Announce(object? sender, string text)
    {
        FrameworkElementAutomationPeer.FromElement(this)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.MostRecent, text, "edit");
    }
    private Brush Brush(string key) => Ui.ThemeBrush(this, key);

    private void Prepared(ItemsRepeater sender, ItemsRepeaterElementPreparedEventArgs args)
    {
        if (model is null || args.Element is not Grid grid || args.Index >= model.Paragraphs.Count) return;
        var item = model.Paragraphs[args.Index];
        var gutter = (TextBlock)grid.Children[0];
        gutter.Text = item.Timecode + (item.Speaker is null ? "" : "\n" + item.Speaker);
        gutter.FontFamily = (FontFamily)Application.Current.Resources["VcFontGeistMono"];
        gutter.Foreground = Brush("VcTextTertiaryBrush");
        var rich = (RichTextBlock)grid.Children[1];
        rich.FontFamily = (FontFamily)Application.Current.Resources["VcFontDmSans"];
        rich.FontSize = fontSize;
        rich.LineHeight = fontSize * 26 / 16;
        var rtl = model.State?.Transcript.Language?.Split('-')[0] is "ar" or "he" or "fa" or "ur";
        rich.FlowDirection = rtl ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        Grid.SetColumn(gutter, rtl ? 1 : 0); Grid.SetColumn(rich, rtl ? 0 : 1);
        grid.ColumnDefinitions[0].Width = rtl ? new GridLength(1, GridUnitType.Star) : new GridLength(64);
        grid.ColumnDefinitions[1].Width = rtl ? new GridLength(64) : new GridLength(1, GridUnitType.Star);
        rich.Blocks.Clear();
        var paragraph = new Paragraph();
        var runs = new List<WordRun>();
        var pauses = new List<PauseRun>();
        for (var index = item.StartIndex; index < item.StartIndex + item.Count; index++)
        {
            var word = model.Words[index];
            var run = new Run { Text = model.DisplayText(word) + " " };
            paragraph.Inlines.Add(run);
            runs.Add(new(index, run));
            if (showPauses && model.State?.Pauses.FirstOrDefault(pause => pause.AfterIndex == index) is { } pause)
            {
                var pauseRun = new Run { Text = " ‖ " + pause.Label + " ", FontSize = 11, FontFamily = (FontFamily)Application.Current.Resources["VcFontGeistMono"], Foreground = Brush("VcTextMutedBrush") };
                paragraph.Inlines.Add(pauseRun); pauses.Add(new(pause, pauseRun));
            }
        }
        rich.Blocks.Add(paragraph);
        realized[grid] = new(rich, runs, pauses);
        rich.PointerPressed -= Pressed; rich.PointerPressed += Pressed;
        rich.PointerMoved -= Moved; rich.PointerMoved += Moved;
        rich.PointerReleased -= Released; rich.PointerReleased += Released;
        rich.DoubleTapped -= DoubleTappedWord; rich.DoubleTapped += DoubleTappedWord;
        rich.RightTapped -= WordContextRequested; rich.RightTapped += WordContextRequested;
        RefreshVisuals();
    }

    public void RefreshVisuals()
    {
        if (model?.State is not { } state) return;
        var lowConfidence = App.Services.Get("general.showLowConfidence", false);
        foreach (var visual in realized.Values)
        {
            visual.Text.TextHighlighters.Clear();
            var textChanged = visual.HighlightStarts.Length != visual.Runs.Count;
            foreach (var run in visual.Runs)
            {
                var word = model.Words.ElementAtOrDefault(run.Index);
                if (word is null) continue;
                var cut = state.CutWordIds.Contains(word.Id);
                var text = model.DisplayText(word) + " ";
                if (cut && !showCuts)
                {
                    var count = 1;
                    while (run.Index + count < model.Words.Count && state.CutWordIds.Contains(model.Words[run.Index + count].Id)) count++;
                    text = run.Index > 0 && state.CutWordIds.Contains(model.Words[run.Index - 1].Id) ? "" : $"⋯ {count} cut ";
                }
                if (run.Run.Text != text) { run.Run.Text = text; textChanged = true; }
                run.Run.TextDecorations = cut && showCuts ? TextDecorations.Strikethrough : IsFiller(model.DisplayText(word)) || lowConfidence && word.Conf is < 0.6 ? TextDecorations.Underline : TextDecorations.None;
                run.Run.Foreground = Brush(cut ? "VcWordCutBrush" : IsFiller(model.DisplayText(word)) ? "VcWordFillerBrush" : "VcTextPrimaryBrush");
                if (state.ActiveClipId is { } id && state.Clips.FirstOrDefault(clip => clip.Id == id) is { } active &&
                    (run.Index < model.Index(active.StartWordId) || run.Index > model.Index(active.EndWordId))) run.Run.Foreground = Brush("VcTextDisabledBrush");
            }
            if (textChanged)
            {
                var pauseAfter = visual.Pauses.ToDictionary(pause => pause.Pause.AfterIndex, pause => pause.Run.Text);
                visual.HighlightStarts = TranscriptTextRanges.Starts(
                    visual.Runs.Select(run => run.Run.Text).ToArray(),
                    visual.Runs.Select(run => pauseAfter.GetValueOrDefault(run.Index)).ToArray());
            }
            for (var index = 0; index < visual.Runs.Count; index++)
            {
                var run = visual.Runs[index];
                var word = model.Words.ElementAtOrDefault(run.Index);
                if (word is null) continue;
                var selected = model.HasSelection && run.Index >= model.SelectionStart && run.Index <= model.SelectionEnd;
                var playing = model.SourceTime >= word.Start && model.SourceTime < word.End;
                var length = run.Run.Text.TrimEnd().Length;
                if ((!selected && !playing) || length == 0) continue;
                var highlighter = new TextHighlighter { Background = Brush(selected ? "SystemControlHighlightAccentBrush" : "VcWordPlayingBackgroundBrush"), Foreground = Brush(playing ? "VcWordPlayingForegroundBrush" : "SystemControlHighlightAltChromeWhiteBrush") };
                highlighter.Ranges.Add(new TextRange { StartIndex = visual.HighlightStarts[index], Length = length });
                visual.Text.TextHighlighters.Add(highlighter);
            }
            foreach (var pause in visual.Pauses) pause.Run.TextDecorations = state.CutPauseIds.Contains(pause.Pause.Id) ? TextDecorations.Strikethrough : TextDecorations.None;
            AutomationProperties.SetName(visual.Text, string.Join(" ", visual.Runs.Select(run => model.AccessibleWord(run.Index))));
        }
    }

    private static bool IsFiller(string text) => System.Text.RegularExpressions.Regex.IsMatch(text, @"^(um+|uh+|erm+|hmm+)[,.!?]?$|^…$", System.Text.RegularExpressions.RegexOptions.CultureInvariant | System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    private int Hit(RichTextBlock rich, Windows.Foundation.Point point)
    {
        var pointer = rich.GetPositionFromPoint(point);
        var visual = realized.Values.FirstOrDefault(value => value.Text == rich);
        if (pointer is null || visual is null) return -1;
        var offset = pointer.Offset - rich.ContentStart.Offset;
        return visual.Runs.LastOrDefault(run => run.Run.Text.Length > 0 && run.Run.ContentStart.Offset - rich.ContentStart.Offset <= offset)?.Index ?? visual.Runs.FirstOrDefault()?.Index ?? -1;
    }
    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        if (model is null || sender is not RichTextBlock rich || !args.GetCurrentPoint(rich).Properties.IsLeftButtonPressed) return;
        var pointer = rich.GetPositionFromPoint(args.GetCurrentPoint(rich).Position);
        var pause = realized.Values.FirstOrDefault(value => value.Text == rich)?.Pauses.FirstOrDefault(value => pointer is not null && pointer.Offset >= value.Run.ContentStart.Offset && pointer.Offset < value.Run.ContentEnd.Offset);
        if (pause is not null) { model.Apply(new EditOperation.Toggle(pause.Pause.Id)); args.Handled = true; return; }
        var index = Hit(rich, args.GetCurrentPoint(rich).Position);
        if (index < 0) return;
        Focus(FocusState.Pointer);
        model.Select(index, InputState.Down(Windows.System.VirtualKey.Shift));
        dragging = true;
        rich.CapturePointer(args.Pointer);
        SeekRequested?.Invoke(this, EventArgs.Empty);
        if (InputState.Down(Windows.System.VirtualKey.Menu)) PlayRequested?.Invoke(this, EventArgs.Empty);
        args.Handled = true;
    }
    private void Moved(object sender, PointerRoutedEventArgs args)
    {
        if (!dragging || model is null) return;
        foreach (var visual in realized.Values)
        {
            var point = args.GetCurrentPoint(visual.Text).Position;
            if (point.X < 0 || point.Y < 0 || point.X > visual.Text.ActualWidth || point.Y > visual.Text.ActualHeight) continue;
            var index = Hit(visual.Text, point);
            if (index >= 0) model.Select(index, true);
            break;
        }
    }
    private void Released(object sender, PointerRoutedEventArgs args)
    {
        dragging = false;
        ((UIElement)sender).ReleasePointerCapture(args.Pointer);
    }
    private void DoubleTappedWord(object sender, DoubleTappedRoutedEventArgs args) { BeginCorrection(); args.Handled = true; }
    public void BeginCorrection()
    {
        if (model is null || !model.HasSelection) return;
        var text = new TextBox { Text = model.DisplayText(model.Words[model.SelectionStart]), MinWidth = 140, MaxWidth = 320, Header = "Correct spelling" };
        AutomationProperties.SetName(text, "Correct spelling. The audio stays the same.");
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(text);
        panel.Children.Add(new TextBlock { Text = "Changes captions only. Enter saves. Esc cancels.", TextWrapping = TextWrapping.Wrap, FontSize = 12 });
        correction.Child = new Border { Child = panel, Padding = new Thickness(12), CornerRadius = new CornerRadius(8), Background = Brush("LayerFillColorDefaultBrush"), BorderBrush = Brush("VcLineStrongBrush"), BorderThickness = new Thickness(1), MaxWidth = 340 };
        correction.XamlRoot = XamlRoot;
        var visual = realized.Values.FirstOrDefault(value => value.Runs.Any(run => run.Index == model.SelectionStart));
        var word = visual?.Runs.FirstOrDefault(run => run.Index == model.SelectionStart);
        if (visual is not null && word is not null)
        {
            var rect = word.Run.ContentStart.GetCharacterRect(LogicalDirection.Forward);
            var point = visual.Text.TransformToVisual(null).TransformPoint(new(rect.X, rect.Bottom));
            correction.HorizontalOffset = Math.Min(point.X, Math.Max(0, XamlRoot.Size.Width - 350));
            correction.VerticalOffset = Math.Min(point.Y, Math.Max(0, XamlRoot.Size.Height - 160));
        }
        text.KeyDown += (_, args) =>
        {
            if (args.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Tab) { model.Correct(text.Text); correction.IsOpen = false; if (args.Key == Windows.System.VirtualKey.Tab) model.Select(model.SelectionEnd + 1); Focus(FocusState.Keyboard); args.Handled = true; }
            if (args.Key == Windows.System.VirtualKey.Escape) { correction.IsOpen = false; Focus(FocusState.Keyboard); args.Handled = true; }
        };
        EventHandler<object>? opened = null;
        opened = (_, _) => { correction.Opened -= opened; text.Focus(FocusState.Programmatic); text.SelectAll(); };
        correction.Opened += opened;
        correction.IsOpen = true;
    }
    private void WordContextRequested(object sender, RightTappedRoutedEventArgs args)
    {
        var menu = new MenuFlyout();
        void Add(string label, Action action) { var item = new MenuFlyoutItem { Text = label }; item.Click += (_, _) => action(); menu.Items.Add(item); }
        Add("Cut", () => model?.CutSelection());
        Add("Restore", () => model?.CutSelection(true));
        Add("Correct spelling…", BeginCorrection);
        Add("Play from here", () => SeekRequested?.Invoke(this, EventArgs.Empty));
        Add("Make clip from selection (Ctrl+K)", () => MakeClipRequested?.Invoke(this, EventArgs.Empty));
        Add("Copy text", () => Services.ShareHelpers.Copy(model?.SelectionText ?? ""));
        menu.ShowAt((FrameworkElement)sender, args.GetPosition((UIElement)sender));
        args.Handled = true;
    }
}

internal static class InputState
{
    internal static bool Down(Windows.System.VirtualKey key) => (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
    internal static bool IsTextFocus(object? element)
    {
        for (var current = element as DependencyObject; current is not null; current = VisualTreeHelper.GetParent(current))
            if (current is TextBox or PasswordBox or AutoSuggestBox or RichEditBox or NumberBox) return true;
        return false;
    }
    internal static bool DescendsFrom(DependencyObject? element, DependencyObject parent)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current)) if (current == parent) return true;
        return false;
    }
}
