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
    private readonly ScrollViewer scroll;
    private int pendingReveal = -1;
    private readonly SelectionFlyout selectionFlyout;
    private readonly Dictionary<Grid, ParagraphVisual> realized = [];
    private EditorViewModel? model;
    private bool dragging;
    private bool showCuts = true;
    private bool showPauses = true;
    private double fontSize = DefaultFontSize;
    private string structure = "";
    private readonly Popup correction = new() { IsLightDismissEnabled = true };
    private sealed record WordRun(int Index, Run Run, int Before, int After);
    private sealed record PauseRun(Pause Pause, Inline Inline, Run? Run);
    private sealed record ParagraphVisual(RichTextBlock Text, List<WordRun> Runs, List<PauseRun> Pauses, TranscriptOverlay Overlay)
    {
        internal int[] HighlightStarts { get; set; } = [];
    }
    public bool CorrectionOpen => correction.IsOpen;
    internal bool CanRewrite => RewriteRequested is not null && RewriteEntryPolicy.Resolve(RewriteEntry.Selection,
        App.Services.Get("voiceLab.enabled", false), model is { IsReadOnly: false, Busy: false, IsLeaving: false },
        model?.HasSelection == true, false, RewriteEntryPolicy.BuildEnabled) == RewriteEntryAction.OpenPassage;
    internal int InsertionAfterIndex { get; private set; } = -1;
    internal void RequestRewrite()
    {
        if (!RewriteEntryPolicy.BuildEnabled || !App.Services.Get("voiceLab.enabled", false) || model is null) return;
        if (CanRewrite) RewriteRequested?.Invoke(this, EventArgs.Empty);
        else if (RewriteRequested is null) { model.Notice = "Rewrite is not available in this build."; Announce(model.Notice); }
    }
#if DEBUG
    internal Windows.Foundation.Rect? DebugWordBounds(int index)
    {
        foreach (var visual in realized.Values)
            if (visual.Runs.FirstOrDefault(run => run.Index == index) is { } word && TranscriptOverlay.Bounds(word.Run).FirstOrDefault() is { Width: > 0 } bounds)
                return visual.Text.TransformToVisual(this).TransformBounds(bounds);
        return null;
    }
