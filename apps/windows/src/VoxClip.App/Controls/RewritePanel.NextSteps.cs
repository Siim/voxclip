using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using VoxClip.App.ViewModels;
using Windows.System;

namespace VoxClip.App.Controls;

/// <summary>Rewrite never dead-ends (design.md R2, voice-lab.md §8.2.1): each stuck state's card has one plain sentence and
/// chips that wrap at any width (✦ for the AI's suggestions), then exactly one "Tell the AI what to do instead…" field. A re-ask
/// shows "Asking {AI}: “{label}”" with Stop. The footer always names the next step. No dialogs.</summary>
internal sealed partial class RewritePanel
{
    private readonly StackPanel nextSteps = Ui.Stack(8);
    private readonly TextBox tellTheAi = new() { PlaceholderText = RewriteSession.TellTheAiPlaceholder, AcceptsReturn = false, MaxLength = 1000,
        TextWrapping = TextWrapping.Wrap };
    private readonly Button tellTheAiSend = new() { Content = "Send" };
    private readonly Grid tellTheAiRow = new() { ColumnSpacing = 8 };
    private string renderedSteps = "";

    private void BuildNextSteps()
    {
        AutomationProperties.SetAutomationId(nextSteps, "Rewrite.NextSteps");
        SetName(nextSteps, "Next steps");
        AutomationProperties.SetAutomationId(tellTheAi, "Rewrite.TellTheAi");
        SetName(tellTheAi, RewriteSession.TellTheAiPlaceholder);
        AutomationProperties.SetAutomationId(tellTheAiSend, "Rewrite.TellTheAiSend");
        SetName(tellTheAiSend, "Send to the AI");
        tellTheAiRow.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        tellTheAiRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        Grid.SetColumn(tellTheAiSend, 1);
        tellTheAiRow.Children.Add(tellTheAi); tellTheAiRow.Children.Add(tellTheAiSend);
        tellTheAiSend.Click += async (_, _) => await SendTellTheAiAsync();
        tellTheAi.KeyDown += async (_, args) =>
        {
            if (args.Key != VirtualKey.Enter || textFocus?.OwnsComposition == true) return;
            args.Handled = true;
            await SendTellTheAiAsync();
        };
    }

    private async Task SendTellTheAiAsync()
    {
        var text = tellTheAi.Text;
        if (string.IsNullOrWhiteSpace(text) || !await ConfirmReaskAsync("your words")) return;
        tellTheAi.Text = "";
        await session.TellTheAiAsync(text);
    }

    /// <summary>A send billed to a key asks once inline ([Send] [Cancel]); a subscription or local AI sends at once.</summary>
    private async Task<bool> ConfirmReaskAsync(string label)
    {
        if (!session.FitAsksFirst) return true;
        if (approval is not null || session.Connector is not { } connector) return false;
        using var pending = new InlineApproval(new(Guid.NewGuid(), session.Review!, "Send this to " + connector.Name + "?",
            $"Sends {label} and the changed phrases to {connector.Name} with your key. No audio or video.", "Price unavailable · billed to your key.", "Send", true),
            () => session.IsOpen && session.Reasking is null, CancellationToken.None, Environment.TickCount);
        return await ShowVoiceApprovalAsync(pending);
    }

    private async Task InvokeChipAsync(RewriteChip chip)
    {
        if (chip.Id == RewriteSession.AskAgainChip) { await SendProposalAsync(); return; }
        if (chip.Invoke is not { } invoke) return;
        if (chip.Ai && !await ConfirmReaskAsync("“" + chip.Title + "”")) return;
        await invoke();
    }

