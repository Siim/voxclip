using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using Windows.System;

namespace VoxClip.App.Controls;

/// <summary>The Rewrite thread under the focused change (design.md §6.3 "Talk back to Claude", ADR-R50): one control, moved to the
/// paragraph of the focused waiting change and updated in place, so its input keeps the keys while the proposal refreshes. Keep and Undo
/// take it away: a kept or left-out change has none.</summary>
public sealed partial class TranscriptView
{
    private RewriteThreadView? threadView;
    private int threadFocusRequest;

    /// <summary>Puts the thread under <paramref name="editor"/>'s paragraph when the focused change's last piece is in it, or takes it out.</summary>
    private void PlaceThread(StackPanel editor, bool hostsFocusedChange)
    {
        var display = hostsFocusedChange && proposalSession is { IsOpen: true } session && session.ThreadDisplay is { } shown && shown.Ordinal == focusedChange
            ? shown : null;
        if (display is null || proposalSession is not { } owner)
        {
            if (threadView is not null && editor.Children.Contains(threadView)) editor.Children.Remove(threadView);
            return;
        }
        threadView ??= new RewriteThreadView(this);
        if (threadView.Parent is Panel parent && !ReferenceEquals(parent, editor)) parent.Children.Remove(threadView);
        if (!editor.Children.Contains(threadView)) editor.Children.Insert(0, threadView);
        threadView.Show(owner, display);
        if (owner.Thread.FocusRequest == threadFocusRequest) return;
        threadFocusRequest = owner.Thread.FocusRequest;
        threadView.FocusInput();
    }

    /// <summary>F2, Shift+F2, Enter, a click on a change's new words and the review's Edit: the change's thread opens and its input takes
    /// the keys; <paramref name="ownWords"/> opens it taking your own words.</summary>
    internal void OpenThread(int ordinal, bool ownWords = false)
    {
        if (!CanEditTranscript || proposalSession is not { } session || proposal.Hunks.All(hunk => hunk.Ordinal != ordinal)) return;
        if (focusedChange != ordinal) FocusChange(ordinal);
        var opened = ownWords ? session.OpenThreadOwnWords() : session.OpenThreadInput();
        if (!opened) Announce($"Change {ordinal} can't be talked about now.");
    }

    /// <summary>Alt+Page Up and Alt+Page Down in the transcript: the focused change's previous or next version, once it has two.</summary>
    private bool SwitchThreadVersion(int step) =>
        proposalSession is { ThreadDisplay: { Versions: > 1 } display } session && display.Ordinal == focusedChange && session.SwitchThreadVersion(step);

    /// <summary>The thread itself: the last two turns, "‹ n of m ›" with the voice line, the bubbles, the inline confirmation, the input
    /// with its cost line or the working line with Stop, and an error with Try Again. A 2 epx <c>change.add</c> rule at 45 % on its left,
    /// and no box.</summary>
    private sealed class RewriteThreadView : Grid
    {
        private readonly TranscriptView owner;
        private readonly StackPanel turns = new() { Spacing = 2 };
        private readonly Button previous = Arrow("‹", "Previous version");
        private readonly Button next = Arrow("›", "Next version");
        private readonly TextBlock version = new() { VerticalAlignment = VerticalAlignment.Center, FontSize = 13 };
        private readonly TextBlock phrases = new() { VerticalAlignment = VerticalAlignment.Center, FontSize = 13 };
        private readonly StackPanel versionRow = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
        private readonly FlowPanel bubbles = new() { Spacing = 6 };
        private readonly StackPanel confirmation = new();
        private readonly TextBox input = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinWidth = 240, MaxHeight = 104, FontSize = 13 };
        private readonly TextBlock cost = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        private readonly Grid inputRow = new() { ColumnSpacing = 8 };
        private readonly TextBlock working = new() { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        private readonly StackPanel workingRow = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
        /// <summary>"Waiting: this replaces 2 paid takes. Confirm in the Rewrite panel to use it." while a version waits for their discard.</summary>
        private readonly TextBlock waiting = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock error = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap };
        private readonly Button retry = new() { Content = "Try Again" };
        private readonly StackPanel errorRow = new() { Spacing = 4 };
        private RewriteSession? session;
        private RewriteThreadDisplay? shown;
        private InlineApproval? shownApproval;
        private bool updating;
        private bool composing;

