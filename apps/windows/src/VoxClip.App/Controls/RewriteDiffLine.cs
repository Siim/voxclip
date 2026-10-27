using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal sealed class RewriteDiffLine : Grid
{
    private readonly RichTextBlock text = new() { FontSize = 13, IsTextSelectionEnabled = false, TextWrapping = TextWrapping.Wrap };
    private readonly TranscriptOverlay overlay;
    private readonly List<(Run Run, RewriteDiffKind Kind)> runs = [];
    internal RewriteDiffLine(RewriteReview review)
    {
        var behind = new Border { IsHitTestVisible = false };
        var above = new Border { IsHitTestVisible = false };
        Children.Add(behind); Children.Add(text); Children.Add(above);
        overlay = new(text, behind, above);
        AutomationProperties.SetName(text, "Changes: " + review.AccessibleDescription);
        AutomationProperties.SetHelpText(text, review.AccessibleDescription);
        var paragraph = new Paragraph();
        foreach (var item in review.Runs)
        {
            var run = new Run { Text = item.Text + " ", Foreground = Ui.ThemeBrush(this,
                item.Kind == RewriteDiffKind.Removed ? "VcTextSecondaryBrush" : item.Kind == RewriteDiffKind.Inserted ? "VcAccentTextBrush" : "VcTextPrimaryBrush") };
            paragraph.Inlines.Add(run); runs.Add((run, item.Kind));
        }
        text.Blocks.Add(paragraph);
        text.SizeChanged += (_, _) => Draw();
        ActualThemeChanged += (_, _) => Draw();
        Unloaded += (_, _) => overlay.Dispose();
    }
    private void Draw()
    {
        overlay.Invalidate();
        overlay.Clear(text.ActualWidth, text.ActualHeight);
        foreach (var item in runs)
        {
            item.Run.Foreground = Ui.ThemeBrush(this, item.Kind == RewriteDiffKind.Removed ? "VcTextSecondaryBrush"
                : item.Kind == RewriteDiffKind.Inserted ? "VcAccentTextBrush" : "VcTextPrimaryBrush");
            overlay.Diff(item.Run, item.Kind);
        }
    }
}
