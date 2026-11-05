using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using Windows.System;

namespace VoxClip.App.Controls;

/// <summary>✦ Make it postable's run and review in the right column (design §6.7), twin of the Mac <c>MakeItPanel</c>: progress lines
/// and Stop while Claude plans and applies; then the headline, each decision with ▶, Undo and Change (inline chips, the hook's
/// field, a question's answers), the post text with Copy, Undo all, and "Export · shapes" as the primary action. No dialog.</summary>
internal sealed class MakeItPanel : InlineEditorJob
{
    private readonly StackPanel body = Ui.Stack(8);
    private bool queued;
    private InlineConfirmation? asking;

    /// <summary>A first or billed AI send asks here, inline, before the plan is sent.</summary>
    internal async Task<bool> AskAsync(InlineApproval pending)
    {
        using var row = new InlineConfirmation(pending, () => RightColumn.RequestSourcePlayback(Editor));
        asking = row;
        Render();
        row.FocusTarget.Focus(FocusState.Programmatic);
        try { return await pending.Completion; }
        finally { asking = null; Render(); }
    }

    internal MakeItPanel(EditorViewModel editor) : base(editor)
    {
        JobLabel = "Make it postable";
        Title = "✦ Make it postable";
        CloseButtonText = "Close";
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        AutomationProperties.SetAutomationId(this, "MakeIt.Panel");
        PrimaryButtonClick += (_, action) => { action.Cancel = true; Primary(); };
        Opened += (_, _) => { Editor.MakeItChanged += EditorMakeItChanged; Render(); };
        Closed += (_, _) => Editor.MakeItChanged -= EditorMakeItChanged;
        Abandoned += (_, _) => Editor.MakeItChanged -= EditorMakeItChanged;
        Render();
    }

    private void EditorMakeItChanged(object? sender, EventArgs args)
    {
        if (queued) return;
        queued = true;
        DispatcherQueue.TryEnqueue(() => { queued = false; Render(); });
    }

    private MakeItRun? Run => Editor.MakeIt.Shown;

    /// <summary>Stop while a run goes; Export once it is done; Try again after a failure.</summary>
    private void Primary()
    {
        if (Run is not { } run) return;
        if (run.Running) { Editor.StopMakeIt(); return; }
        if (run.Phase == MakeItPhase.Failed) { Editor.MakeItPostable(run.ClipId); return; }
        _ = Editor.MakeItExportAsync(run);
    }

