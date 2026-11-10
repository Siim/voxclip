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
        // F2 opens the focused change's thread for Claude, Shift+F2 with your own words (the Mac's Return and ⌥E: Alt+E would reach
        // menu access keys); with no change focused, F2 corrects the selected word's spelling.
        if (args.Key == VirtualKey.F2)
        {
            var ownWords = InputState.Down(VirtualKey.Shift);
            if (focusedChange > 0) OpenThread(focusedChange, ownWords);
            else if (!ownWords) BeginWordCorrection();
            args.Handled = true;
            return true;
        }
        // Alt+Page Up and Alt+Page Down: the focused change's previous or next version (the Mac's ⌥← and ⌥→; Alt+← is Back).
        if (InputState.Down(VirtualKey.Menu) && args.Key is VirtualKey.PageUp or VirtualKey.PageDown && focusedChange > 0)
        {
            if (SwitchThreadVersion(args.Key == VirtualKey.PageDown ? 1 : -1)) { args.Handled = true; return true; }
            return false;
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
        ShowInlineEditor(visual, model.CorrectionText);
    }

    /// <summary>The word's inline spelling row under its paragraph: "Correct spelling", Enter saves (Tab saves and opens the next word), Esc
    /// cancels, and a click outside it ends the correction.</summary>
    private void ShowInlineEditor(ParagraphVisual visual, string value)
    {
        const string title = "Correct spelling";
        selectionFlyout.Hide();
        var host = visual.Editor;
        var expectedProject = model?.Project;
        inlineEditor = host;
        inlineWordCorrection = true;
        var text = new TextBox { Header = title, Text = value, TextWrapping = TextWrapping.Wrap, MaxWidth = 680 };
        model?.RewriteCaretChanged();
        text.SelectionChanged += (_, _) => model?.RewriteCaretChanged();
        AutomationProperties.SetName(text, title);
        text.TextChanged += (_, _) => { if (ReferenceEquals(inlineEditor, host) && model is not null) model.CorrectionText = text.Text; };
        text.LostFocus += (_, _) =>
        {
            if (ReferenceEquals(inlineEditor, host) && text.ContextFlyout is not { IsOpen: true } && text.SelectionFlyout is not { IsOpen: true })
                model?.EndCorrection();
        };
        var status = new TextBlock { Text = "Changes captions only. Enter saves. Esc cancels.", TextWrapping = TextWrapping.Wrap, FontSize = 12 };
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
            if (model is not null && !ReferenceEquals(expectedProject, model.Project)) { model.EndCorrection(keep: false); return; }
            var entered = text.Text;
            if (model is not null) model.CorrectionText = entered;
            var applied = model?.SaveCorrection(advance: next) == true;
            if (!applied)
            {
                status.Text = "The edit was not applied. Your media and edits are safe.";
                Announce(status.Text);
                return;
            }
            if (model?.CorrectionWordId is null) Focus(FocusState.Keyboard);
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
        host.Children.Add(text);
        host.Children.Add(status);
        host.Children.Add(actions);
        host.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = Ui.EffectPolicy.Animations });
        text.Focus(FocusState.Programmatic);
        text.SelectAll();
        if (XamlRoot?.Content is UIElement root)
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
        ClearEditorHost(previous);
        if (focus && IsLoaded) Focus(FocusState.Keyboard);
    }

    /// <summary>Empties a paragraph's editor host but keeps the thread, which moves only with the focused change.</summary>
    private void ClearEditorHost(StackPanel? host)
    {
        if (host is null) return;
        foreach (var child in host.Children.ToArray())
            if (!ReferenceEquals(child, threadView)) host.Children.Remove(child);
    }
}
