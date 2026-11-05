using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Autopilot;
using VoxClip.Core.Domain.Effects;
using Windows.System;

namespace VoxClip.App.Controls;

/// <summary>✦ Ask Claude in the right column (design §6.8), twin of the Mac <c>AskClaudePanel</c>: one inline field with the two chip
/// groups ("Reword these words" runs Rewrite at once; "Edit the video here" only fills the field), the inline connector confirmation,
/// progress, then "Done for … · n changes · Undo all" with ▶ · Adjust · Undo on each row. No pop-ups: the send confirmation, the paid
/// click and every Adjust editor are inline. The footer always names the next step.</summary>
internal sealed class AskClaudePanel : InlineEditorJob
{
    private readonly StackPanel body = Ui.Stack(8);
    private readonly TextBox field = new()
    {
        PlaceholderText = AskClaudeState.Placeholder, AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, MinHeight = 32, MaxHeight = 96
    };
    private bool queued;
    private InlineConfirmation? asking;

    /// <summary>A first or billed AI send asks here, inline, before the request is sent.</summary>
    internal async Task<bool> AskAsync(InlineApproval pending)
    {
        using var row = new InlineConfirmation(pending, () => RightColumn.RequestSourcePlayback(Editor));
        asking = row;
        Render();
        row.FocusTarget.Focus(FocusState.Programmatic);
        try { return await pending.Completion; }
        finally { asking = null; Render(); }
    }

    internal AskClaudePanel(EditorViewModel editor) : base(editor)
    {
        JobLabel = "Ask Claude";
        Title = "✦ Ask Claude";
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        AutomationProperties.SetAutomationId(this, "AskClaude.Panel");
        AutomationProperties.SetName(field, "What should Claude do?");
        AutomationProperties.SetAutomationId(field, "AskClaude.Field");
        field.TextChanged += (_, _) => { if (Editor.AskClaude.Text != field.Text) { Editor.AskClaude.Text = field.Text; UpdateButtons(); } };
        field.KeyDown += (_, args) =>
        {
            if (args.Key != VirtualKey.Enter || InputState.Down(VirtualKey.Shift)) return;
            args.Handled = true;
            _ = Editor.SendAskClaudeAsync();
        };
        PrimaryButtonClick += (_, action) => { action.Cancel = true; Primary(); };
        CloseButtonClick += (_, _) => { if (Editor.AskClaude.IsOpen) Editor.CloseAskClaude(); };
        Opened += (_, _) => { Editor.AskClaudeChanged += Changed; Render(); if (Editor.AskClaude.Selection is not null) field.Focus(FocusState.Programmatic); };
        Closed += (_, _) => Editor.AskClaudeChanged -= Changed;
        Abandoned += (_, _) => Editor.AskClaudeChanged -= Changed;
        Render();
    }

    private void Changed(object? sender, EventArgs args)
    {
        if (queued) return;
        queued = true;
        DispatcherQueue.TryEnqueue(() => { queued = false; Render(); });
    }

    /// <summary>Ask Claude once there is text; Stop while Claude works; Done on the change list.</summary>
    private void Primary()
    {
        var state = Editor.AskClaude;
        if (state.Selection is not null && state.Asking) Editor.StopAskClaude();
        else if (state.Selection is not null) _ = Editor.SendAskClaudeAsync();
        else Editor.CloseAskClaude();
    }

    private void UpdateButtons()
    {
        var state = Editor.AskClaude;
        if (state.Selection is not null && state.Asking) { PrimaryButtonText = "Stop"; PrimaryButtonVisible = true; CloseButtonText = "Close"; }
        else if (state.Selection is not null)
        {
            // Shown once there is something to send: never a button that cannot act.
            PrimaryButtonText = "Ask Claude";
            PrimaryButtonVisible = state.Text.Trim().Length > 0;
            CloseButtonText = "Cancel";
        }
        else { PrimaryButtonText = "Done"; PrimaryButtonVisible = state.Run is not null; CloseButtonText = "Close"; }
        IsPrimaryButtonEnabled = true;
    }

    private void Render()
    {
        var state = Editor.AskClaude;
        body.Children.Clear();
        if (state.Selection is not null) Composer(state);
        if (state.Run is { } run) Changes(run);
        var footer = new Grid { ColumnSpacing = 8 };
        footer.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var next = Secondary(Editor.AskClaudeFooter);
        AutomationProperties.SetAutomationId(next, "AskClaude.Footer");
        footer.Children.Add(next);
        if (state.Selection is null && state.Run is { } shown)
        {
            var again = Ui.Button("Ask again", () => Editor.OpenAskClaude(shown.Selection));
            AutomationProperties.SetAutomationId(again, "AskClaude.Again");
            Grid.SetColumn(again, 1);
            footer.Children.Add(again);
        }
        body.Children.Add(footer);
        UpdateButtons();
    }

