using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

/// <summary>A phrase card's words (design.md §6.3.8, voice-lab.md §8.13; Mac <c>PhraseWordingSection</c>): the segmented control
/// ✦ Suggested · My words · ● Say it myself, and the segment it shows, inline. My words has one visible field, the live "Your voice
/// reads this…" line, ✦ Shorten/Lengthen my words (fills the field, sends no take) and [Make take · ≈ $x] once its quote is for
/// these words. No dialogs.</summary>
internal sealed partial class RewritePanel
{
    private static readonly PhraseWording[] Wordings = [PhraseWording.Suggested, PhraseWording.OwnWords, PhraseWording.Microphone];
    private readonly StackPanel wordingBox = Ui.Stack(6);
    private readonly CommunityToolkit.WinUI.Controls.Segmented wordingChoice = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private readonly StackPanel ownWordsBox = Ui.Stack(6);
    private readonly TextBox ownWordsField = new() { AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, MinWidth = 0 };
    private readonly DispatcherTimer ownWordsPricing = new() { Interval = TimeSpan.FromMilliseconds(600) };
    private int renderedWordingPhrase = -1;

    private void BuildOwnWords()
    {
        AutomationProperties.SetAutomationId(wordingBox, "Rewrite.Wording");
        AutomationProperties.SetAutomationId(wordingChoice, "Rewrite.WordingChoice");
        foreach (var wording in Wordings)
        {
            var item = new CommunityToolkit.WinUI.Controls.SegmentedItem { Content = PhraseWordingCopy.Title(wording), MinWidth = 0, Padding = new(8, 4, 8, 4) };
            AutomationProperties.SetAutomationId(item, "Rewrite.Wording." + wording);
            SetName(item, PhraseWordingCopy.Title(wording).TrimStart('✦', '●', ' '));
            wordingChoice.Items.Add(item);
        }
        wordingChoice.SelectionChanged += async (_, _) =>
        {
            if (updating || wordingChoice.SelectedIndex < 0 || session.Generation is null) return;
            await session.ChooseWordingAsync(Wordings[wordingChoice.SelectedIndex], session.ActiveWindow);
            if (session.Wording(session.ActiveWindow) == PhraseWording.OwnWords) ownWordsField.Focus(FocusState.Programmatic);
        };
        AutomationProperties.SetAutomationId(ownWordsField, "Rewrite.OwnWords");
        ownWordsField.TextChanged += (_, _) =>
        {
            if (updating) return;
            session.EditOwnWords(ownWordsField.Text, session.ActiveWindow);
            // The price follows the words once typing pauses; nothing is sent until [Make take · ≈ $x].
            ownWordsPricing.Stop(); ownWordsPricing.Start();
        };
        ownWordsField.KeyDown += async (_, args) =>
        {
            if (args.Key != Windows.System.VirtualKey.Enter) return;
            args.Handled = true;
            ownWordsPricing.Stop();
            await session.PriceOwnWordsAsync(session.ActiveWindow);
        };
        ownWordsPricing.Tick += async (_, _) =>
        {
            ownWordsPricing.Stop();
            await session.PriceOwnWordsAsync(session.ActiveWindow);
        };
        wordingBox.Children.Add(wordingChoice);
        wordingBox.Children.Add(ownWordsBox);
        BuildMicrophone();
        wordingBox.Children.Add(microphoneBox);
    }

    private void RenderOwnWords(RewriteGeneration generation)
    {
        var index = session.ActiveWindow;
        var wording = session.Wording(index);
        updating = true;
        // Full labels where the column allows, short ones in a narrow column: never clipped.
        var narrow = ActualWidth is > 0 and < 360;
        for (var item = 0; item < Wordings.Length; item++)
            ((CommunityToolkit.WinUI.Controls.SegmentedItem)wordingChoice.Items[item]).Content =
                narrow ? PhraseWordingCopy.ShortTitle(Wordings[item]) : PhraseWordingCopy.Title(Wordings[item]);
        wordingChoice.SelectedIndex = Array.IndexOf(Wordings, wording);
        SetName(wordingChoice, $"Words for phrase {index + 1}");
        wordingChoice.IsEnabled = session.GenerationIsCurrent && !generation.IsRunning && !session.IsGeneratingBatch;
        updating = false;
        RenderOwnWordsBody(generation, index, wording == PhraseWording.OwnWords);
        RenderMicrophone(generation, index, wording == PhraseWording.Microphone);
        renderedWordingPhrase = index;
    }

