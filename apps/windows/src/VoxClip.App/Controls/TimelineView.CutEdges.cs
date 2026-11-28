using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace VoxClip.App.Controls;

/// <summary>The cut edge row in the timeline's toolbar (design §6.8 "Cut edges", editing §5.10), after the selection's length: a selected
/// cut's edges with Use word edge or Use quiet point, the result of Fix cut edges, or the offer "{N} cuts can land in the quiet · Fix
/// cut edges". One borderless action in the toolbar's secondary text; when it can't run it stays, disabled, with the reason beside it.
/// In a narrow toolbar the reason gives way first and stays on the row's tooltip.</summary>
public sealed partial class TimelineView
{
    private readonly StackPanel cutEdgeRow = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
    private readonly TextBlock cutEdgeText = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    private readonly HyperlinkButton cutEdgeAction = new() { FontSize = 11, Padding = new(2, 0, 2, 0), MinHeight = 0, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock cutEdgeReason = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 260 };

    private void InitializeCutEdgeRow(Panel host)
    {
        AutomationProperties.SetAutomationId(cutEdgeRow, "Timeline.CutEdges");
        AutomationProperties.SetName(cutEdgeRow, "Cut edges");
        AutomationProperties.SetAutomationId(cutEdgeAction, "Timeline.CutEdges.Action");
        AutomationProperties.SetLiveSetting(cutEdgeText, AutomationLiveSetting.Polite);
        cutEdgeAction.Click += (_, _) => model?.RunCutEdgeBarAction();
        cutEdgeRow.Children.Add(new TextBlock { Text = "|", FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Opacity = .5, Margin = new(4, 0, 2, 0) });
        cutEdgeRow.Children.Add(cutEdgeText);
        cutEdgeRow.Children.Add(cutEdgeAction);
        cutEdgeRow.Children.Add(cutEdgeReason);
        host.Children.Add(cutEdgeRow);
    }

    /// <summary>The levels loaded or an open Rewrite changed: the row reads again.</summary>
    private void CutEdgesChanged(object? sender, EventArgs args) => RefreshCutEdgeRow();

    private void RefreshCutEdgeRow()
    {
        if (model?.CutEdgeBarRow is not { } row)
        {
            cutEdgeRow.Visibility = Visibility.Collapsed;
            return;
        }
        cutEdgeRow.Visibility = Visibility.Visible;
        cutEdgeText.Text = row.Action is null ? row.Text : row.Text + " ·";
        cutEdgeText.Foreground = cutEdgeReason.Foreground = Brush("VcTextSecondaryBrush");
        cutEdgeAction.Visibility = row.Action is null ? Visibility.Collapsed : Visibility.Visible;
        cutEdgeAction.Content = row.Action;
        cutEdgeAction.IsEnabled = row.Reason is null && !model.IsReadOnly && !model.Busy && !model.IsLeaving;
        AutomationProperties.SetName(cutEdgeAction, row.Action ?? "");
        AutomationProperties.SetHelpText(cutEdgeAction, row.Reason ?? "");
        cutEdgeReason.Text = row.Reason ?? "";
        cutEdgeReason.Visibility = row.Reason is not null && ActualWidth >= 1100 ? Visibility.Visible : Visibility.Collapsed;
        // A disabled button shows no tooltip, so the reason sits on the row.
        ToolTipService.SetToolTip(cutEdgeRow, row.Reason);
    }
}