    // MARK: The field

    private void Composer(AskClaudeState state)
    {
        var heading = Ui.Text("✦ Ask Claude about " + state.Label, "SubtitleTextBlockStyle");
        AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        AutomationProperties.SetAutomationId(heading, "AskClaude.Title");
        body.Children.Add(heading);
        if (field.Text != state.Text) field.Text = state.Text;
        field.IsReadOnly = state.Asking;
        body.Children.Add(field);
        // Two labelled groups: rewording runs Rewrite on these words at once; the video edits only fill the field. Tones never join
        // the effect group. While Claude works both step aside rather than show disabled.
        if (!state.Asking && Editor.AskClaudeTones is { Count: > 0 } tones && Editor.AskClaudeRewriteTarget(tones[0]) is not null)
        {
            body.Children.Add(GroupLabel("Reword these words"));
            var group = new FlowPanel { Spacing = 6 };
            AutomationProperties.SetName(group, "Reword these words");
            AutomationProperties.SetAutomationId(group, "AskClaude.RewordGroup");
            foreach (var item in tones)
            {
                var chip = Chip(item.Label, () => Editor.AskClaudeRewriteAs(item));
                ToolTipService.SetToolTip(chip, item.Detail);
                group.Children.Add(chip);
            }
            if (!state.AllTones)
            {
                var more = Chip("More…", Editor.ShowAllAskClaudeTones);
                AutomationProperties.SetAutomationId(more, "AskClaude.MoreTones");
                group.Children.Add(more);
            }
            body.Children.Add(group);
        }
        if (!state.Asking)
        {
            body.Children.Add(GroupLabel("Edit the video here"));
            var group = new FlowPanel { Spacing = 6 };
            AutomationProperties.SetName(group, "Edit the video here");
            foreach (var (label, text) in AskClaudeState.Chips)
            {
                var chip = Chip(label, () => { Editor.FillAskClaude(text); field.Text = text; field.Focus(FocusState.Programmatic); field.SelectionStart = text.Length; });
                AutomationProperties.SetHelpText(chip, "Fills the field. Nothing is sent until you press Enter.");
                group.Children.Add(chip);
            }
            body.Children.Add(group);
        }
        if (asking is not null) body.Children.Add(asking);
        if (state.Progress is { } progress)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            line.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            line.Children.Add(Ui.Text(progress));
            AutomationProperties.SetLiveSetting(line, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
            AutomationProperties.SetAutomationId(line, "AskClaude.Progress");
            body.Children.Add(line);
        }
        if (state.Error is { } error)
        {
            var text = Ui.Text(error);
            text.Foreground = Ui.ThemeBrush(this, "VcStatusDangerForegroundBrush");
            AutomationProperties.SetAutomationId(text, "AskClaude.Error");
            body.Children.Add(text);
        }
    }

    private static TextBlock GroupLabel(string text)
    {
        var label = Ui.Text(text);
        label.FontSize = 11;
        label.Opacity = 0.7;
        AutomationProperties.SetHeadingLevel(label, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level3);
        return label;
    }

    private static Button Chip(string label, Action action)
    {
        var chip = Ui.Button(label, action);
        chip.Padding = new(8, 2, 8, 2);
        chip.MinHeight = 24;
        chip.FontSize = 12;
        chip.CornerRadius = new(12);
        return chip;
    }

    // MARK: The change list

    private void Changes(AskClaudeRun run)
    {
        var card = Ui.Stack(6);
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var count = run.AppliedCount;
        var done = Ui.Text("Done for " + run.Label + " · " + (count == 1 ? "1 change" : count + " changes"), "BodyStrongTextBlockStyle");
        AutomationProperties.SetAutomationId(done, "AskClaude.Done");
        header.Children.Add(done);
        if (count > 0)
        {
            var undoAll = new HyperlinkButton { Content = "Undo all", Padding = new(0) };
            undoAll.Click += (_, _) => Editor.UndoAllAskClaude();
            AutomationProperties.SetAutomationId(undoAll, "AskClaude.UndoAll");
            Grid.SetColumn(undoAll, 1);
            header.Children.Add(undoAll);
        }
        card.Children.Add(header);
        if (run.Summary.Length > 0) card.Children.Add(Secondary(run.Summary));
        foreach (var row in run.Rows) card.Children.Add(Row(row));
        foreach (var repair in run.Repairs) card.Children.Add(Secondary(repair));
        body.Children.Add(new Border { Child = card, Padding = new(12), CornerRadius = new(8), Background = Ui.ThemeBrush(this, "VcBgElevatedBrush") });
    }

