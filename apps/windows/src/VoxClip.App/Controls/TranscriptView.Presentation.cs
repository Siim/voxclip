using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Windows.Foundation;

namespace VoxClip.App.Controls;

public sealed partial class TranscriptView
{
    private EditState? presentationState;
    private Project? presentationProject;
    private IReadOnlyDictionary<int, Pause> pausesByIndex = new Dictionary<int, Pause>();
    private readonly HashSet<string> expandedCuts = new(StringComparer.Ordinal);
    private readonly Canvas overview = new() { IsHitTestVisible = false };
    private TranscriptProposalPresentation proposal = TranscriptProposalPresentation.Empty;
    private RewriteSession? proposalSession;
    private Project? proposalProject;
    private int focusedChange;
    private IReadOnlyDictionary<int, TranscriptChangeState>? proposalStates;
    internal Action<int>? KeepChangeRequested { get; set; }
    internal Action<int>? ExcludeChangeRequested { get; set; }
    internal event Action<int>? ChangeFocused;
    internal int FocusedChange => focusedChange;

    internal void AttachProposal(RewriteSession? session)
    {
        if (ReferenceEquals(proposalSession, session)) { ProposalChanged(this, EventArgs.Empty); return; }
        DetachProposal();
        proposalSession = session;
        if (session is not null) session.Changed += ProposalChanged;
        ProposalChanged(this, EventArgs.Empty);
    }

    internal void SetProposal(RewriteReview? review, IReadOnlyList<TimedWord> source, int? insertionAfter = null,
        IReadOnlyDictionary<int, TranscriptChangeState>? states = null)
    {
        proposalStates = states;
        proposalProject = model?.Project;
        proposal = review is null || model is null ? TranscriptProposalPresentation.Empty
            : TranscriptProposalPresentation.From(review.Diff, source, model.Words, insertionAfter, states);
        if (!proposal.Hunks.Any(hunk => hunk.Ordinal == focusedChange)) focusedChange = 0;
        RebuildRealized();
        RefreshOverview();
    }

    private void ProposalChanged(object? sender, EventArgs args)
    {
        if (proposalSession is { IsOpen: true } session && model is not null && ReferenceEquals(session.Project, model.Project))
            SetProposal(session.Review, session.Source, session.InsertionAfter, proposalStates);
        else SetProposal(null, []);
    }

    private void DetachProposal()
    {
        if (proposalSession is not null) proposalSession.Changed -= ProposalChanged;
        proposalSession = null;
        proposalProject = null;
        proposalStates = null;
        proposal = TranscriptProposalPresentation.Empty;
        focusedChange = 0;
    }

    private (int First, int Last, bool Suggested) ClipExtent()
    {
        if (model?.State?.ActiveClipId is not { } id || model.Clips.FirstOrDefault(clip => clip.Id == id) is not { } active)
            return (0, (model?.Words.Count ?? 0) - 1, false);
        return (model.Index(active.Clip.StartWordId), model.Index(active.Clip.EndWordId), active.IsSuggested);
    }

    private void RebuildRealized()
    {
        foreach (var pair in realized.ToArray()) PrepareParagraph(pair.Key, pair.Value.Item);
    }

    private void SelectionChanged(object? sender, EventArgs args)
    {
        var changed = false;
        if (model?.HasSelection == true)
            foreach (var visual in realized.Values)
                foreach (var display in visual.Display)
                    if (display.Piece is { Kind: TranscriptPieceKind.Fold } fold && fold.Last >= model.SelectionStart && fold.First <= model.SelectionEnd)
                        foreach (var id in (fold.WordIds ?? []).Concat(fold.PauseIds ?? [])) changed |= expandedCuts.Add(id);
        if (changed) RebuildRealized();
        RefreshVisuals();
        RefreshOverview();
    }

