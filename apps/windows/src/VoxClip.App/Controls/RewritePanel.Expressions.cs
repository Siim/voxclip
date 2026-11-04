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

    /// <summary>The change whose newly added expression is being placed: click a word to put it before that word.</summary>
    private (int Ordinal, int Index)? placing;

    private StackPanel ExpressionPhrase(string text, IReadOnlyList<VoiceLabAudioTag> tags, int phraseNumber,
        Action<int> remove, Action<string> add, int? ordinal = null)
    {
        var identity = session.ReviewIdentity;
        var editable = session.ExpressionsEditable;
        var root = Ui.Stack(6);
        var quote = new RichTextBlock { TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Stretch, IsTextSelectionEnabled = false };
        var paragraph = new Paragraph();
        var tokens = EditingAlgorithms.SplitWords(text);
        var placingHere = ordinal is { } here && placing is { } active && active.Ordinal == here && active.Index < tags.Count;
        foreach (var (tagIndex, wordIndex, piece) in RewriteQuote.Pieces(tokens, tags))
        {
            if (tagIndex is not null && !editable) paragraph.Inlines.Add(new Run { Text = "[" + piece + "] " });
            else if (tagIndex is { } index)
            {
                var chip = ExpressionButton($"[{piece}] ×", $"Remove {piece} from phrase {phraseNumber}");
                chip.Click += (_, _) => { if (identity == session.ReviewIdentity) { placing = null; remove(index); } };
                paragraph.Inlines.Add(new InlineUIContainer { Child = chip });
                paragraph.Inlines.Add(new Run { Text = " " });
            }
            else if (wordIndex is { } boundary && placingHere && placing is { } target)
            {
                var word = new HyperlinkButton { Content = piece, Padding = new Thickness(2, 0, 2, 0) };
                AutomationProperties.SetName(word, $"Place {tags[target.Index].Tag} before {tokens[boundary]}");
                word.Click += (_, _) =>
                {
                    if (identity != session.ReviewIdentity) return;
                    placing = null;
                    renderedReview = null;
                    session.MoveExpression(target.Ordinal, target.Index, boundary);
                };
                paragraph.Inlines.Add(new InlineUIContainer { Child = word });
                paragraph.Inlines.Add(new Run { Text = " " });
            }
            else paragraph.Inlines.Add(new Run { Text = piece + " " });
        }
        quote.Blocks.Add(paragraph);
        root.Children.Add(quote);
        if (placingHere) root.Children.Add(Wrapped("Click a word to place the expression before it. It starts before the first changed word."));
        if (ordinal is { } noted && session.ExpressionNote(noted) is { } note) root.Children.Add(Wrapped(note));
        var choices = new RichTextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, IsTextSelectionEnabled = false };
        var choiceLine = new Paragraph();
        foreach (var definition in VoiceLabAudioTags.Definitions)
        {
            var button = ExpressionButton(definition.Tag, $"Add {definition.Tag} to phrase {phraseNumber}");
            button.Click += (_, _) =>
            {
                if (identity != session.ReviewIdentity) return;
                if (ordinal is { } owner) placing = (owner, tags.Count);
                renderedReview = null;
                add(definition.Tag);
            };
            choiceLine.Inlines.Add(new InlineUIContainer { Child = button });
            choiceLine.Inlines.Add(new Run { Text = " " });
        }
        choices.Blocks.Add(choiceLine);
        // + Expression shows only where it can act: an editable phrase with room for another tag.
        if (editable && tags.Count < 64)
        {
            var reveal = ExpressionButton("+ Expression", $"Add expression to phrase {phraseNumber}");
            reveal.Click += (_, _) => choices.Visibility = choices.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            root.Children.Add(reveal);
            root.Children.Add(choices);
        }
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
        if (ReferenceEquals(phrase, renderedExpressionPhrase) && session.ExpressionsEditable == renderedExpressionEditable) return;
        renderedExpressionPhrase = phrase;
        renderedExpressionEditable = session.ExpressionsEditable;
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
