using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Controls;

public sealed partial class TranscriptView : UserControl
{
    private readonly ItemsRepeater repeater;
    private readonly ScrollViewer scroll;
    private int pendingReveal = -1;
    private readonly SelectionFlyout selectionFlyout;
    private readonly Dictionary<Grid, ParagraphVisual> realized = [];
    internal ScrollViewer FrameProbeScrollHost => scroll;
    internal int FrameProbeRealizedParagraphs => realized.Count;
    internal Action<double>? FrameProbePrepared { get; set; }
    private EditorViewModel? model;
    private bool dragging;
    private bool showCuts;
    private bool showPauses = true;
    private double fontSize = DefaultFontSize;
    private StackPanel? inlineEditor;
    private sealed record WordRun(int Index, Run Run, int LastIndex);
    private sealed record PauseRun(Pause Pause, Inline Inline, Run? Run);
    private sealed record DisplayRun(Inline Inline, TranscriptPiece Piece);
    private sealed record ParagraphVisual(RichTextBlock Text, List<WordRun> Runs, List<PauseRun> Pauses, TranscriptOverlay Overlay,
        Grid Root, Canvas Glyphs, StackPanel Editor, TranscriptParagraph Item, List<DisplayRun> Display)
    {
        internal int[] HighlightStarts { get; set; } = [];
        internal TranscriptTextSpan[] TextMap { get; set; } = [];
        internal EventHandler<object>? LayoutHandler { get; set; }
        internal bool Released { get; private set; }
        internal void Release()
        {
            Released = true;
            if (LayoutHandler is not null) Text.LayoutUpdated -= LayoutHandler;
            Overlay.Dispose();
        }
    }
    public bool CorrectionOpen => inlineEditor is not null;
    internal bool CanRewrite => RewriteRequested is not null && model is { IsReadOnly: false, Busy: false, IsLeaving: false, HasSelection: true };
    internal int InsertionAfterIndex => -1;
    internal void RequestRewrite()
    {
        if (model is null) return;
        if (CanRewrite) RewriteRequested?.Invoke(this, EventArgs.Empty);
        else if (RewriteRequested is null) { model.Notice = "Rewrite is not available in this build."; Announce(model.Notice); }
    }
#if DEBUG
    private bool debugGlyphOnly;
    internal int DebugRealizedParagraphs => realized.Count;
    internal void DebugScroll(double fraction)
    {
        scroll.ChangeView(null, scroll.ScrollableHeight * fraction, null, true);
        UpdateLayout();
    }
    internal object DebugGeometry => realized.Values.Select(visual => new { Overlay = visual.Overlay.DebugDiagnostics,
        Words = visual.Runs.Select(word => new { word.Index, word.Run.Text, Start = word.Run.ContentStart.Offset,
            End = word.Run.ContentEnd.Offset, Highlight = visual.HighlightStarts[visual.Runs.IndexOf(word)],
            Bounds = TranscriptOverlay.Bounds(word.Run), Cached = visual.Overlay.DebugCached(word.Run) }) });
    internal Windows.Foundation.Rect? DebugWordBounds(int index)
    {
        foreach (var visual in realized.Values)
        {
            if (visual.Runs.FirstOrDefault(run => run.Index <= index && run.LastIndex >= index) is { } word && TranscriptOverlay.Bounds(word.Run).FirstOrDefault() is { Width: > 0 } bounds)
                return visual.Text.TransformToVisual(this).TransformBounds(bounds);
            if (visual.Display.FirstOrDefault(display => display.Piece.Kind == TranscriptPieceKind.Fold && display.Piece.First <= index && display.Piece.Last >= index) is { } fold
                && TranscriptOverlay.Bounds(fold.Inline).FirstOrDefault() is { Width: > 0 } foldedBounds)
                return visual.Text.TransformToVisual(this).TransformBounds(foldedBounds);
        }
        return null;
    }
    internal void DebugGlyphOnly(int index)
    {
        debugGlyphOnly = true;
        foreach (var visual in realized.Values)
        {
            visual.Text.TextHighlighters.Clear();
            visual.Overlay.Clear(visual.Text.ActualWidth, visual.Text.ActualHeight);
            foreach (var word in visual.Runs)
                word.Run.Foreground = new SolidColorBrush(word.Index == index ? Windows.UI.Color.FromArgb(255, 0, 255, 0) : Windows.UI.Color.FromArgb(0, 0, 0, 0));
        }
    }
    internal void DebugEndGlyph() { debugGlyphOnly = false; RefreshVisuals(); }
    internal void DebugHideGlyphs(bool retainDecorations = false)
    {
        debugGlyphOnly = true;
        foreach (var visual in realized.Values)
        {
            visual.Text.TextHighlighters.Clear();
            if (!retainDecorations) visual.Overlay.DebugClearAbove();
            foreach (var word in visual.Runs)
                word.Run.Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
        }
    }
    internal void DebugRemovePaint(bool strike)
    {
        foreach (var visual in realized.Values)
            if (strike) visual.Overlay.DebugClearAbove(); else visual.Overlay.DebugClearCaret();
    }
    internal Windows.Foundation.Rect? DebugPlayheadBounds => realized.Values
        .Where(visual => visual.Overlay.DebugCaretBounds is not null)
        .Select(visual => (Windows.Foundation.Rect?)visual.Text.TransformToVisual(this).TransformBounds(visual.Overlay.DebugCaretBounds!.Value))
        .FirstOrDefault();
#endif
    public event EventHandler? SeekRequested;
    public event EventHandler? MakeClipRequested;
    public event EventHandler? PlayRequested;
    public event EventHandler? PreviewCutRequested;
    public event EventHandler? RewriteRequested;
    private EventHandler? unsupportedInsertionSubscriber;
    public event EventHandler? InsertWordsRequested
    {
        add => unsupportedInsertionSubscriber += value;
        remove => unsupportedInsertionSubscriber -= value;
    }

