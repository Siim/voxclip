using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel
{
    private readonly StackPanel takeExpression = Ui.Stack(6);
    private RewriteHunkReview? renderedExpressionPhrase;
    private bool renderedExpressionEditable;

    private StackPanel ExpressionPhrase(string text, IReadOnlyList<VoiceLabAudioTag> tags, int phraseNumber,
        Action<int> remove, Action<string> add)
    {
        var identity = session.ReviewIdentity;
        var root = Ui.Stack(6);
        var quote = new RichTextBlock { TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Stretch, IsTextSelectionEnabled = false };
        var paragraph = new Paragraph();
        paragraph.Inlines.Add(new Run { Text = "“" });
        var tokens = EditingAlgorithms.SplitWords(text);
        for (var boundary = 0; boundary <= tokens.Count; boundary++)
        {
            foreach (var indexed in tags.Select((tag, index) => (Tag: tag, Index: index)).Where(item => item.Tag.BeforeToken == boundary))
            {
                var chip = ExpressionButton($"[{indexed.Tag.Tag}] ×", $"Remove {indexed.Tag.Tag} from phrase {phraseNumber}");
                chip.IsEnabled = session.ReviewIsCurrent;
                chip.Click += (_, _) => { if (identity == session.ReviewIdentity) remove(indexed.Index); };
                paragraph.Inlines.Add(new InlineUIContainer { Child = chip });
                paragraph.Inlines.Add(new Run { Text = " " });
            }
            if (boundary < tokens.Count) paragraph.Inlines.Add(new Run { Text = tokens[boundary] + (boundary + 1 < tokens.Count ? " " : "") });
        }
        paragraph.Inlines.Add(new Run { Text = "”" });
        quote.Blocks.Add(paragraph);
        root.Children.Add(quote);
        var choices = new RichTextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, IsTextSelectionEnabled = false };
        var choiceLine = new Paragraph();
        foreach (var definition in VoiceLabAudioTags.Definitions)
        {
            var button = ExpressionButton(definition.Tag, $"Add {definition.Tag} to phrase {phraseNumber}");
            button.IsEnabled = session.ReviewIsCurrent && tags.Count < 64;
            button.Click += (_, _) => { if (identity == session.ReviewIdentity) add(definition.Tag); };
            choiceLine.Inlines.Add(new InlineUIContainer { Child = button });
            choiceLine.Inlines.Add(new Run { Text = " " });
        }
        choices.Blocks.Add(choiceLine);
        var reveal = ExpressionButton("+ Expression", $"Add expression to phrase {phraseNumber}");
        reveal.IsEnabled = session.ReviewIsCurrent;
        reveal.Click += (_, _) => choices.Visibility = choices.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        root.Children.Add(reveal);
        root.Children.Add(choices);
        return root;
    }

    private static Button ExpressionButton(string text, string name)
    {
        var button = new Button { Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
            IsTabStop = true, Padding = new Thickness(6, 2, 6, 2), MaxWidth = 180, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetName(button, name);
        return button;
    }
    private const string ExpressionNote =
        "Rewrite suggests tags where your original had a laugh, sigh or pause. Tags aren't spoken words and don't count in the word check.";

    private void RenderTakeExpression(RewriteGeneration generation)
    {
        var phrase = session.PricedVoiceHunks.ElementAtOrDefault(session.ActiveWindow);
        if (ReferenceEquals(phrase, renderedExpressionPhrase) && session.ReviewIsCurrent == renderedExpressionEditable) return;
        renderedExpressionPhrase = phrase;
        renderedExpressionEditable = session.ReviewIsCurrent;
        takeExpression.Children.Clear();
        if (phrase?.PatchText is not { } text) return;
        takeExpression.Children.Add(ExpressionPhrase(text, phrase.RequestAudioTags, session.ActiveWindow + 1, index =>
        {
            foreach (var ordinal in phrase.Ordinals)
            {
                var count = session.Review?.Diff.Hunks[ordinal - 1].AudioTags.Count ?? 0;
                if (index < count) { session.RemoveExpression(ordinal, index); return; }
                index -= count;
            }
        }, tag => session.AddExpression(phrase.Ordinals[^1], tag)));
        takeExpression.Children.Add(Small(ExpressionNote));
    }
}