    private void RenderOwnWordsBody(RewriteGeneration generation, int index, bool shown)
    {
        ownWordsBox.Children.Clear();
        ownWordsBox.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        if (!shown) return;
        var words = session.OwnWords(index) ?? "";
        // At most one free-text field shows (house rule): the phrase being edited; another phrase's words read as a line.
        if (session.OwnWordsEditing == index)
        {
            SetName(ownWordsField, $"Your words for phrase {index + 1}");
            ownWordsField.PlaceholderText = $"Your words for phrase {index + 1}";
            if (ownWordsField.Text != words || renderedWordingPhrase != index) { updating = true; ownWordsField.Text = words; updating = false; }
            ownWordsField.IsEnabled = !generation.IsRunning;
            ownWordsBox.Children.Add(ownWordsField);
        }
        else if (words.Length > 0)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var line = Wrapped($"My words: “{words}”", small: false);
            var edit = Ui.Button("Edit", () => { session.OwnWordsEditing = index; RenderTakes(generation); ownWordsField.Focus(FocusState.Programmatic); });
            AutomationProperties.SetAutomationId(edit, "Rewrite.OwnWordsEdit"); SetName(edit, $"Edit your words for phrase {index + 1}");
            Grid.SetColumn(edit, 1);
            row.Children.Add(line); row.Children.Add(edit);
            ownWordsBox.Children.Add(row);
        }
        if (session.OwnWordsFit(index) is { } fit)
        {
            var line = Themed(Wrapped(fit.Line), TextBlock.ForegroundProperty, fit.Fits ? "VcTextSecondaryBrush" : "VcStatusWarningBrush");
            AutomationProperties.SetAutomationId(line, "Rewrite.OwnWordsLine");
            ownWordsBox.Children.Add(line);
            if (!fit.Fits && !generation.IsRunning) RenderOwnWordsAdvice(index, fit);
        }
        if (!generation.IsRunning && session.OwnWordsTakeTitle(index) is { } title)
        {
            ownWordsBox.Children.Add(Themed(Wrapped(RewriteGeneration.SendLine), TextBlock.ForegroundProperty, "VcTextTertiaryBrush"));
            var make = new Button { Content = title, IsEnabled = session.GenerationIsCurrent && approval is null };
            AutomationProperties.SetAutomationId(make, "Rewrite.OwnWordsMakeTake");
            SetName(make, "Make a take of your words. " + title);
            make.Click += async (_, _) => await session.MakeOwnWordsTakeAsync(index, (copy, token) =>
                ConfirmVoiceActionAsync(generation, copy, () => session.GenerationIsCurrent, token));
            ownWordsBox.Children.Add(make);
        }
        else if (generation.IsPreparing && session.OwnWordsText(index) is not null)
            ownWordsBox.Children.Add(Wrapped("Pricing your words…"));
        var next = Themed(Wrapped(PhraseWordingCopy.OwnWordsFooter), TextBlock.ForegroundProperty, "VcTextTertiaryBrush");
        AutomationProperties.SetAutomationId(next, "Rewrite.OwnWordsNext");
        ownWordsBox.Children.Add(next);
    }

    /// <summary>A likely misfit's advice, with actions that fill the field and send no take. Eleven v4 has no pace setting, so no
    /// pace control shows: it could not act.</summary>
    private void RenderOwnWordsAdvice(int index, RewriteOwnWordsFit fit)
    {
        var advice = session.OwnWordsAdvice;
        var title = fit.TooLong ? "✦ Shorten my words" : "✦ Lengthen my words";
        if (advice.Phrase == index && advice.Running)
            ownWordsBox.Children.Add(Wrapped($"Asking {session.AiName} to fit your words…"));
        else if (advice.Phrase == index && advice.Awaiting)
        {
            ownWordsBox.Children.Add(Themed(Wrapped($"Sends your words to {session.AiName} with your key. It fills the field; no take is made."),
                TextBlock.ForegroundProperty, "VcTextTertiaryBrush"));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var send = Ui.Button("Send · price unavailable", () => _ = session.AdviseOwnWordsAsync(index, approved: true));
            AutomationProperties.SetAutomationId(send, "Rewrite.OwnWordsSend"); SetName(send, "Send your words to fit them, price unavailable, billed to your key");
            var cancel = Ui.Button("Cancel", session.CancelOwnWordsAdvice);
            AutomationProperties.SetAutomationId(cancel, "Rewrite.OwnWordsCancel");
            actions.Children.Add(send); actions.Children.Add(cancel);
            ownWordsBox.Children.Add(actions);
        }
        else if (session.Connector is not null)
        {
            var ask = new HyperlinkButton { Content = title };
            AutomationProperties.SetAutomationId(ask, "Rewrite.OwnWordsFit");
            SetName(ask, title.TrimStart('✦', ' '));
            ToolTipService.SetToolTip(ask, $"Ask {session.AiName} to fit your words to the gap. It fills the field; nothing is sent to ElevenLabs.");
            ask.Click += async (_, _) => await session.AdviseOwnWordsAsync(index);
            ownWordsBox.Children.Add(ask);
        }
        if (advice.Phrase == index && advice.Problem.Length > 0)
            ownWordsBox.Children.Add(Themed(Wrapped(advice.Problem), TextBlock.ForegroundProperty, "VcStatusWarningBrush"));
    }
}