    private void PrepareParagraph(Grid grid, TranscriptParagraph item)
    {
        if (model?.State is not { } state || item.StartIndex >= model.Words.Count) return;
        var started = FrameProbePrepared is null ? 0 : System.Diagnostics.Stopwatch.GetTimestamp();
        if (realized.Remove(grid, out var previous)) previous.Release();
        var gutter = (Grid)grid.Children[0];
        Canvas.SetZIndex(gutter, 1);
        var timecode = (TextBlock)gutter.Children[0];
        timecode.Text = FormatTakeTime(model.Words[item.StartIndex].Start) + (item.Speaker is null ? "" : "\n" + item.Speaker);
        timecode.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
        timecode.Foreground = Brush("VcGutterTextBrush");
        var glyphs = (Canvas)gutter.Children[1];
        glyphs.Children.Clear();
        glyphs.Tag = null;
        var page = (Grid)grid.Children[1];
        var rich = (RichTextBlock)page.Children[1];
        rich.HighContrastAdjustment = ElementHighContrastAdjustment.None;
        rich.FontFamily = (FontFamily)Application.Current.Resources["ContentControlThemeFontFamily"];
        rich.FontSize = fontSize;
        rich.LineHeight = LineHeight(fontSize);
        rich.FlowDirection = state.Transcript.Language?.Split('-')[0] is "ar" or "he" or "fa" or "ur"
            ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        var rtl = rich.FlowDirection == FlowDirection.RightToLeft;
        Grid.SetColumn(gutter, rtl ? 1 : 0); Grid.SetColumn(page, rtl ? 0 : 1);
        grid.ColumnDefinitions[0].Width = rtl ? new GridLength(1, GridUnitType.Star) : new GridLength(80);
        grid.ColumnDefinitions[1].Width = rtl ? new GridLength(80) : new GridLength(1, GridUnitType.Star);
        page.Margin = rtl ? new Thickness(44, 0, 0, 0) : new Thickness(0, 0, 44, 0);
        timecode.HorizontalAlignment = rtl ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        timecode.TextAlignment = rtl ? TextAlignment.Left : TextAlignment.Right;
        var editor = (StackPanel)page.Children[3];
        if (ReferenceEquals(inlineEditor, editor)) CloseInlineEditor(false);
        ClearEditorHost(editor);
        rich.Blocks.Clear();
        var paragraph = new Paragraph();
        var runs = new List<WordRun>();
        var pauses = new List<PauseRun>();
        var displays = new List<DisplayRun>();
        var extent = ClipExtent();
        var pieces = TranscriptParagraphPresentation.Build(model.Words, item.StartIndex, item.Count, model.PresentedWord,
            state.CutWordIds, state.CutPauseIds, pausesByIndex, extent.First, extent.Last, showCuts, showPauses, expandedCuts, proposal,
            model.HasSelection ? model.SelectionStart : -1, model.HasSelection ? model.SelectionEnd : -1);
        var actionsAfter = pieces.LastOrDefault(piece => piece.Change?.Ordinal == focusedChange);
        foreach (var piece in pieces)
        {
            Inline inline;
            if (piece.Kind == TranscriptPieceKind.Fold)
            {
                paragraph.Inlines.Add(new Run { Text = "\u2060" });
                var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 5, Height = 5, Fill = Brush("VcFoldDotBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
                var halo = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 11, Height = 11, Fill = Brush("VcTextSecondaryBrush"),
                    Opacity = 0.18, Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
                var ink = new Grid { Width = 13, Height = 13 };
                ink.Children.Add(halo); ink.Children.Add(dot);
                var button = new Button { Content = ink, Width = 13, MinWidth = 0, Height = LineHeight(fontSize), MinHeight = 0,
                    Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
                AutomationProperties.SetName(button, piece.FoldName + ". Expand or restore cut.");
                ToolTipService.SetToolTip(button, piece.FoldName + " · Click to expand");
                button.PointerEntered += (_, _) => { dot.Fill = Brush("VcTextSecondaryBrush"); halo.Visibility = Visibility.Visible; };
                button.PointerExited += (_, _) => { dot.Fill = Brush("VcFoldDotBrush"); halo.Visibility = Visibility.Collapsed; };
                button.Click += (_, _) => OpenFold(piece);
                inline = new InlineUIContainer { Child = button };
            }
            else
            {
                var run = new Run { Text = piece.Text };
                inline = run;
                if (piece.Selectable) runs.Add(new(piece.First, run, piece.Last));
                if (piece.Kind == TranscriptPieceKind.Pause)
                {
                    run.FontSize = 12;
                    run.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
                    if (pausesByIndex.TryGetValue(piece.Last, out var pause)) pauses.Add(new(pause, run, run));
                }
            }
            paragraph.Inlines.Add(inline);
            if (piece.Kind == TranscriptPieceKind.Fold) paragraph.Inlines.Add(new Run { Text = "\u200b" });
            displays.Add(new(inline, piece));
            if (ReferenceEquals(piece, actionsAfter) && piece.Change is { } focused)
            {
                var actions = ChangeActions(focused);
                if (actions.Children.Count > 0) paragraph.Inlines.Add(new InlineUIContainer { Child = actions });
            }
        }
        rich.Blocks.Add(paragraph);
        // The focused change's thread sits under the paragraph that holds its last piece (design.md §6.3 "Where").
        PlaceThread(editor, actionsAfter?.Change is not null);
        var overlay = new TranscriptOverlay(rich, (FrameworkElement)page.Children[0], (FrameworkElement)page.Children[2]);
        var visual = new ParagraphVisual(rich, runs, pauses, overlay, grid, glyphs, editor, item, displays);
        visual.HighlightStarts = runs.Select(run => run.Run.ContentStart.Offset - rich.ContentStart.Offset).ToArray();
        visual.TextMap = displays.Select(display => new TranscriptTextSpan(display.Inline.ContentStart.Offset, display.Inline.ContentEnd.Offset,
            display.Piece.Selectable ? display.Piece.First : -1, display.Piece.Selectable ? display.Piece.Last : -1, display.Piece.Change?.Ordinal ?? 0)).ToArray();
        visual.LayoutHandler = (_, _) => ParagraphLayoutUpdated(visual);
        rich.LayoutUpdated += visual.LayoutHandler;
        realized[grid] = visual;
        rich.SizeChanged -= ParagraphSizeChanged; rich.SizeChanged += ParagraphSizeChanged;
        rich.PointerPressed -= Pressed; rich.PointerPressed += Pressed;
        rich.PointerMoved -= Moved; rich.PointerMoved += Moved;
        rich.PointerReleased -= Released; rich.PointerReleased += Released;
        rich.PointerCaptureLost -= CaptureLost; rich.PointerCaptureLost += CaptureLost;
        rich.DoubleTapped -= DoubleTappedWord; rich.DoubleTapped += DoubleTappedWord;
        rich.RightTapped -= WordContextRequested; rich.RightTapped += WordContextRequested;
        AutomationProperties.SetName(rich, string.Join(" ", pieces.Select(piece => piece.Kind == TranscriptPieceKind.Fold ? piece.FoldName :
            piece.Change is { } hunk ? $"Proposed change {hunk.Ordinal} of {proposal.TotalCount}{hunk.Reviewed}: {piece.Text}" : piece.Text)));
        // Narrator's form of the Mac's custom actions on the focused change: WinUI has none, so the keys are in the paragraph's help. A
        // kept or left-out change has no thread to talk in.
        AutomationProperties.SetHelpText(rich, actionsAfter?.Change is { State: TranscriptChangeState.Pending } talked
            ?$"{RewriteThreadDisplay.TalkAction(talked.Ordinal)}: F2. {RewriteThreadDisplay.OwnWordsAction(talked.Ordinal)}: {RewriteThreadDisplay.OwnWordsKey}."
            : "");
        DrawParagraph(visual);
        if (FrameProbePrepared is { } report) report(System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds);
    }

    private void CaptureLost(object sender, PointerRoutedEventArgs args) => dragging = false;

    private void DrawParagraph(ParagraphVisual visual)
    {
#if DEBUG
        if (debugGlyphOnly) return;
#endif
        if (visual.Released || model?.State is not { } state) return;
        var extent = ClipExtent();
        visual.Overlay.Clear(visual.Text.ActualWidth, visual.Text.ActualHeight);
        var covered = visual.Display.Where(display => display.Piece.First >= 0 && display.Piece.Last >= extent.First && display.Piece.First <= extent.Last)
            .SelectMany(display => visual.Overlay.Rectangles(display.Inline)).ToArray();
        if (covered.Length > 0 && state.ActiveClipId is not null)
        {
            var rtl = visual.Text.FlowDirection == FlowDirection.RightToLeft;
            visual.Overlay.Band(covered.Min(rect => rect.Top), covered.Max(rect => rect.Bottom), visual.Text.ActualWidth, rtl);
            visual.Overlay.Clip(covered.Min(rect => rect.Top), covered.Max(rect => rect.Bottom), true, extent.Suggested, rtl ? visual.Text.ActualWidth + 70 : -72);
        }
        var lowConfidence = App.Services.Get("general.showLowConfidence", false);
        Dictionary<double, (Rect Bounds, TranscriptProposalHunk? Change, bool Ai)> lines = [];
        WordRun? caret = null;
        var caretAfter = false;
        foreach (var display in visual.Display)
        {
            var piece = display.Piece;
            var selected = piece.Selectable && model.HasSelection && piece.Last >= model.SelectionStart && piece.First <= model.SelectionEnd;
            if (display.Inline is Run run)
            {
                var highlight = TranscriptWordHighlight.For(selected, false, Ui.HighContrast);
                var key = highlight is { } selection ? selection.ForegroundBrush == "SystemColorHighlightTextColor" ? "VcAccentOnBrush" : selection.ForegroundBrush
                    : piece.Kind == TranscriptPieceKind.Inserted ? "VcTextPrimaryBrush"
                    : TranscriptWordDecoration.For(piece.Removed, piece.Outside, false, false, false, "").Foreground;
                SetForeground(run, key);
                if (piece.Kind == TranscriptPieceKind.Source)
                {
                    var word = model.Words[piece.First];
                    visual.Overlay.Word(run, piece.Removed, false, !piece.Outside && !piece.Ai && !piece.Removed && piece.Change is null && !selected && lowConfidence && word.Conf is < 0.6,
                        !piece.Outside && !piece.Ai && !piece.Removed && piece.Change is null && !selected && state.Corrections.ContainsKey(word.Id),
                        !piece.Outside && piece.Ai && proposal.Hunks.Count == 0, selected, false, false);
                    if (model.SourceTime >= word.Start && model.SourceTime < model.Words[piece.Last].End)
                    {
                        caret = visual.Runs.FirstOrDefault(item => ReferenceEquals(item.Run, run));
                        caretAfter = false;
                    }
                    else if (model.SourceTime >= model.Words[piece.Last].End &&
                        (piece.Last + 1 >= model.Words.Count || model.SourceTime < model.Words[piece.Last + 1].Start))
                    {
                        caret = visual.Runs.FirstOrDefault(item => ReferenceEquals(item.Run, run));
                        caretAfter = true;
                    }
                }
                else if (piece.Kind == TranscriptPieceKind.Inserted) visual.Overlay.Diff(run, RewriteDiffKind.Inserted);
            }
            if (piece.Outside) continue;
            foreach (var rectangle in visual.Overlay.Rectangles(display.Inline))
            {
                var line = Math.Round(rectangle.Top * 2) / 2;
                if (!lines.TryGetValue(line, out var previous)) lines[line] = (rectangle, piece.Change, piece.Ai);
                else
                {
                    var change = (piece.Change?.Priority ?? 0) > (previous.Change?.Priority ?? 0) ? piece.Change : previous.Change;
                    lines[line] = (new(Math.Min(previous.Bounds.Left, rectangle.Left), rectangle.Top,
                        Math.Max(previous.Bounds.Right, rectangle.Right) - Math.Min(previous.Bounds.Left, rectangle.Left), rectangle.Height), change, piece.Ai || previous.Ai);
                }
            }
        }
        if (caret is not null) visual.Overlay.Caret(caret.Run, caretAfter,
            model.HasSelection && caret.LastIndex >= model.SelectionStart && caret.Index <= model.SelectionEnd);
        var gutterText = (TextBlock)((Grid)visual.Root.Children[0]).Children[0];
        gutterText.Foreground = Brush(caret is not null ? "VcTextSecondaryBrush" : covered.Length > 0 ? "VcGutterTextBrush" : "VcGutterTextOutBrush");
        DrawGutter(visual, lines);
        if (visual.Overlay.NeedsLayout) visual.Overlay.DrawAfterLayout(() => DrawParagraph(visual));
    }

    private void SetForeground(Run run, string key)
    {
        var brush = Brush(key);
        if (run.Foreground is not SolidColorBrush current || brush is not SolidColorBrush next || current.Color != next.Color) run.Foreground = brush;
    }

    private void DrawGutter(ParagraphVisual visual, IReadOnlyDictionary<double, (Rect Bounds, TranscriptProposalHunk? Change, bool Ai)> lines)
    {
        var glyphs = new List<(double Top, string Text, string Brush)>();
        foreach (var line in lines.Values)
        {
            // A kept change keeps its words and its glyph but no bar: the bar marks what still waits for a review (design.md §6.3.5).
            if (line.Change is { State: not TranscriptChangeState.Kept } change) visual.Overlay.ChangeBar(line.Bounds, change.Ordinal == focusedChange, change.State == TranscriptChangeState.Excluded);
            if (line.Change is { } hunk) glyphs.Add((line.Bounds.Top, hunk.Priority == 3 ? "\u223f" : hunk.Priority == 2 ? "\u270e" : "\u2702", "VcTextTertiaryBrush"));
            else if (line.Ai) glyphs.Add((line.Bounds.Top, "\u223f", "VcAiWaveBrush"));
        }
        var signature = string.Join(";", glyphs.Select(glyph => $"{glyph.Top.ToString(CultureInfo.InvariantCulture)}:{glyph.Text}:{glyph.Brush}"));
        if (Equals(visual.Glyphs.Tag, signature)) return;
        visual.Glyphs.Tag = signature;
        visual.Glyphs.Children.Clear();
        foreach (var glyph in glyphs)
        {
            var text = new TextBlock { Text = glyph.Text, FontSize = 13, Foreground = Brush(glyph.Brush) };
            Canvas.SetLeft(text, visual.Text.FlowDirection == FlowDirection.RightToLeft ? 17 : 49); Canvas.SetTop(text, glyph.Top);
            visual.Glyphs.Children.Add(text);
        }
    }

    private static DisplayRun? HitPiece(ParagraphVisual visual, int offset) => visual.Display.FirstOrDefault(display =>
        offset >= display.Inline.ContentStart.Offset && offset < display.Inline.ContentEnd.Offset);

    private void RefreshOverview()
    {
        overview.Children.Clear();
        if (model is null || model.Words.Count == 0 || overview.ActualHeight <= 0) return;
        var duration = Math.Max(0.001, model.Words[^1].End);
        var extent = ClipExtent();
        if (extent.First >= 0 && extent.Last >= extent.First) Mark(extent.First, extent.Last, "VcClipLabelBrush", 1);
        if (model.HasSelection) Mark(model.SelectionStart, model.SelectionEnd, "VcAccentTextBrush", 4);
        foreach (var hunk in proposal.Hunks.Where(hunk => hunk.State != TranscriptChangeState.Kept)) Mark(hunk.First >= 0 ? hunk.First : hunk.Anchor, hunk.Last >= 0 ? hunk.Last : hunk.Anchor, "VcChangeAddBrush", 6);
        foreach (var segment in model.Project.VoiceLab.Segments.Where(segment => segment.Enabled))
            Mark(model.Index(segment.Replace.FirstWordId), model.Index(segment.Replace.LastWordId), "VcAiWaveBrush", 8);

        void Mark(int first, int last, string key, double left)
        {
            if (first < 0 || last < first || last >= model.Words.Count) return;
            var top = model.Words[first].Start / duration * overview.ActualHeight;
            var bottom = model.Words[last].End / duration * overview.ActualHeight;
            var marker = new Microsoft.UI.Xaml.Shapes.Rectangle { Width = 2, Height = Math.Max(2, bottom - top), Fill = Brush(key) };
            Canvas.SetLeft(marker, left); Canvas.SetTop(marker, top);
            overview.Children.Add(marker);
        }
    }

    private static string FormatTakeTime(double seconds)
    {
        var total = Math.Max(0, (int)Math.Floor(seconds));
        return total >= 3600 ? $"{total / 3600}:{total / 60 % 60:00}:{total % 60:00}" : $"{total / 60}:{total % 60:00}";
    }
}
