using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using Windows.System;

namespace VoxClip.App.Controls;

public sealed partial class TranscriptView
{
    internal void FocusChange(int ordinal, bool reveal = true)
    {
        if (proposal.Hunks.FirstOrDefault(hunk => hunk.Ordinal == ordinal) is not { } change) return;
        CloseInlineEditor(false);
        focusedChange = ordinal;
        if (reveal) RevealWord(change.First >= 0 ? change.First : change.Anchor);
        RebuildRealized();
        ChangeFocused?.Invoke(ordinal);
        Announce($"Proposed change {ordinal} of {proposal.TotalCount}. {change.NewText}");
    }

    private bool HandleProposalKey(KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.F2)
        {
            if (focusedChange > 0) BeginProposalCorrection();
            else BeginWordCorrection();
            args.Handled = true;
            return true;
        }
        if (InputState.Down(VirtualKey.Menu) && (args.Key is VirtualKey.Up or VirtualKey.Down) && proposal.Hunks.Count > 0)
        {
            var ordered = proposal.Hunks.OrderBy(hunk => hunk.Anchor).ThenBy(hunk => hunk.Ordinal).ToArray();
            var position = Array.FindIndex(ordered, hunk => hunk.Ordinal == focusedChange);
            var next = position < 0 ? args.Key == VirtualKey.Up ? ordered.Length - 1 : 0
                : (position + (args.Key == VirtualKey.Up ? ordered.Length - 1 : 1)) % ordered.Length;
            FocusChange(ordered[next].Ordinal);
            args.Handled = true;
            return true;
        }
        if (CanEditTranscript && focusedChange > 0 && InputState.Down(VirtualKey.Control))
        {
            if (args.Key == VirtualKey.Enter && KeepChangeRequested is not null)
            {
                KeepChangeRequested(focusedChange);
                args.Handled = true;
                return true;
            }
            if (args.Key == VirtualKey.Back && ExcludeChangeRequested is not null)
            {
                ExcludeChangeRequested(focusedChange);
                args.Handled = true;
                return true;
            }
        }
        return false;
    }

    private StackPanel ChangeActions(TranscriptProposalHunk hunk)
    {
        var expected = proposal;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(8, 0, 0, 0) };
        if (KeepChangeRequested is not null) Add("Keep", () => KeepChangeRequested?.Invoke(hunk.Ordinal));
        if (ExcludeChangeRequested is not null) Add("Undo", () => ExcludeChangeRequested?.Invoke(hunk.Ordinal));
        if (EditChangeRequested is not null) Add("Edit", () => BeginProposalCorrection());
        return row;

        void Add(string title, Action action)
        {
            var button = new Button { Content = title, MinWidth = 0, MinHeight = 20, Height = 20, Padding = new Thickness(7, 0, 7, 0), FontSize = 12 };
            AutomationProperties.SetName(button, $"{title} proposed change {hunk.Ordinal} of {proposal.TotalCount}");
            button.Click += (_, _) => { if (CanEditTranscript && ReferenceEquals(expected, proposal)) action(); };
            button.IsEnabled = CanEditTranscript;
            row.Children.Add(button);
        }
    }

    private bool CanEditTranscript => model is { IsReadOnly: false, Busy: false, IsLeaving: false };

    private void OpenFold(TranscriptPiece fold)
    {
        if (model is null) return;
        foreach (var id in (fold.WordIds ?? []).Concat(fold.PauseIds ?? [])) expandedCuts.Add(id);
        RebuildRealized();
        if (realized.Values.FirstOrDefault(visual => fold.First >= visual.Item.StartIndex && fold.First < visual.Item.StartIndex + visual.Item.Count) is not { } owner) return;
        CloseInlineEditor(false);
        inlineEditor = owner.Editor;
        owner.Editor.Children.Add(new TextBlock { Text = fold.Text, TextWrapping = TextWrapping.Wrap });
        var restore = new Button { Content = "Restore", IsEnabled = CanEditTranscript };
        AutomationProperties.SetName(restore, "Restore " + fold.FoldName);
        restore.Click += (_, _) =>
        {
            if (!CanEditTranscript) return;
            CloseInlineEditor(false);
            model.ApplyBatch([new EditOperation.SetWordCuts(fold.WordIds ?? [], false), new EditOperation.SetPauseCuts(fold.PauseIds ?? [], false)]);
            Announce("Restored cut");
            Focus(FocusState.Keyboard);
        };
        owner.Editor.Children.Add(restore);
        var close = new Button { Content = "Close" };
        close.Click += (_, _) => CloseInlineEditor(true);
        owner.Editor.Children.Add(close);
        owner.Editor.StartBringIntoView();
        restore.Focus(FocusState.Programmatic);
    }

    private bool inlineWordCorrection;
    private UIElement? inlinePressRoot;
    private PointerEventHandler? inlinePressHandler;

    private void BeginWordCorrection()
    {
        selectionFlyout.Hide();
        if (!CanEditTranscript || model is null || !model.HasSelection || model.PresentedWord(model.SelectionStart).AiModified) return;
        CloseInlineEditor(false);
        model.BeginCorrection();
    }

    private void CorrectionChanged(object? sender, EventArgs args)
    {
        if (model?.CorrectionWordId is not { } id)
        {
            if (inlineWordCorrection) CloseInlineEditor(false);
            return;
        }
        var index = model.Index(id);
        RevealWord(index);
        var visual = realized.Values.FirstOrDefault(value => value.Runs.Any(run => run.Index <= index && run.LastIndex >= index));
        if (visual is null || !IsLoaded) { model.EndCorrection(keep: false); return; }
        ShowInlineEditor(visual, "Correct spelling", model.CorrectionText,
            "Changes captions only. Enter saves. Esc cancels.", _ => false, wordCorrection: true);
    }

    internal void EditProposalChange(int ordinal)
    {
        FocusChange(ordinal);
        BeginProposalCorrection();
    }

    private void BeginProposalCorrection()
    {
        if (!CanEditTranscript || model is null || EditChangeRequested is null ||
            proposal.Hunks.FirstOrDefault(hunk => hunk.Ordinal == focusedChange) is not { } hunk) return;
        var index = hunk.First >= 0 ? hunk.First : hunk.Anchor;
        RevealWord(index);
        var visual = realized.Values.FirstOrDefault(value => index >= value.Item.StartIndex && index < value.Item.StartIndex + value.Item.Count);
        if (visual is null) return;
        var expected = proposal;
        var timing = proposalSession?.Review?.VoiceHunks.FirstOrDefault(review => review.Ordinals.Contains(hunk.Ordinal))?.Fit;
        ShowInlineEditor(visual, $"New words for change {hunk.Ordinal}", hunk.NewText,
            (timing is null ? "Nothing is sent. " : timing.Copy + ". ") + "Return saves · Esc cancels", value =>
                ReferenceEquals(expected, proposal) && EditChangeRequested?.Invoke(hunk.Ordinal, value) == true,
            ExcludeChangeRequested is null ? null : () => ExcludeChangeRequested?.Invoke(hunk.Ordinal));
    }

    private void ShowInlineEditor(ParagraphVisual visual, string title, string value, string hint, Func<string, bool> save, Action? reject = null, bool wordCorrection = false)
    {
        if (!wordCorrection) CloseInlineEditor(false);
        selectionFlyout.Hide();
        var host = visual.Editor;
        var expectedProject = model?.Project;
        inlineEditor = host;
        inlineWordCorrection = wordCorrection;
        var text = new TextBox { Header = title, Text = value, TextWrapping = TextWrapping.Wrap, MaxWidth = 680 };
        model?.RewriteCaretChanged();
        text.SelectionChanged += (_, _) => model?.RewriteCaretChanged();
        AutomationProperties.SetName(text, title);
        if (wordCorrection)
        {
            text.TextChanged += (_, _) => { if (ReferenceEquals(inlineEditor, host) && model is not null) model.CorrectionText = text.Text; };
            text.LostFocus += (_, _) =>
            {
                if (ReferenceEquals(inlineEditor, host) && text.ContextFlyout is not { IsOpen: true } && text.SelectionFlyout is not { IsOpen: true })
                    model?.EndCorrection();
            };
        }
        var status = new TextBlock { Text = hint, TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        var composing = false;
        var compositionEnded = false;
        text.TextCompositionStarted += (_, _) => composing = true;
        text.TextCompositionEnded += (_, _) =>
        {
            composing = false;
            compositionEnded = true;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => compositionEnded = false);
        };
        void Commit(bool next)
        {
            if (composing || compositionEnded || !ReferenceEquals(inlineEditor, host) || !CanEditTranscript) return;
            if (wordCorrection && model is not null && !ReferenceEquals(expectedProject, model.Project))
            { model.EndCorrection(keep: false); return; }
            var entered = text.Text;
            if (wordCorrection && model is not null) model.CorrectionText = entered;
            var applied = wordCorrection ? model?.SaveCorrection(advance: next) == true : save(entered);
            if (!applied)
            {
                status.Text = "The edit was not applied. Your media and edits are safe.";
                Announce(status.Text);
                return;
            }
            if (wordCorrection)
            {
                if (model?.CorrectionWordId is null) Focus(FocusState.Keyboard);
                return;
            }
            CloseInlineEditor(false);
            if (next && model?.HasSelection == true) { model.Select(model.SelectionEnd + 1); KeepWordInView(model.SelectionCaret); }
            Focus(FocusState.Keyboard);
        }
        text.KeyDown += (_, args) =>
        {
            if (composing || compositionEnded) return;
            if (args.Key is VirtualKey.Enter or VirtualKey.Tab) { Commit(args.Key == VirtualKey.Tab); args.Handled = true; }
            else if (args.Key == VirtualKey.Escape) { CloseInlineEditor(true); args.Handled = true; }
        };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        Add("Save", () => Commit(false));
        Add("Cancel", () => CloseInlineEditor(true));
        if (reject is not null) Add("Reject Change", () => { CloseInlineEditor(false); reject(); Focus(FocusState.Keyboard); });
        host.Children.Add(text);
        host.Children.Add(status);
        host.Children.Add(actions);
        host.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = Ui.EffectPolicy.Animations });
        text.Focus(FocusState.Programmatic);
        text.SelectAll();
        if (wordCorrection && XamlRoot?.Content is UIElement root)
        {
            // Register after the opening pointer event has finished bubbling.
            DispatcherQueue.TryEnqueue(() =>
            {
                if (!ReferenceEquals(inlineEditor, host) || inlinePressRoot is not null) return;
                inlinePressRoot = root;
                inlinePressHandler = (_, args) =>
                {
                    var element = args.OriginalSource as DependencyObject;
                    while (element is not null)
                    {
                        if (ReferenceEquals(element, host)) return;
                        element = VisualTreeHelper.GetParent(element);
                    }
                    model?.EndCorrection();
                };
                root.AddHandler(PointerPressedEvent, inlinePressHandler, true);
            });
        }

        void Add(string label, Action action)
        {
            var button = new Button { Content = label };
            button.Click += (_, _) => action();
            actions.Children.Add(button);
        }
    }

    private void CloseInlineEditor(bool focus)
    {
        if (inlinePressRoot is { } root && inlinePressHandler is { } handler)
            root.RemoveHandler(PointerPressedEvent, handler);
        inlinePressRoot = null;
        inlinePressHandler = null;
        var previous = inlineEditor;
        var word = inlineWordCorrection;
        inlineEditor = null;
        inlineWordCorrection = false;
        if (word) model?.EndCorrection(keep: false);
        previous?.Children.Clear();
        if (focus && IsLoaded) Focus(FocusState.Keyboard);
    }
}