    public TranscriptView()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        selectionFlyout = new(this, () => MakeClipRequested?.Invoke(this, EventArgs.Empty), () => model?.CutSelection(),
            () => model?.CutSelection(true), RequestRewrite);
        selectionFlyout.Tones = () => model is { ShowsToneStrip: true } editor ? editor.RewriteStripItems : [];
        selectionFlyout.RewriteAs = item => model?.RewriteSelectionAs(item);
        AutomationProperties.SetAutomationId(this, "Editor.Transcript");
        AutomationProperties.SetName(this, "Transcript. Select words to cut. Enter corrects spelling. F2 edits a proposed change. Control Alt K makes a clip.");
        repeater = new ItemsRepeater
        {
            Layout = new StackLayout { Spacing = 14 },
            ItemTemplate = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><Grid Padding='0,8'><Grid.ColumnDefinitions><ColumnDefinition Width='80'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions><Grid><TextBlock Width='42' FontSize='12' TextAlignment='Right' VerticalAlignment='Top' HorizontalAlignment='Left' TextWrapping='Wrap'/><Canvas IsHitTestVisible='False'/></Grid><Grid Grid.Column='1' MaxWidth='724' Margin='0,0,44,0' HorizontalAlignment='Stretch'><Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/></Grid.RowDefinitions><Border IsHitTestVisible='False'/><RichTextBlock IsTextSelectionEnabled='False' TextWrapping='Wrap'/><Border IsHitTestVisible='False'/><StackPanel Grid.Row='1' Spacing='8'/></Grid></Grid></DataTemplate>")
        };
        repeater.ElementPrepared += Prepared;
        repeater.ElementClearing += (_, args) => { if (args.Element is Grid grid && realized.Remove(grid, out var visual)) visual.Release(); };
        scroll = new ScrollViewer { Content = repeater, Padding = new Thickness(0, 8, 0, 24), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var buffer = new Grid();
        buffer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buffer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
        buffer.Children.Add(scroll);
        Grid.SetColumn(overview, 1);
        buffer.Children.Add(overview);
        overview.SizeChanged += (_, _) => RefreshOverview();
        Content = buffer;
        scroll.ViewChanging += (_, _) => selectionFlyout.Hide();
        scroll.ViewChanged += (_, args) => { if (!args.IsIntermediate) ScheduleFlyout(); };
        KeyDown += SelectionKeyDown;
        KeyUp += (_, args) => { if (args.Key is Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right or Windows.System.VirtualKey.Home or Windows.System.VirtualKey.End) ScheduleFlyout(); };
        ActualThemeChanged += (_, _) => RebuildThemeVisuals();
        Loaded += (_, _) => { Ui.EffectsChanged += EffectsChanged; RefreshVisuals(); if (pendingReveal >= 0) RevealWord(pendingReveal); };
        Unloaded += (_, _) => { Ui.EffectsChanged -= EffectsChanged; model?.EndCorrection(); CloseInlineEditor(false); selectionFlyout.Hide(); };
    }
    private void EffectsChanged(object? sender, EventArgs args)
    {
        DispatcherQueue.TryEnqueue(RebuildThemeVisuals);
        EventHandler<object>? rendered = null;
        rendered = (_, _) =>
        {
            CompositionTarget.Rendering -= rendered;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (!IsLoaded) return;
                RebuildThemeVisuals();
#if DEBUG
                Ui.TraceEffects("transcript-post-render", this);
#endif
            });
        };
        CompositionTarget.Rendering += rendered;
    }
    private void RebuildThemeVisuals()
    {
        // Inline pauses, clip brackets and badge children also own resolved brushes.
        // Reprepare realized paragraphs only on a theme/effects change.
        RebuildRealized();
        RefreshVisuals();
        RefreshOverview();
    }
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
    /// <summary>After a keyboard move: scroll as little as needed to keep the caret word on screen, and tell Narrator the
    /// caret word and the selection's size (design §15). Select All announces without scrolling.</summary>
    internal void SelectionMovedByKeyboard(bool reveal = true)
    {
        if (model is null || !model.HasSelection) return;
        if (reveal) KeepWordInView(model.SelectionCaret);
        Ui.Announce(this, model.SelectionAnnouncement(App.Services.Get("general.showLowConfidence", false)), "selection");
    }
    private void KeepWordInView(int wordIndex)
    {
        if (!IsLoaded || model is null) return;
        for (var index = 0; index < model.Paragraphs.Count; index++)
        {
            var paragraph = model.Paragraphs[index];
            if (wordIndex < paragraph.StartIndex || wordIndex >= paragraph.StartIndex + paragraph.Count) continue;
            var element = repeater.GetOrCreateElement(index);
            repeater.UpdateLayout();
            var options = new BringIntoViewOptions { AnimationDesired = Ui.EffectPolicy.Animations };
            if (element is Grid grid && realized.TryGetValue(grid, out var visual) && visual.Runs.FirstOrDefault(run => run.Index <= wordIndex && run.LastIndex >= wordIndex) is { } word
                && TranscriptOverlay.Bounds(word.Run).FirstOrDefault() is { Width: > 0 } bounds)
            {
                options.TargetRect = new Windows.Foundation.Rect(bounds.X, bounds.Y - bounds.Height, bounds.Width, bounds.Height * 3);
                visual.Text.StartBringIntoView(options);
            }
            else element.StartBringIntoView(options);
            break;
        }
    }

    /// <summary>V2 maps the 15/26 body to Segoe UI Variable at 16 epx.</summary>
    internal static double DefaultFontSize => 16;
    private static double LineHeight(double size) => size * 26 / 16;
    public void Attach(EditorViewModel viewModel)
    {
        fontSize = Math.Clamp(App.Services.Get("general.transcriptTextSize", DefaultFontSize), 13, 28);
        model?.EndCorrection();
        if (model is not null) { model.Changed -= ModelChanged; model.SelectionChanged -= SelectionChanged; model.Announcement -= Announce; model.CorrectionChanged -= CorrectionChanged; }
        CloseInlineEditor(false);
        DetachProposal();
        KeepChangeRequested = null; ExcludeChangeRequested = null; EditChangeRequested = null;
        model = viewModel;
        model.Changed += ModelChanged;
        model.SelectionChanged += SelectionChanged;
        model.Announcement += Announce;
        model.CorrectionChanged += CorrectionChanged;
        expandedCuts.Clear();
        presentationState = null;
        presentationProject = null;
        ModelChanged(this, EventArgs.Empty);
    }
    public void Detach()
    {
        model?.EndCorrection();
        if (model is not null) { model.Changed -= ModelChanged; model.SelectionChanged -= SelectionChanged; model.Announcement -= Announce; model.CorrectionChanged -= CorrectionChanged; }
        CloseInlineEditor(false);
        DetachProposal();
        KeepChangeRequested = null; ExcludeChangeRequested = null; EditChangeRequested = null;
        selectionFlyout.Hide();
        foreach (var visual in realized.Values) visual.Release();
        realized.Clear();
        repeater.ItemsSource = null;
        model = null;
    }
    public void SetDisplay(bool cutWords, bool pauses)
    {
        if (showCuts == cutWords && showPauses == pauses) return;
        showCuts = cutWords;
        showPauses = pauses;
        CloseInlineEditor(false);
        RebuildRealized();
        if (model?.HasSelection == true) KeepWordInView(model.SelectionCaret);
        ShowCutsChanged?.Invoke(this, EventArgs.Empty);
    }
    public bool ShowCuts => showCuts;
    public event EventHandler? ShowCutsChanged;
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
            foreach (var run in visual.Runs.Where(run => run.LastIndex >= model.SelectionStart && run.Index <= model.SelectionEnd))
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
            cut, RewriteRequested is not null, CanRewrite,
            model.Clips.FirstOrDefault(clip => model.Index(clip.Clip.StartWordId) == model.SelectionStart && model.Index(clip.Clip.EndWordId) == model.SelectionEnd) is { } existing
                ? $"Clip {existing.Number} already covers these words." : null);
    }

    private void SelectionKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (InputState.IsTextFocus(FocusManager.GetFocusedElement(XamlRoot))) return;
        if (HandleProposalKey(args)) return;
        if (args.Key == Windows.System.VirtualKey.Escape && selectionFlyout.IsOpen)
        {
            selectionFlyout.Hide(true); args.Handled = true;
        }
        else if (args.Key == Windows.System.VirtualKey.Application || args.Key == Windows.System.VirtualKey.F10 && InputState.Down(Windows.System.VirtualKey.Shift))
        {
            ShowSelectionFlyout(true); args.Handled = true;
        }
        else if (args.Key is Windows.System.VirtualKey.PageDown or Windows.System.VirtualKey.PageUp)
        {
            var page = Math.Max(LineHeight(fontSize), scroll.ViewportHeight - LineHeight(fontSize));
            scroll.ChangeView(null, scroll.VerticalOffset + (args.Key == Windows.System.VirtualKey.PageDown ? page : -page), null, !Ui.EffectPolicy.Animations);
            args.Handled = true;
        }
    }
    public void ApplySettings()
    {
        fontSize = Math.Clamp(App.Services.Get("general.transcriptTextSize", DefaultFontSize), 13, 28);
        Zoom(0); RefreshVisuals();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new TranscriptPeer(this);
    /// <summary>The transcript's value is the caret word and the selection's size, so Narrator says where the caret is when
    /// focus comes back to the transcript. Keyboard moves announce it as a notification, not as a value change, so it is
    /// not spoken twice.</summary>
    private sealed class TranscriptPeer(TranscriptView owner) : FrameworkElementAutomationPeer(owner), IValueProvider
    {
        protected override string GetClassNameCore() => "VoxClipTranscript";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Document;
        protected override object GetPatternCore(PatternInterface pattern) => pattern == PatternInterface.Value ? this : base.GetPatternCore(pattern);
        public bool IsReadOnly => true;
        public string Value => owner.model?.SelectionAnnouncement(App.Services.Get("general.showLowConfidence", false)) is { Length: > 0 } text ? text : "No words selected";
        public void SetValue(string value) => throw new InvalidOperationException("The transcript is edited with its own commands.");
    }
    private void ModelChanged(object? sender, EventArgs args)
    {
        if (model?.State is not { } state) return;
        if (!ReferenceEquals(presentationState, state) || !ReferenceEquals(presentationProject, model.Project))
        {
            presentationState = state;
            presentationProject = model.Project;
            pausesByIndex = state.Pauses.ToDictionary(pause => pause.AfterIndex);
            CloseInlineEditor(false);
            if (proposalSession is { IsOpen: false } || !ReferenceEquals(proposalProject, model.Project)) DetachProposal();
            RebuildRealized();
        }
        if (!ReferenceEquals(repeater.ItemsSource, model.Paragraphs)) repeater.ItemsSource = model.Paragraphs;
        RefreshVisuals();
        RefreshOverview();
    }
    private void Announce(object? sender, string text) => Announce(text);
    /// <summary>Tell Narrator what an edit or a clip command did.</summary>
    internal void Announce(string text)
    {
        Ui.Announce(this, text, "edit");
    }
    private Brush Brush(string key) => Ui.ThemeBrush(this, key);
    private void Prepared(ItemsRepeater sender, ItemsRepeaterElementPreparedEventArgs args)
    {
        if (model is null || args.Element is not Grid grid || args.Index >= model.Paragraphs.Count) return;
        PrepareParagraph(grid, model.Paragraphs[args.Index]);
    }

    private void ParagraphSizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (realized.Values.FirstOrDefault(visual => ReferenceEquals(visual.Text, sender)) is not { } changed) return;
        changed.Overlay.Invalidate();
        RefreshParagraph(changed);
    }

    private void ParagraphLayoutUpdated(ParagraphVisual changed)
    {
        if (changed.Overlay.NeedsLayout)
            changed.Overlay.DrawAfterLayout(() => RefreshParagraph(changed));
    }

    public void RefreshVisuals()
    {
#if DEBUG
        if (debugGlyphOnly) return;
#endif
        if (model?.State is null) return;
        scroll.Background = Brush("VcBgSurfaceBrush");
        foreach (var visual in realized.Values) RefreshParagraph(visual);
    }

    private void RefreshParagraph(ParagraphVisual visual) => DrawParagraph(visual);

    private int Hit(RichTextBlock rich, Windows.Foundation.Point point)
    {
        var pointer = rich.GetPositionFromPoint(point);
        var visual = realized.Values.FirstOrDefault(value => value.Text == rich);
        if (pointer is null || visual is null) return -1;
        return TranscriptTextRanges.Hit(visual.TextMap, pointer.Offset)?.SourceIndex ?? -1;
    }
    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        selectionFlyout.Hide();
        if (model is null || sender is not RichTextBlock rich || !args.GetCurrentPoint(rich).Properties.IsLeftButtonPressed) return;
        var pointer = rich.GetPositionFromPoint(args.GetCurrentPoint(rich).Position);
        var visual = realized.Values.FirstOrDefault(value => value.Text == rich);
        var display = pointer is null || visual is null ? null : HitPiece(visual, pointer.Offset);
        if (display?.Piece.Kind == TranscriptPieceKind.Inserted && display.Piece.Change is { } inserted)
        {
            FocusChange(inserted.Ordinal, false);
            Focus(FocusState.Pointer);
            args.Handled = true;
            return;
        }
        var previousFocus = focusedChange;
        if (display?.Piece.Change is { } change) focusedChange = change.Ordinal;
        else focusedChange = 0;
        var pause = realized.Values.FirstOrDefault(value => value.Text == rich)?.Pauses.FirstOrDefault(value => pointer is not null && pointer.Offset >= value.Inline.ContentStart.Offset && pointer.Offset < value.Inline.ContentEnd.Offset);
        if (pause is not null) { if (CanEditTranscript) model.Apply(new EditOperation.Toggle(pause.Pause.Id)); args.Handled = true; return; }
        var index = Hit(rich, args.GetCurrentPoint(rich).Position);
        if (index < 0) return;
        Focus(FocusState.Pointer);
        model.Select(index, InputState.Down(Windows.System.VirtualKey.Shift));
        if (model.PresentedWord(index).LastSourceIndex > index) model.Select(model.PresentedWord(index).LastSourceIndex, true);
        if (focusedChange != previousFocus)
        {
            RebuildRealized();
            if (focusedChange > 0) ChangeFocused?.Invoke(focusedChange);
        }
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
        if (focusedChange > 0 && proposal.Hunks.Any(hunk => hunk.Ordinal == focusedChange)) BeginProposalCorrection();
        else BeginWordCorrection();
    }
    private void WordContextRequested(object sender, RightTappedRoutedEventArgs args)
    {
        selectionFlyout.Hide();
        var contextIndex = -1;
        if (sender is RichTextBlock rich && model is not null)
        {
            var hitPointer = rich.GetPositionFromPoint(args.GetPosition(rich));
            var hitVisual = realized.Values.FirstOrDefault(value => value.Text == rich);
            if (hitPointer is not null && hitVisual is not null && HitPiece(hitVisual, hitPointer.Offset)?.Piece is { Kind: TranscriptPieceKind.Inserted, Change: { } inserted })
            {
                FocusChange(inserted.Ordinal, false);
                args.Handled = true;
                return;
            }
            var index = Hit(rich, args.GetPosition(rich));
            contextIndex = index;
            if (index >= 0 && (!model.HasSelection || index < model.SelectionStart || index > model.SelectionEnd)) model.Select(index);
        }
        var menu = new MenuFlyout();
        void Add(string label, Action action, bool enabled = true, string? key = null) { var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled, KeyboardAcceleratorTextOverride = key ?? "" }; item.Click += (_, _) => action(); menu.Items.Add(item); }
        Add("Make clip", () => MakeClipRequested?.Invoke(this, EventArgs.Empty), model is { IsReadOnly: false, Busy: false, HasSelection: true });
        if (RewriteRequested is not null)
        {
            Add("Rewrite…", RequestRewrite, CanRewrite, "Ctrl+R");
        }
        Add("Cut", () => model?.CutSelection());
#if DEBUG
        if (model is not null)
        {
            var voiceLab = DebugVoiceLabActions.For(model, App.Services.Get("voiceLab.enabled", false));
            if (voiceLab.Actions.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
            foreach (var action in voiceLab.Actions)
            {
                MenuFlyoutItemBase item;
                if (action.Command is VoiceLabEditCommand.ChooseCandidate)
                {
                    var candidate = new ToggleMenuFlyoutItem { Text = action.Label, IsChecked = action.Selected };
                    candidate.Click += (_, _) => voiceLab.Apply(model, action, App.Services.Get("voiceLab.enabled", false));
                    item = candidate;
                }
                else
                {
                    var operation = new MenuFlyoutItem { Text = action.Label };
                    operation.Click += (_, _) => voiceLab.Apply(model, action, App.Services.Get("voiceLab.enabled", false));
                    item = operation;
                }
                AutomationProperties.SetAutomationId(item, action.Id);
                menu.Items.Add(item);
            }
        }
#endif
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