#endif
    public event EventHandler? SeekRequested;
    public event EventHandler? MakeClipRequested;
    public event EventHandler? PlayRequested;
    public event EventHandler? PreviewCutRequested;
    public event EventHandler? RewriteRequested;
    public event EventHandler? InsertWordsRequested;

    public TranscriptView()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        selectionFlyout = new(this, () => MakeClipRequested?.Invoke(this, EventArgs.Empty), () => model?.CutSelection(),
            () => model?.CutSelection(true), RequestRewrite);
        AutomationProperties.SetName(this, "Transcript. Select words to cut. Enter corrects spelling. Control K makes a clip.");
        repeater = new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 20 },
            ItemTemplate = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Grid ColumnSpacing='20' Padding='0,4'><Grid.ColumnDefinitions><ColumnDefinition Width='56'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions><TextBlock FontSize='12' TextAlignment='Right' VerticalAlignment='Top' Margin='0,5,0,0' TextWrapping='Wrap'/><Grid Grid.Column='1' MinWidth='480' MaxWidth='680' HorizontalAlignment='Left'><Border IsHitTestVisible='False'/><RichTextBlock IsTextSelectionEnabled='False' TextWrapping='Wrap'/><Border IsHitTestVisible='False'/></Grid></Grid></DataTemplate>")
        };
        repeater.ElementPrepared += Prepared;
        repeater.ElementClearing += (_, args) => { if (args.Element is Grid grid && realized.Remove(grid, out var visual)) visual.Overlay.Dispose(); };
        scroll = new ScrollViewer { Content = repeater, Padding = new Thickness(16, 16, 16, 24), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Content = scroll;
        scroll.ViewChanging += (_, _) => selectionFlyout.Hide();
        scroll.ViewChanged += (_, args) => { if (!args.IsIntermediate) ScheduleFlyout(); };
        KeyDown += SelectionKeyDown;
        KeyUp += (_, args) => { if (args.Key is Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Home or Windows.System.VirtualKey.End) ScheduleFlyout(); };
        ActualThemeChanged += (_, _) => RefreshVisuals();
        Loaded += (_, _) => { Ui.EffectsChanged += EffectsChanged; if (pendingReveal >= 0) RevealWord(pendingReveal); };
        Unloaded += (_, _) => { Ui.EffectsChanged -= EffectsChanged; correction.IsOpen = false; selectionFlyout.Hide(); };
    }
    private void EffectsChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(RefreshVisuals);
    internal void RevealWord(int wordIndex)
    {
        pendingReveal = wordIndex;
        if (!IsLoaded || model is null) return;
        pendingReveal = -1;
        for (var index = 0; index < model.Paragraphs.Count; index++)
        {
            var paragraph = model.Paragraphs[index];
            if (wordIndex < paragraph.StartIndex || wordIndex >= paragraph.StartIndex + paragraph.Count) continue;
            var element = repeater.GetOrCreateElement(index);
            repeater.UpdateLayout();
            element.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = Ui.EffectPolicy.Animations, VerticalAlignmentRatio = 0.2 });
            break;
        }
    }

    /// <summary>Segoe UI Variable Text at 19 epx is the Windows transcript default; design §4.1 (C4).</summary>
    internal static double DefaultFontSize => (double)Application.Current.Resources["VcTranscriptFontSize"];
    private static double LineHeight(double size) => size * (double)Application.Current.Resources["VcTranscriptLineHeight"] / DefaultFontSize;
    public void Attach(EditorViewModel viewModel)
    {
        fontSize = Math.Clamp(App.Services.Get("general.transcriptTextSize", DefaultFontSize), 13, 28);
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
        selectionFlyout.Hide();
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
        fontSize = reset ? DefaultFontSize : Math.Clamp(fontSize + delta, 13, 28);
        foreach (var visual in realized.Values) { visual.Text.FontSize = fontSize; visual.Text.LineHeight = LineHeight(fontSize); visual.Overlay.Invalidate(); }
        RefreshVisuals();
    }

    private void ScheduleFlyout() => selectionFlyout.Schedule(() => ShowSelectionFlyout(false));
    internal void HideSelectionFlyout() => selectionFlyout.Hide();

    private void ShowSelectionFlyout(bool keyboard)
    {
        if (model is null || !model.HasSelection || dragging || CorrectionOpen || !IsLoaded || FocusManager.GetFocusedElement(XamlRoot) is TextBox) return;
        var rectangles = new List<Windows.Foundation.Rect>();
        foreach (var visual in realized.Values)
            foreach (var run in visual.Runs.Where(run => run.Index >= model.SelectionStart && run.Index <= model.SelectionEnd))
                foreach (var rect in TranscriptOverlay.Bounds(run.Run))
                {
                    var bounds = visual.Text.TransformToVisual(this).TransformBounds(rect);
                    if (bounds.Bottom > 0 && bounds.Top < ActualHeight) rectangles.Add(bounds);
                }
        if (rectangles.Count == 0) return;
        var first = rectangles.OrderBy(rect => rect.Top).ThenBy(rect => rect.Left).First();
        var top = rectangles.Min(rect => rect.Top);
        var bottom = rectangles.Max(rect => rect.Bottom);
        var before = model.Clips.Any(clip => model.Index(clip.Clip.StartWordId) < model.SelectionStart && model.Index(clip.Clip.EndWordId) >= model.SelectionStart - 1);
        var after = model.Clips.Any(clip => model.Index(clip.Clip.StartWordId) <= model.SelectionEnd + 1 && model.Index(clip.Clip.EndWordId) > model.SelectionEnd);
        if (SelectionBarLayout.Below(top, bottom, ActualHeight, before, after) is not { } below) return;
        var cut = model.Words.Skip(model.SelectionStart).Take(model.SelectionEnd - model.SelectionStart + 1).Any(word => model.State!.CutWordIds.Contains(word.Id))
            || model.State!.Pauses.Any(pause => pause.AfterIndex >= model.SelectionStart && pause.AfterIndex < model.SelectionEnd && model.State.CutPauseIds.Contains(pause.Id));
        selectionFlyout.Show(new(first.X, top, Math.Max(1, first.Width), bottom - top), below, keyboard, !model.IsReadOnly && !model.Busy,
            cut, RewriteEntryPolicy.BuildEnabled && App.Services.Get("voiceLab.enabled", false), CanRewrite,
            model.Clips.FirstOrDefault(clip => model.Index(clip.Clip.StartWordId) == model.SelectionStart && model.Index(clip.Clip.EndWordId) == model.SelectionEnd) is { } existing
                ? $"Clip {existing.Number} already covers these words." : null);
    }

    private void SelectionKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == Windows.System.VirtualKey.Escape && selectionFlyout.IsOpen)
        {
            selectionFlyout.Hide(true); args.Handled = true;
        }
        else if (args.Key == Windows.System.VirtualKey.Application || args.Key == Windows.System.VirtualKey.F10 && InputState.Down(Windows.System.VirtualKey.Shift))
        {
            ShowSelectionFlyout(true); args.Handled = true;
        }
    }
    public void ApplySettings()
    {
        fontSize = Math.Clamp(App.Services.Get("general.transcriptTextSize", DefaultFontSize), 13, 28);
        Zoom(0); RefreshVisuals();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new TranscriptPeer(this);
    private sealed class TranscriptPeer(TranscriptView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override string GetClassNameCore() => "VoxClipTranscript";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Document;
    }
    private void ModelChanged(object? sender, EventArgs args)
    {
        var next = string.Join(";", model?.Clips.Select(clip => $"{clip.Id}:{clip.Clip.StartWordId}:{clip.Clip.EndWordId}:{clip.IsSuggested}:{clip.Id == model.State?.ActiveClipId}") ?? [])
            + "|" + string.Join(",", model?.State?.CutPauseIds.Order().ToArray() ?? [])
            + "|" + string.Join(",", model?.Project.VoiceLab.Segments.Select(segment => $"{segment.Id}:{segment.Enabled}:{segment.Replace.Start}:{segment.Replace.End}") ?? []);
        if (structure != next)
        {
            structure = next;
            repeater.ItemsSource = null;
            repeater.ItemsSource = model?.Paragraphs;
        }
        RefreshVisuals();
    }
    private void Announce(object? sender, string text) => Announce(text);
    /// <summary>Tell Narrator what an edit or a clip command did.</summary>
    internal void Announce(string text)
    {
        Ui.Announce(this, text, "edit");
    }
    private Brush Brush(string key) => Ui.ThemeBrush(this, key);
    private SolidColorBrush Transparent(string key)
    {
        var color = ((SolidColorBrush)Brush(key)).Color;
        color.A = 0;
        return new(color);
    }

    private void Prepared(ItemsRepeater sender, ItemsRepeaterElementPreparedEventArgs args)
    {
        if (model is null || args.Element is not Grid grid || args.Index >= model.Paragraphs.Count) return;
        var item = model.Paragraphs[args.Index];
        var gutter = (TextBlock)grid.Children[0];
        gutter.Text = item.Timecode + (item.Speaker is null ? "" : "\n" + item.Speaker);
        gutter.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
        gutter.FontSize = (double)Application.Current.Resources["VcTimecodeFontSize"];
        gutter.Foreground = Brush("VcTextTertiaryBrush");
        if (realized.Remove(grid, out var previous)) previous.Overlay.Dispose();
        var page = (Grid)grid.Children[1];
        var rich = (RichTextBlock)page.Children[1];
        rich.FontFamily = (FontFamily)Application.Current.Resources["ContentControlThemeFontFamily"];
        rich.FontSize = fontSize;
        rich.LineHeight = LineHeight(fontSize);
        var rtl = model.State?.Transcript.Language?.Split('-')[0] is "ar" or "he" or "fa" or "ur";
        rich.FlowDirection = rtl ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        Grid.SetColumn(gutter, rtl ? 1 : 0); Grid.SetColumn(page, rtl ? 0 : 1);
        grid.ColumnDefinitions[0].Width = rtl ? new GridLength(1, GridUnitType.Star) : new GridLength(56);
        grid.ColumnDefinitions[1].Width = rtl ? new GridLength(56) : new GridLength(1, GridUnitType.Star);
        rich.Blocks.Clear();
        var paragraph = new Paragraph();
        var runs = new List<WordRun>();
        var pauses = new List<PauseRun>();
        for (var index = item.StartIndex; index < item.StartIndex + item.Count; index++)
        {
            var before = 0;
            var after = 0;
            foreach (var clip in model.Clips.Where(clip => model.Index(clip.Clip.StartWordId) == index))
            {
                paragraph.Inlines.Add(new InlineUIContainer { Child = ClipBadge(clip) });
                before++;
            }
            if (model.IsAiWord(index) && (index == 0 || !model.IsAiWord(index - 1)))
            {
                var chip = new Border { Background = Brush("VcAccentSoftBrush"), CornerRadius = new CornerRadius(3), Margin = new Thickness(0, 0, 4, 0), Padding = new Thickness(3, 0, 3, 0),
                    Child = new TextBlock { Text = "AI", FontSize = 11, Foreground = Brush("VcAccentTextBrush"), FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"] } };
                AutomationProperties.SetName(chip, "AI modified");
                paragraph.Inlines.Add(new InlineUIContainer { Child = chip });
                before++;
            }
            var word = model.Words[index];
            var run = new Run { Text = model.DisplayText(word) + " " };
            paragraph.Inlines.Add(run);
            foreach (var clip in model.Clips.Where(clip => model.Index(clip.Clip.EndWordId) == index))
            {
                paragraph.Inlines.Add(new Run { Text = "]", Foreground = Brush(clip.Id == model.State?.ActiveClipId ? "VcAccentTextBrush" : "VcLineStrongBrush") });
                after++;
            }
            if (showPauses && model.State?.Pauses.FirstOrDefault(pause => pause.AfterIndex == index) is { } pause)
            {
                var label = TranscriptWordDecoration.VisiblePause(pause.Label);
                if (model.State.CutPauseIds.Contains(pause.Id))
                {
                    var chip = new Border { Background = Brush("VcPauseBackgroundBrush"), CornerRadius = new CornerRadius(6),
                        Child = new TextBlock { Text = label, FontSize = (double)Application.Current.Resources["VcPauseTokenFontSize"], FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"], Foreground = Brush("VcTextMutedBrush") } };
                    AutomationProperties.SetName(chip, TranscriptWordDecoration.PauseName(pause.Label, true));
                    chip.Tapped += (_, args) => { model.Apply(new EditOperation.Toggle(pause.Id)); args.Handled = true; };
                    var inline = new InlineUIContainer { Child = chip };
                    paragraph.Inlines.Add(inline);
                    pauses.Add(new(pause, inline, null));
                    after++;
                }
                else
                {
                    var pauseRun = new Run { Text = label, FontSize = (double)Application.Current.Resources["VcPauseTokenFontSize"], FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"], Foreground = Brush("VcTextMutedBrush") };
                    paragraph.Inlines.Add(pauseRun);
                    pauses.Add(new(pause, pauseRun, pauseRun));
                }
            }
            runs.Add(new(index, run, before, after));
        }
        rich.Blocks.Add(paragraph);
        var overlay = new TranscriptOverlay(rich, (FrameworkElement)page.Children[0], (FrameworkElement)page.Children[2]);
        realized[grid] = new(rich, runs, pauses, overlay);
        rich.SizeChanged -= ParagraphSizeChanged;
        rich.SizeChanged += ParagraphSizeChanged;
        rich.PointerPressed -= Pressed; rich.PointerPressed += Pressed;
        rich.PointerMoved -= Moved; rich.PointerMoved += Moved;
        rich.PointerReleased -= Released; rich.PointerReleased += Released;
        rich.DoubleTapped -= DoubleTappedWord; rich.DoubleTapped += DoubleTappedWord;
        rich.RightTapped -= WordContextRequested; rich.RightTapped += WordContextRequested;
        RefreshVisuals();
    }

    private FrameworkElement ClipBadge(ClipRow clip)
    {
        var selected = clip.Id == model?.State?.ActiveClipId;
        var contents = new Grid();
        if (clip.IsSuggested) contents.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            RadiusX = 4, RadiusY = 4, Stroke = Brush("VcLineStrongBrush"), StrokeThickness = 1, StrokeDashArray = [2, 2]
        });
        contents.Children.Add(new TextBlock { Text = clip.Number.ToString(System.Globalization.CultureInfo.InvariantCulture), FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"], HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Brush(selected ? "VcAccentOnBrush" : "VcTextSecondaryBrush") });
        var badge = new Border { Width = 16, Height = 16, Margin = new Thickness(0, 0, 6, 0), CornerRadius = new CornerRadius(4),
            Background = Brush(selected ? "VcAccentDefaultBrush" : "VcClipBadgeBackgroundBrush"),
            Child = contents };
        AutomationProperties.SetName(badge, $"Clip {clip.Number} starts");
        return badge;
    }

    private void ParagraphSizeChanged(object sender, SizeChangedEventArgs args)
    {
        foreach (var visual in realized.Values) visual.Overlay.Invalidate();
        RefreshVisuals();
    }

    public void RefreshVisuals()
    {
        if (model?.State is not { } state) return;
        var lowConfidence = App.Services.Get("general.showLowConfidence", false);
        foreach (var visual in realized.Values)
        {
            visual.Text.TextHighlighters.Clear();
            visual.Overlay.Clear(visual.Text.ActualWidth, visual.Text.ActualHeight);
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
                run.Run.TextDecorations = TextDecorations.None;
                var outside = state.ActiveClipId is { } id && state.Clips.FirstOrDefault(clip => clip.Id == id) is { } active &&
                    (run.Index < model.Index(active.StartWordId) || run.Index > model.Index(active.EndWordId));
                run.Run.Foreground = Brush(TranscriptWordDecoration.For(cut, outside, false, false, false, word.Text).Foreground);
            }
            if (textChanged)
            {
                visual.Overlay.Invalidate();
                var pauseAfter = visual.Pauses.ToDictionary(pause => pause.Pause.AfterIndex, pause => pause.Run?.Text);
                visual.HighlightStarts = TranscriptTextRanges.Starts(
                    visual.Runs.Select(run => run.Run.Text).ToArray(),
                    visual.Runs.Select(run => pauseAfter.GetValueOrDefault(run.Index)).ToArray(),
                    visual.Runs.Select(run => run.Before).ToArray(), visual.Runs.Select(run => run.After).ToArray());
                DispatcherQueue.TryEnqueue(RefreshVisuals);
            }
            for (var index = 0; index < visual.Runs.Count; index++)
            {
                var run = visual.Runs[index];
                var word = model.Words.ElementAtOrDefault(run.Index);
                if (word is null) continue;
                var selected = model.HasSelection && run.Index >= model.SelectionStart && run.Index <= model.SelectionEnd;
                var rewriting = run.Index >= model.RewriteStart && run.Index <= model.RewriteEnd;
                var playing = model.SourceTime >= word.Start && model.SourceTime < word.End;
                var length = run.Run.Text.TrimEnd().Length;
                var decoration = TranscriptWordDecoration.For(state.CutWordIds.Contains(word.Id), false, EditingAlgorithms.IsFillerText(model.DisplayText(word)),
                    lowConfidence && word.Conf is < 0.6, state.Corrections.ContainsKey(word.Id), word.Text);
                visual.Overlay.Word(run.Run, state.CutWordIds.Contains(word.Id) && showCuts, decoration.Filler, decoration.LowConfidence,
                    decoration.Corrected, model.IsAiWord(run.Index), playing, rewriting);
                if (length == 0 || TranscriptWordHighlight.For(selected && !rewriting, playing, Ui.HighContrast) is not { } highlight) continue;
                // Selected words draw in text.primary on the selection fill, which also overrides the cut and filler colours
                // (they fail contrast on it); High Contrast maps the fill to Highlight, so the text takes HighlightText.
                var highlighter = new TextHighlighter
                {
                    Background = playing ? Transparent(highlight.BackgroundBrush) : Brush(highlight.BackgroundBrush),
                    Foreground = highlight.ForegroundBrush == "SystemColorHighlightTextColor"
                        ? new SolidColorBrush((Windows.UI.Color)Application.Current.Resources[highlight.ForegroundBrush]) : Brush(highlight.ForegroundBrush)
                };
                highlighter.Ranges.Add(new TextRange { StartIndex = visual.HighlightStarts[index], Length = length });
                visual.Text.TextHighlighters.Add(highlighter);
            }
            foreach (var pause in visual.Pauses)
                if (state.CutPauseIds.Contains(pause.Pause.Id)) visual.Overlay.Strike(pause.Inline);
            foreach (var clip in model.Clips)
            {
                var first = model.Index(clip.Clip.StartWordId);
                var last = model.Index(clip.Clip.EndWordId);
                var covered = visual.Runs.Where(run => run.Index >= first && run.Index <= last).ToArray();
                if (covered.Length == 0) continue;
                var start = covered[0].Run.ContentStart.GetCharacterRect(LogicalDirection.Forward);
                var end = covered[^1].Run.ContentEnd.GetCharacterRect(LogicalDirection.Backward);
                visual.Overlay.Clip(start.Top, end.Bottom, clip.Id == state.ActiveClipId, clip.IsSuggested, visual.Text.FlowDirection == FlowDirection.RightToLeft ? visual.Text.ActualWidth + 8 : -10);
            }
            AutomationProperties.SetName(visual.Text, string.Join(" ", visual.Runs.Select(run => model.AccessibleWord(run.Index, lowConfidence)
                + (visual.Pauses.FirstOrDefault(pause => pause.Pause.AfterIndex == run.Index) is { } pause ? ", " + TranscriptWordDecoration.PauseName(pause.Pause.Label, state.CutPauseIds.Contains(pause.Pause.Id)) : ""))));
        }
    }

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
        selectionFlyout.Hide();
        if (model is null || sender is not RichTextBlock rich || !args.GetCurrentPoint(rich).Properties.IsLeftButtonPressed) return;
        var pointer = rich.GetPositionFromPoint(args.GetCurrentPoint(rich).Position);
        var pause = realized.Values.FirstOrDefault(value => value.Text == rich)?.Pauses.FirstOrDefault(value => pointer is not null && pointer.Offset >= value.Inline.ContentStart.Offset && pointer.Offset < value.Inline.ContentEnd.Offset);
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
        if (!dragging && model is not null && sender is RichTextBlock rich)
        {
            var index = Hit(rich, args.GetCurrentPoint(rich).Position);
            if (index >= 0)
            {
                var word = model.Words[index];
                var decoration = TranscriptWordDecoration.For(model.State!.CutWordIds.Contains(word.Id), false, EditingAlgorithms.IsFillerText(model.DisplayText(word)),
                    App.Services.Get("general.showLowConfidence", false) && word.Conf is < 0.6, model.State.Corrections.ContainsKey(word.Id), word.Text);
                ToolTipService.SetToolTip(rich, decoration.Tooltip.Length == 0 ? null : decoration.Tooltip);
            }
        }
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
        ScheduleFlyout();
    }
    private void DoubleTappedWord(object sender, DoubleTappedRoutedEventArgs args) { BeginCorrection(); args.Handled = true; }
    public void BeginCorrection()
    {
        selectionFlyout.Hide();
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
        selectionFlyout.Hide();
        var contextIndex = -1;
        InsertionAfterIndex = -1;
        if (sender is RichTextBlock rich && model is not null)
        {
            var index = Hit(rich, args.GetPosition(rich));
            contextIndex = index;
            if (index >= 0 && (!model.HasSelection || index < model.SelectionStart || index > model.SelectionEnd)) model.Select(index);
            var pointer = rich.GetPositionFromPoint(args.GetPosition(rich));
            var runs = realized.Values.FirstOrDefault(value => value.Text == rich)?.Runs;
            if (pointer is not null && runs is not null)
                for (var runIndex = 0; runIndex + 1 < runs.Count; runIndex++)
                {
                    var run = runs[runIndex].Run;
                    var end = run.ContentStart.Offset + run.Text.TrimEnd().Length;
                    if (pointer.Offset >= end && pointer.Offset < runs[runIndex + 1].Run.ContentStart.Offset &&
                        RewriteEntryPolicy.BetweenWords(model.Words, runs[runIndex].Index))
                        InsertionAfterIndex = runs[runIndex].Index;
                }
        }
        var menu = new MenuFlyout();
        void Add(string label, Action action, bool enabled = true, string? key = null) { var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled, KeyboardAcceleratorTextOverride = key ?? "" }; item.Click += (_, _) => action(); menu.Items.Add(item); }
        Add("Make clip", () => MakeClipRequested?.Invoke(this, EventArgs.Empty), model is { IsReadOnly: false, Busy: false, HasSelection: true });
        if (RewriteEntryPolicy.BuildEnabled && App.Services.Get("voiceLab.enabled", false))
        {
            Add("Rewrite…", RequestRewrite, CanRewrite, "Ctrl+R");
            if (InsertionAfterIndex >= 0)
                Add("Insert Words…", () => InsertWordsRequested?.Invoke(this, EventArgs.Empty), InsertWordsRequested is not null &&
                    RewriteEntryPolicy.Resolve(RewriteEntry.InsertWords, true, model is { IsReadOnly: false, Busy: false, IsLeaving: false },
                        false, true, RewriteEntryPolicy.BuildEnabled) == RewriteEntryAction.OpenInsertion);
        }
        Add("Cut", () => model?.CutSelection());
        Add("Restore", () => model?.CutSelection(true));
        Add("Correct spelling…", BeginCorrection);
        Add("Play from here", () => { if (contextIndex >= 0) model?.Select(contextIndex); PlayRequested?.Invoke(this, EventArgs.Empty); }, model is { IsReadOnly: false, Busy: false });
        Add("Preview This Cut", () => PreviewCutRequested?.Invoke(this, EventArgs.Empty), model?.CanPreviewCut == true, "P");
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