        internal RewriteThreadView(TranscriptView owner)
        {
            this.owner = owner;
            Margin = new Thickness(0, 4, 0, 4);
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var rule = new Border { Width = 2, Opacity = 0.45, Background = owner.Brush("VcChangeAddBrush") };
            Children.Add(rule);
            var body = new StackPanel { Spacing = 6, Margin = new Thickness(10, 0, 0, 0), MaxWidth = 680, HorizontalAlignment = HorizontalAlignment.Left };
            SetColumn(body, 1);
            Children.Add(body);
            AutomationProperties.SetAutomationId(this, "Rewrite.Thread");
            previous.Click += (_, _) => session?.SwitchThreadVersion(-1);
            next.Click += (_, _) => session?.SwitchThreadVersion(1);
            versionRow.Children.Add(previous); versionRow.Children.Add(version); versionRow.Children.Add(next); versionRow.Children.Add(phrases);
            AutomationProperties.SetAutomationId(input, "Rewrite.ThreadInput");
            input.TextChanged += (_, _) => { if (!updating) session?.SetThreadText(input.Text); };
            input.TextCompositionStarted += (_, _) => composing = true;
            input.TextCompositionEnded += (_, _) => composing = false;
            input.PreviewKeyDown += InputKeyDown;
            inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            inputRow.Children.Add(input);
            SetColumn(cost, 1);
            inputRow.Children.Add(cost);
            var stop = new Button { Content = "Stop" };
            AutomationProperties.SetName(stop, "Stop");
            stop.Click += (_, _) => { session?.StopThread(); FocusInput(); };
            workingRow.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            workingRow.Children.Add(working);
            workingRow.Children.Add(stop);
            retry.Click += (_, _) => { if (session is { } current) _ = current.RetryThreadAsync(); };
            AutomationProperties.SetName(retry, "Try Again");
            errorRow.Children.Add(error); errorRow.Children.Add(retry);
            AutomationProperties.SetAutomationId(waiting, "Rewrite.ThreadWaiting");
            foreach (var part in new UIElement[] { turns, versionRow, bubbles, confirmation, inputRow, workingRow, waiting, errorRow }) body.Children.Add(part);
        }

        private static Button Arrow(string glyph, string name)
        {
            var button = new Button { Content = glyph, MinWidth = 0, MinHeight = 0, Padding = new Thickness(6, 0, 6, 1), FontSize = 13 };
            AutomationProperties.SetName(button, name);
            return button;
        }

        internal void FocusInput() => DispatcherQueue.TryEnqueue(() =>
        {
            if (!input.IsLoaded || inputRow.Visibility != Visibility.Visible) return;
            input.Focus(FocusState.Programmatic);
            input.SelectionStart = input.Text.Length;
        });

        internal void Show(RewriteSession current, RewriteThreadDisplay display)
        {
            session = current;
            shown = display;
            updating = true;
            try
            {
                AutomationProperties.SetName(this, display.Label);
                RenderTurns(display);
                version.Text = display.VersionLine;
                AutomationProperties.SetName(version, display.VersionLabel);
                phrases.Text = display.PhrasesLine + (display.YoursLine is { } yours ? " " + yours : "");
                phrases.Foreground = owner.Brush("VcTextSecondaryBrush");
                previous.IsEnabled = display.Version > 1 && !display.Sending;
                next.IsEnabled = display.Version < display.Versions && !display.Sending;
                ToolTipService.SetToolTip(versionRow, display.FitLine.Length == 0 ? null : display.FitLine);
                RenderBubbles(display);
                RenderConfirmation(display);
                if (input.Text != display.Input) { input.Text = display.Input; input.SelectionStart = input.Text.Length; }
                input.PlaceholderText = display.Placeholder;
                AutomationProperties.SetName(input, display.InputLabel);
                AutomationProperties.SetHelpText(input, display.OwnWords ? "Enter puts your words in place. Escape goes back to Claude." :
                    $"Enter sends. Shift+Enter adds a line. {RewriteThreadDisplay.PreviousVersionKey} and {RewriteThreadDisplay.NextVersionKey} switch versions. Control+Enter keeps the change.");
                cost.Text = display.InputCostLine;
                cost.Foreground = owner.Brush("VcTextTertiaryBrush");
                inputRow.Visibility = display.Sending ? Visibility.Collapsed : Visibility.Visible;
                working.Text = display.WorkingLine;
                workingRow.Visibility = display.Sending && display.Confirmation is null ? Visibility.Visible : Visibility.Collapsed;
                waiting.Text = display.Waiting ?? "";
                waiting.Foreground = owner.Brush("VcTextSecondaryBrush");
                waiting.Visibility = display.Waiting is null ? Visibility.Collapsed : Visibility.Visible;
                error.Text = display.Error ?? "";
                retry.Visibility = display.Retry ? Visibility.Visible : Visibility.Collapsed;
                errorRow.Visibility = display.Error is null ? Visibility.Collapsed : Visibility.Visible;
            }
            finally { updating = false; }
        }

        private void RenderTurns(RewriteThreadDisplay display)
        {
            turns.Children.Clear();
            foreach (var turn in display.Turns)
            {
                var line = new RichTextBlock { FontSize = 13, IsTextSelectionEnabled = false, TextWrapping = TextWrapping.Wrap };
                var paragraph = new Paragraph();
                var claude = turn.Speaker == RewriteThreadSpeaker.Claude;
                paragraph.Inlines.Add(new Run
                {
                    Text = claude ? "✦ Claude " : turn.Speaker == RewriteThreadSpeaker.Yours ? "You · your own words: " : "You ",
                    FontWeight = FontWeights.SemiBold, Foreground = owner.Brush(claude ? "VcAccentTextBrush" : "VcTextSecondaryBrush")
                });
                paragraph.Inlines.Add(new Run { Text = turn.Speaker == RewriteThreadSpeaker.Yours ? "“" + turn.Text + "”" : turn.Text });
                line.Blocks.Add(paragraph);
                AutomationProperties.SetName(line, RewriteThreadDisplay.TurnLabel(turn));
                turns.Children.Add(line);
            }
            turns.Visibility = display.Turns.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }

        private void RenderBubbles(RewriteThreadDisplay display)
        {
            bubbles.Children.Clear();
            var enabled = !display.Sending && display.Confirmation is null;
            if (display.Keep.Length > 0) Add(display.Keep, display.Keep, keep: true);
            foreach (var step in display.Steps) Add("✦ " + step, step, name: RewriteThreadDisplay.StepLabel(step), ai: true);
            foreach (var steady in display.Steady) Add(steady, steady);
            // "✎ My own words", last: a toggle, so Narrator reads its selected state.
            var own = new ToggleButton { Content = RewriteThreadDisplay.OwnWordsBubble, IsChecked = display.OwnWords, IsEnabled = !display.Sending };
            Capsule(own);
            if (display.OwnWords)
            {
                own.Background = owner.Brush("VcBgSelectedRowBrush");
                own.BorderBrush = owner.Brush("VcLineStrongBrush");
                own.FontWeight = FontWeights.SemiBold;
            }
            AutomationProperties.SetName(own, "My own words");
            AutomationProperties.SetHelpText(own, $"Type your own words for change {display.Ordinal}. {RewriteThreadDisplay.OwnWordsKey} in the transcript.");
            own.Click += (_, _) => { session?.ToggleThreadOwnWords(); FocusInput(); };
            bubbles.Children.Add(own);

            void Add(string label, string title, bool keep = false, bool ai = false, string? name = null)
            {
                var bubble = new Button { Content = label, IsEnabled = enabled || keep && !display.Sending };
                Capsule(bubble);
                if (keep) bubble.Background = owner.Brush("VcChangeAddBrush");
                if (ai) bubble.BorderBrush = owner.Brush("VcAccentTextBrush");
                AutomationProperties.SetName(bubble, name ?? title);
                bubble.Click += (_, _) =>
                {
                    if (session is not { } current) return;
                    _ = current.PressThreadBubbleAsync(title);
                    // Keep removes the thread: the keys go back to the transcript, on the change the focus moved to (Mac ⌘↩).
                    if (keep) owner.Focus(FocusState.Programmatic);
                };
                bubbles.Children.Add(bubble);
            }
        }

        private static void Capsule(ButtonBase bubble)
        {
            bubble.MinHeight = 24;
            bubble.Height = 24;
            bubble.Padding = new Thickness(10, 0, 10, 0);
            bubble.FontSize = 12;
            bubble.CornerRadius = new CornerRadius(12);
            bubble.BorderThickness = new Thickness(1);
        }

        private void RenderConfirmation(RewriteThreadDisplay display)
        {
            if (ReferenceEquals(shownApproval, display.Confirmation)) return;
            foreach (var row in confirmation.Children.OfType<IDisposable>()) row.Dispose();
            confirmation.Children.Clear();
            shownApproval = display.Confirmation;
            if (display.Confirmation is { } approval) confirmation.Children.Add(new InlineConfirmation(approval));
            confirmation.Visibility = display.Confirmation is null ? Visibility.Collapsed : Visibility.Visible;
        }

        /// <summary>Enter sends, Shift+Enter is a new line, Esc folds or leaves your own words, Alt+Page Up and Alt+Page Down switch versions
        /// while the input is empty, Ctrl+Enter keeps the change and Ctrl+Backspace on an empty input undoes it.</summary>
        private void InputKeyDown(object sender, KeyRoutedEventArgs args)
        {
            if (composing || session is not { } current || shown is null) return;
            var shift = InputState.Down(VirtualKey.Shift);
            var control = InputState.Down(VirtualKey.Control);
            var alt = InputState.Down(VirtualKey.Menu);
            RewriteThreadInputKey? key = args.Key switch
            {
                VirtualKey.Enter when control => RewriteThreadInputKey.Keep,
                VirtualKey.Enter when shift => RewriteThreadInputKey.ShiftEnter,
                VirtualKey.Enter => RewriteThreadInputKey.Enter,
                VirtualKey.Escape => RewriteThreadInputKey.Escape,
                VirtualKey.PageUp when alt => RewriteThreadInputKey.PreviousVersion,
                VirtualKey.PageDown when alt => RewriteThreadInputKey.NextVersion,
                VirtualKey.Back when control && input.Text.Length == 0 => RewriteThreadInputKey.Undo,
                _ => null
            };
            if (key is not { } pressed) return;
            var folding = pressed == RewriteThreadInputKey.Escape && !shown.OwnWords && !shown.Sending;
            if (!current.ThreadInputKey(pressed)) return;
            args.Handled = true;
            if (folding || pressed is RewriteThreadInputKey.Keep or RewriteThreadInputKey.Undo) owner.Focus(FocusState.Keyboard);
        }
    }
}