    private void RenderNextSteps()
    {
        var cards = session.NextStepCards;
        var asking = session.ReaskingLine;
        var key = string.Join("\n", cards.Select(card => card.Id + "|" + card.Sentence + "|" + string.Join(",", card.Chips.Select(chip => chip.Id + chip.Title)))) +
            "\n" + asking + "|" + session.ReviewIsCurrent + "|" + (approval is null);
        if (key == renderedSteps) return;
        renderedSteps = key;
        nextSteps.Children.Clear();
        if (asking is not null)
        {
            var header = new Grid { ColumnSpacing = 8 };
            header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var line = Wrapped(asking, small: false);
            AutomationProperties.SetAutomationId(line, "Rewrite.Asking");
            var stop = Ui.Button("Stop", session.StopReask);
            AutomationProperties.SetAutomationId(stop, "Rewrite.ReaskStop"); SetName(stop, "Stop asking the AI");
            Grid.SetColumn(stop, 1);
            header.Children.Add(line); header.Children.Add(stop);
            nextSteps.Children.Add(header);
        }
        foreach (var card in cards)
        {
            var box = Ui.Stack(6);
            AutomationProperties.SetAutomationId(box, card.Id);
            SetName(box, card.Sentence);
            box.Children.Add(Wrapped(card.Sentence, small: false));
            var chips = new RichTextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = false, HorizontalAlignment = HorizontalAlignment.Stretch };
            var line = new Paragraph();
            foreach (var chip in card.Chips)
            {
                var button = new Button { Content = new TextBlock { Text = chip.Label, TextWrapping = TextWrapping.Wrap }, Padding = new(8, 3, 8, 3),
                    MaxWidth = 260, IsEnabled = approval is null && session.Reasking is null };
                AutomationProperties.SetAutomationId(button, chip.Id);
                SetName(button, chip.Ai ? "AI suggestion: " + chip.Title : chip.Title);
                button.Click += async (_, _) => await InvokeChipAsync(chip);
                line.Inlines.Add(new InlineUIContainer { Child = button });
                line.Inlines.Add(new Run { Text = " " });
            }
            chips.Blocks.Add(line);
            box.Children.Add(chips);
            nextSteps.Children.Add(box);
        }
        // A card folded under "Choose yourself…" carries no field, as on the Mac.
        if (cards.Any(card => card.Asks))
        {
            tellTheAi.IsEnabled = tellTheAiSend.IsEnabled = session.Connector is not null && session.Review is not null && approval is null;
            nextSteps.Children.Add(tellTheAiRow);
        }
        nextSteps.Visibility = nextSteps.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>The footer names the next step and carries its one primary action.</summary>
    private void RenderFooter()
    {
        var step = session.FooterStep;
        acceptBlocker.Text = step.Line;
        acceptBlocker.Visibility = step.Line.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        apply.Visibility = step.Title is null ? Visibility.Collapsed : Visibility.Visible;
        apply.Content = step.Title ?? "";
        SetName(apply, step.Title ?? "Apply changes");
        AutomationProperties.SetAutomationId(apply, step.Action switch
        {
            RewriteFooterAction.UseTakes => "Rewrite.UseTake",
            RewriteFooterAction.ApplyTextFixes => "Rewrite.ApplyTextFixes",
            RewriteFooterAction.Done => "Rewrite.Done",
            RewriteFooterAction.KeepFixing => "Rewrite.FooterKeepFixing",
            RewriteFooterAction.ChooseTake => "Rewrite.ChooseTake",
            RewriteFooterAction.PriceTake => "Rewrite.FooterPriceTake",
            RewriteFooterAction.KeepOriginal => "Rewrite.FooterKeepOriginal",
            RewriteFooterAction.StopReask or RewriteFooterAction.StopAutoFix => "Rewrite.FooterStop",
            _ => "Rewrite.Apply"
        });
        apply.Style = step.Action is RewriteFooterAction.StopReask or RewriteFooterAction.StopAutoFix
            ? (Style)Application.Current.Resources["DefaultButtonStyle"] : (Style)Application.Current.Resources["AccentButtonStyle"];
        apply.IsEnabled = step.Action switch
        {
            RewriteFooterAction.ApplyLocal or RewriteFooterAction.ApplyTextFixes => !session.Editor.Busy && !session.Editor.IsReadOnly && !session.Editor.IsLeaving,
            RewriteFooterAction.UseTakes => session.CanAcceptAll,
            RewriteFooterAction.KeepFixing or RewriteFooterAction.PriceTake => approval is null && session.GenerationIsCurrent,
            _ => true
        };
    }

    private async Task ApplyFooterAsync()
    {
        switch (session.FooterStep.Action)
        {
            case RewriteFooterAction.ApplyLocal:
                ReturnFocusOnClose = session.ApplyLocalChanges();
                break;
            case RewriteFooterAction.UseTakes:
                if (!session.CanAcceptAll) return;
                applyingTake = true;
                try { ReturnFocusOnClose = await session.ApplyTakeAsync(); }
                finally { applyingTake = false; }
                if (ReturnFocusOnClose || !session.IsOpen) Closed?.Invoke(this, EventArgs.Empty);
                break;
            case RewriteFooterAction.ApplyTextFixes:
                ReturnFocusOnClose = session.ApplyTextFixesOnly();
                if (ReturnFocusOnClose && session.IsOpen) Close();
                break;
            case RewriteFooterAction.Done:
                ReturnFocusOnClose = true;
                Close();
                break;
            case RewriteFooterAction.KeepFixing: session.KeepFixing(); break;
            case RewriteFooterAction.ChooseTake: await session.ChooseOfferedTakeAsync(); break;
            case RewriteFooterAction.PriceTake: await session.PriceTakeAsync(session.FooterStep.Phrase); break;
            case RewriteFooterAction.KeepOriginal: session.KeepOriginal(session.FooterStep.Phrase); break;
            case RewriteFooterAction.StopReask: session.StopReask(); break;
            case RewriteFooterAction.StopAutoFix: session.StopAutoFix(); break;
        }
    }
}