    private FrameworkElement Row(AskClaudeRow row)
    {
        var panel = Ui.Stack(4);
        var line = new Grid { ColumnSpacing = 4 };
        line.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var words = Ui.Stack(0);
        var title = Ui.Text(row.Title);
        if (row.Status == AskClaudeRowStatus.Undone) { title.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough; title.Opacity = 0.6; }
        words.Children.Add(title);
        words.Children.Add(Secondary(row.Detail));
        line.Children.Add(words);
        if (row.Status == AskClaudeRowStatus.Applied)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Top };
            if (EditorViewModel.SourceRange(row.Operation, Editor.Words) is not null) actions.Children.Add(Small("▶", "Play " + row.Title, () => Editor.PlayAskClaudeRow(row.Id)));
            if (Editor.CanAdjustAskClaude(row)) actions.Children.Add(Small("Adjust", "Adjust " + row.Title, () => Editor.ToggleAskClaudeAdjust(row.Id)));
            actions.Children.Add(Small("Undo", "Undo " + row.Title, () => Editor.UndoAskClaudeRow(row.Id)));
            Grid.SetColumn(actions, 1);
            line.Children.Add(actions);
        }
        panel.Children.Add(line);
        if (row.Choice is { } choice && row.Status == AskClaudeRowStatus.Applied)
        {
            var chose = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            chose.Children.Add(Secondary("Claude chose " + choice));
            if (Editor.CanAdjustAskClaude(row))
            {
                var change = new HyperlinkButton { Content = "Change", Padding = new(0), FontSize = 12 };
                change.Click += (_, _) => { if (Editor.AskClaude.Adjusting != row.Id) Editor.ToggleAskClaudeAdjust(row.Id); };
                AutomationProperties.SetName(change, "Change Claude's choice");
                chose.Children.Add(change);
            }
            panel.Children.Add(chose);
        }
        switch (row.Status)
        {
            case AskClaudeRowStatus.Paid:
                var paid = Ui.Button(row.Price, () => Editor.RunPaidAskClaudeRow(row.Id));
                AutomationProperties.SetAutomationId(paid, "AskClaude.Paid." + row.Id);
                panel.Children.Add(paid);
                panel.Children.Add(Secondary("Nothing is spent until you approve the exact price in the next step."));
                break;
            case AskClaudeRowStatus.Later: panel.Children.Add(Secondary(row.Reason)); break;
            case AskClaudeRowStatus.WholeClip:
                var whole = Ui.Button(EditorViewModel.WholeClipTitle(row.Operation), () => Editor.ApplyAskClaudeStretchToClip(row.Id));
                AutomationProperties.SetAutomationId(whole, "AskClaude.WholeClip." + row.Id);
                panel.Children.Add(whole);
                panel.Children.Add(Secondary("A clip plays at one speed. Nothing changed yet."));
                break;
            case AskClaudeRowStatus.Undone: panel.Children.Add(Secondary("Undone. Press Ctrl+Y (Redo) to bring it back.")); break;
            case AskClaudeRowStatus.Applied when Editor.AskClaude.Adjusting == row.Id && Editor.AskClaudeEffect(row.Id) is { } effect:
                panel.Children.Add(Adjuster(row, effect));
                break;
        }
        AutomationProperties.SetName(panel, row.Title + ", " + row.Detail);
        AutomationProperties.SetAutomationId(panel, "AskClaude.Row." + row.Id);
        return panel;
    }

    // MARK: Adjust

    private FrameworkElement Adjuster(AskClaudeRow row, ClipEffect effect)
    {
        var editor = Ui.Stack(6);
        editor.Children.Add(Nudge("Start", effect.Start, delta => Editor.NudgeAskClaudeEffect(row.Id, true, delta)));
        if (effect.Kind != "sound") editor.Children.Add(Nudge("End", effect.End, delta => Editor.NudgeAskClaudeEffect(row.Id, false, delta)));
        if (effect.Kind is "title" or "lowerThird")
        {
            var text = new TextBox { Text = effect.Text ?? "", MaxLength = 80, Header = "Text" };
            AutomationProperties.SetName(text, "Overlay text");
            text.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { args.Handled = true; Editor.SetAskClaudeText(row.Id, text.Text); } };
            editor.Children.Add(text);
        }
        if (effect.UsesPosition)
        {
            var options = Positions(effect.Kind);
            var choice = Ui.Choice("Position", options.Select(PositionName), Math.Max(0, Array.IndexOf(options, effect.Position)));
            choice.SelectionChanged += (_, _) => { if (choice.SelectedIndex >= 0 && options[choice.SelectedIndex] != effect.Position) Editor.SetAskClaudePosition(row.Id, options[choice.SelectedIndex]); };
            editor.Children.Add(choice);
        }
        if (effect.Kind == "sticker")
        {
            var size = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            size.Children.Add(Ui.Text("Size " + Math.Round((effect.Scale ?? 1) * 100) + "%"));
            size.Children.Add(Small("−", "Smaller emoji", () => Editor.StepAskClaudeScale(row.Id, -1)));
            size.Children.Add(Small("+", "Bigger emoji", () => Editor.StepAskClaudeScale(row.Id, 1)));
            editor.Children.Add(size);
        }
        if (effect.UsesRect)
        {
            var box = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            box.Children.Add(Ui.Text("Box"));
            box.Children.Add(Small("←", "Move the box left", () => Editor.MoveAskClaudeBox(row.Id, -0.02, 0)));
            box.Children.Add(Small("→", "Move the box right", () => Editor.MoveAskClaudeBox(row.Id, 0.02, 0)));
            box.Children.Add(Small("↑", "Move the box up", () => Editor.MoveAskClaudeBox(row.Id, 0, -0.02)));
            box.Children.Add(Small("↓", "Move the box down", () => Editor.MoveAskClaudeBox(row.Id, 0, 0.02)));
            box.Children.Add(Small("−", "Make the box smaller", () => Editor.MoveAskClaudeBox(row.Id, 0, 0, 0.9)));
            box.Children.Add(Small("+", "Make the box bigger", () => Editor.MoveAskClaudeBox(row.Id, 0, 0, 1.1)));
            editor.Children.Add(box);
            editor.Children.Add(Secondary("Drag the box on the viewer to move it."));
        }
        if (effect.Kind is "blur" or "pixelate")
        {
            string[] modes = ["none", "face", "saliency"];
            var follow = Ui.Choice("Follow", ["Hold still", "A face", "The moving subject"], Math.Max(0, Array.IndexOf(modes, effect.Tracking)));
            follow.SelectionChanged += (_, _) => { if (follow.SelectedIndex >= 0 && modes[follow.SelectedIndex] != effect.Tracking) _ = Editor.RetrackAskClaudeEffectAsync(row.Id, modes[follow.SelectedIndex]); };
            AutomationProperties.SetAutomationId(follow, "AskClaude.Tracking");
            editor.Children.Add(follow);
            if (EditorViewModel.AskClaudeFollowNote(effect) is { } note) editor.Children.Add(Secondary(note));
        }
        if (effect.Kind == "sound" && effect.Sound?.Id is { } current)
        {
            string[] sounds = ["whoosh", "pop", "ding"];
            var choice = Ui.Choice("Sound", ["Whoosh", "Pop", "Ding"], Math.Max(0, Array.IndexOf(sounds, current)));
            choice.SelectionChanged += (_, _) => { if (choice.SelectedIndex >= 0 && sounds[choice.SelectedIndex] != current) Editor.SetAskClaudeSound(row.Id, sounds[choice.SelectedIndex]); };
            editor.Children.Add(choice);
        }
        AutomationProperties.SetName(editor, "Adjust " + row.Title);
        AutomationProperties.SetAutomationId(editor, "AskClaude.Adjuster");
        return new Border { Child = editor, Padding = new(8), CornerRadius = new(6), Background = Ui.ThemeBrush(this, "VcBgSurfaceBrush") };
    }

    private FrameworkElement Nudge(string title, double value, Action<double> set)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        line.Children.Add(new TextBlock { Text = title, Width = 44, VerticalAlignment = VerticalAlignment.Center });
        line.Children.Add(new TextBlock { Text = AskClaudePrompt.Number(value) + " s", Width = 64, VerticalAlignment = VerticalAlignment.Center });
        line.Children.Add(Small("−", title + " earlier by a tenth of a second", () => set(-0.1)));
        line.Children.Add(Small("+", title + " later by a tenth of a second", () => set(0.1)));
        return line;
    }

    internal static string[] Positions(string kind) => kind switch
    {
        "title" => ["top", "center", "bottom"],
        "lowerThird" => ["bottomLeft", "bottomRight"],
        "progress" => ["top", "bottom"],
        _ => ["topLeft", "topRight", "center", "bottomLeft", "bottomRight"]
    };

    internal static string PositionName(string position) => position switch
    {
        "top" => "Top", "center" => "Centre", "bottom" => "Bottom", "topLeft" => "Top left", "topRight" => "Top right",
        "bottomLeft" => "Bottom left", _ => "Bottom right"
    };

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