    private void Render()
    {
        body.Children.Clear();
        if (Run is not { } run)
        {
            body.Children.Add(Ui.Text("Nothing to review yet."));
            PrimaryButtonVisible = false;
            return;
        }
        var headline = Ui.Text(Editor.MakeItHeadline(run), "SubtitleTextBlockStyle");
        AutomationProperties.SetAutomationId(headline, "MakeIt.Headline");
        AutomationProperties.SetHeadingLevel(headline, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        body.Children.Add(headline);
        if (asking is not null) body.Children.Add(asking);
        foreach (var note in Editor.MakeItLengthNotes(run)) body.Children.Add(Secondary(note));
        Series(run);
        if (run.Running || run.Exporting)
        {
            var progress = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            progress.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            progress.Children.Add(Ui.Text(run.Lines.LastOrDefault() ?? "Reading the clip…"));
            AutomationProperties.SetLiveSetting(progress, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
            body.Children.Add(progress);
            foreach (var line in run.Lines.SkipLast(1).TakeLast(3)) body.Children.Add(Secondary(line));
        }
        else if (run.Phase == MakeItPhase.Failed) body.Children.Add(Ui.Text(run.Failure));
        if (Editor.MakeIt.Budget is { Needed: { } needed } budget)
        {
            // Claude mode at the video's cap: Continue approves exactly the shortfall; Stop keeps the creator's words.
            var wait = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            wait.Children.Add(Ui.Button("Continue · " + MakeItController.Dollars(needed), budget.ApproveNeeded, accent: true));
            wait.Children.Add(Ui.Button("Stop", Editor.StopMakeIt));
            body.Children.Add(Secondary($"This video's cap is reached. The next step needs about {MakeItController.Dollars(needed)} more."));
            body.Children.Add(wait);
        }
        foreach (var row in run.Rows) body.Children.Add(Row(run, row));
        if (!run.Running && run.Rows.Count > 0)
        {
            var post = Editor.MakeItPost(run);
            if (post.Length > 0)
            {
                body.Children.Add(Ui.Text("Post text", "BodyStrongTextBlockStyle"));
                var text = Ui.Text(post);
                text.IsTextSelectionEnabled = true;
                body.Children.Add(text);
                var copy = Ui.Button(run.Copied ? "Copied" : "Copy", () => Editor.CopyMakeItPostText(run));
                AutomationProperties.SetName(copy, "Copy post text");
                body.Children.Add(copy);
            }
            if (run.Rows.Any(row => row.Undoable && !row.Undone))
            {
                var undoAll = new HyperlinkButton { Content = "Undo all", Padding = new(0) };
                undoAll.Click += (_, _) => Editor.MakeItUndoAll(run);
                body.Children.Add(undoAll);
            }
            foreach (var file in run.Exported) body.Children.Add(Secondary(Path.GetFileName(file)));
        }
        body.Children.Add(Secondary(EditorViewModel.MakeItNextStep(run)));
        PrimaryButtonVisible = true;
        PrimaryButtonText = run.Running ? "Stop" : run.Phase == MakeItPhase.Failed ? "Try again" : Editor.MakeItExportTitle;
        IsPrimaryButtonEnabled = run.Running || (run.Phase == MakeItPhase.Failed ? Editor.CanMakeItPostable(run.ClipId) : !run.Exporting && Editor.ExportBlocked(false, false, run.ClipId) is null);
    }

    /// <summary>"✦ Make top 3 postable": one line per clip of the series; a click shows that clip's review.</summary>
    private void Series(MakeItRun shown)
    {
        var series = Editor.MakeIt.Series;
        if (series.Count < 2 || !series.Contains(shown.ClipId)) return;
        foreach (var id in series)
        {
            if (Editor.MakeIt.Run(id) is not { } run) continue;
            var title = Editor.Clips.FirstOrDefault(clip => clip.Id == id)?.Title ?? id;
            var state = run.Phase switch
            {
                MakeItPhase.Ready => run.Plan is { } plan ? $"score {plan.Score}/10" : "ready",
                MakeItPhase.Failed => "not changed",
                MakeItPhase.Stopped => "stopped",
                _ => run.Lines.LastOrDefault() ?? "waiting"
            };
            var item = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = $"{title} · {state}", IsChecked = id == shown.ClipId, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
            item.Click += (_, _) => { Editor.MakeIt.ShownClipId = id; Render(); };
            body.Children.Add(item);
        }
    }

    private FrameworkElement Row(MakeItRun run, MakeItRow row)
    {
        var panel = Ui.Stack(4);
        var line = new Grid { ColumnSpacing = 4 };
        line.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var words = Ui.Stack(0);
        var text = Ui.Text(row.Text);
        if (row.Undone) text.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
        words.Children.Add(text);
        if (row.Detail.Length > 0) words.Children.Add(Secondary(row.Detail));
        line.Children.Add(words);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Top };
        if (row.Play is not null && !run.Running) actions.Children.Add(Small("▶", "Play " + row.Text, () => Editor.MakeItPlay(row)));
        if (row.Undoable && !row.Undone && !run.Running) actions.Children.Add(Small("Undo", "Undo " + row.Text, () => Editor.MakeItUndo(row.Id, run)));
        if (row.Change != MakeItChange.None && !row.Undone && !run.Running) actions.Children.Add(Small("Change", "Change " + row.Text, () => Editor.MakeItChangeRow(row.Id, run)));
        Grid.SetColumn(actions, 1);
        line.Children.Add(actions);
        panel.Children.Add(line);
        if (run.OpenChoice == row.Id) panel.Children.Add(Choices(run, row));
        AutomationProperties.SetName(panel, row.Detail.Length > 0 ? row.Text + ", " + row.Detail : row.Text);
        return panel;
    }

    /// <summary>The open row's inline choices: look or speed chips, the hook's field, or a question's answers.</summary>
    private FrameworkElement Choices(MakeItRun run, MakeItRow row)
    {
        if (row.Change == MakeItChange.Hook)
        {
            var field = new TextBox { Text = run.Hook, PlaceholderText = "The hook", MaxLength = 80 };
            AutomationProperties.SetName(field, "Hook text");
            field.KeyDown += (_, args) =>
            {
                if (args.Key == VirtualKey.Enter) { args.Handled = true; Editor.MakeItSetHook(field.Text, row.Id, run); }
                else if (args.Key == VirtualKey.Escape) { args.Handled = true; Editor.MakeItChangeRow(row.Id, run); }
            };
            field.Loaded += (_, _) => field.Focus(FocusState.Programmatic);
            return field;
        }
        var chips = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemHeight = 32 };
        foreach (var option in row.Options)
        {
            var chip = row.Change == MakeItChange.Question
                ? Ui.Button(option, () => Editor.MakeItAnswer(option, row.Question, run))
                : Ui.Button(option, () => Editor.MakeItChoose(option, row.Id, run));
            chip.Margin = new(0, 0, 4, 4);
            chips.Children.Add(chip);
        }
        return chips;
    }

    private static Button Small(string label, string name, Action action)
    {
        var button = Ui.Button(label, action);
        button.Padding = new(6, 2, 6, 2);
        button.Style = (Style)Application.Current.Resources["SubtleButtonStyle"];
        AutomationProperties.SetName(button, name);
        return button;
    }

    private static TextBlock Secondary(string text)
    {
        var block = Ui.Text(text, "CaptionTextBlockStyle");
        block.TextWrapping = TextWrapping.Wrap;
        return block;
    }
}
