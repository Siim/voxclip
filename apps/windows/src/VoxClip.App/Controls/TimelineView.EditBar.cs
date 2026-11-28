using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

/// <summary>The timeline's edit bar (issue #41), the Windows twin of the Mac edit bar's range actions. It takes the item bar's row
/// whenever no item is selected: Cut selection (Cut range, disabled, while an exact range is set), then Play range, ✦ Ask Claude,
/// Add title, Trim item to range and Make clip, and what is selected or how to select. They act on the exact range, else on the
/// selected words; each is always shown and disabled with its reason, and drops to its icon when the bar is narrow.</summary>
public sealed partial class TimelineView
{
    private sealed class EditBarPanel : Grid
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new EditBarPeer(this);

        private sealed class EditBarPeer(EditBarPanel owner) : FrameworkElementAutomationPeer(owner)
        {
            protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;
        }
    }

    /// <summary>One edit bar action: its tooltip host (a disabled button shows no tooltip of its own), button and label.</summary>
    private sealed record EditBarAction(Border Host, Button Button, TextBlock Label, Func<EditorViewModel, bool> Enabled,
        Func<EditorViewModel, string> Title, Func<EditorViewModel, string> Tip);

    private const double EditBarHeight = 38;
    private const string CutHelp = "Cut the selected words and pauses (Delete). Undo with Ctrl+Z.";
    private readonly EditBarPanel editBar = new() { Padding = new(8, 3, 8, 3), ColumnSpacing = 10, Height = EditBarHeight, Visibility = Visibility.Collapsed };
    private readonly StackPanel editBarActions = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock editBarStatus = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly List<EditBarAction> editBarItems = [];
    private double editBarLabelsWidth = double.NaN;
    private bool editBarCompact;
    /// <summary>Make clip in the edit bar: the page makes the clip and reveals its row, as the transcript's Make clip does.</summary>
    public event EventHandler? MakeClipRequested;

    private void InitializeEditBar(Grid layout)
    {
        AutomationProperties.SetName(editBar, "Timeline edits");
        AutomationProperties.SetAutomationId(editBar, "Timeline.EditBar");
        AutomationProperties.SetLiveSetting(editBarStatus, AutomationLiveSetting.Polite);
        editBar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        editBar.ColumnDefinitions.Add(new());
        editBar.Children.Add(editBarActions);
        Grid.SetColumn(editBarStatus, 1); editBar.Children.Add(editBarStatus);
        EditBarItem("CutSelection", new SymbolIcon(Symbol.Cut), model => model.CutSelection(),
            model => model.TimelineCutReason is null, model => model.ExactRange is null ? "Cut selection" : "Cut range",
            model => model.TimelineCutReason ?? CutHelp);
        editBarActions.Children.Add(new AppBarSeparator { Padding = new(0), Height = 24, VerticalAlignment = VerticalAlignment.Center });
        EditBarItem("PlayRange", new SymbolIcon(Symbol.Play), model => model.PlayTimelineRange(),
            model => model.TimelinePlayRangeReason is null, _ => "Play range", model => model.TimelinePlayRangeReason ?? "Play the range and stop at its end");
        EditBarItem("AskClaude", new TextBlock { Text = "✦", FontSize = 14, VerticalAlignment = VerticalAlignment.Center }, model => model.AskClaudeOnTimelineRange(),
            model => model.TimelineAskClaudeReason is null, _ => "Ask Claude", model => model.TimelineAskClaudeReason ?? "Ask Claude about the range");
        EditBarItem("AddTitle", new SymbolIcon(Symbol.Font), model => model.AddTimelineTitleOverRange(),
            model => model.TimelineAddTitleReason is null, _ => "Add title", model => model.TimelineAddTitleReason ?? "Add a title over the range");
        EditBarItem("TrimToRange", new SymbolIcon(Symbol.Crop), model => model.TrimTimelineItemToRange(),
            model => model.TimelineTrimToRangeReason is null, _ => "Trim item to range", model => model.TimelineTrimToRangeReason ??
                (model.TimelineRangeTrimTarget is { } target ? $"Trim the {target.Kind.ToLowerInvariant()} to the range" : "Trim an item to the range"));
        EditBarItem("MakeClip", new SymbolIcon(Symbol.Video), model => { if (MakeClipRequested is { } request) request(this, EventArgs.Empty); else model.MakeClip(); },
            model => model.TimelineMakeClipReason is null, _ => "Make clip", model => model.TimelineMakeClipReason ?? EditorViewModel.TimelineMakeClipHelp);
        Grid.SetRow(editBar, 2); layout.Children.Add(editBar);
        editBar.SizeChanged += (_, _) => UpdateEditBarCompact();
    }

    private void EditBarItem(string id, FrameworkElement icon, Action<EditorViewModel> run, Func<EditorViewModel, bool> enabled,
        Func<EditorViewModel, string> title, Func<EditorViewModel, string> tip)
    {
        var label = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        var glyph = icon is SymbolIcon ? new Viewbox { Width = 14, Height = 14, Child = icon, VerticalAlignment = VerticalAlignment.Center } : icon;
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(glyph); content.Children.Add(label);
        var button = new Button { Content = content, Padding = new(6, 2, 6, 2), MinWidth = 0 };
        AutomationProperties.SetAutomationId(button, "Timeline." + id);
        button.Click += (_, _) => { if (model is { } current && enabled(current)) { run(current); Draw(); } };
        var host = new Border { Child = button, VerticalAlignment = VerticalAlignment.Center };
        editBarActions.Children.Add(host);
        editBarItems.Add(new(host, button, label, enabled, title, tip));
    }

    /// <summary>Shows the edit bar in the item bar's row and brings each action's title, state and reason up to date.</summary>
    private bool RefreshEditBar()
    {
        if (model is null) { editBar.Visibility = Visibility.Collapsed; return false; }
        editBar.Visibility = Visibility.Visible;
        foreach (var action in editBarItems)
        {
            var title = action.Title(model); var tip = action.Tip(model);
            if (action.Label.Text != title) { action.Label.Text = title; editBarLabelsWidth = double.NaN; }
            action.Button.IsEnabled = action.Enabled(model);
            AutomationProperties.SetName(action.Button, title);
            AutomationProperties.SetHelpText(action.Button, tip);
            ToolTipService.SetToolTip(action.Host, tip);
        }
        editBarStatus.Text = model.TimelineRangeMessage ?? model.TimelineSelectionStatus;
        editBarStatus.Foreground = Brush("VcTextSecondaryBrush");
        ToolTipService.SetToolTip(editBarStatus, editBarStatus.Text);
        UpdateEditBarCompact();
        return true;
    }

    /// <summary>The actions show their titles while they fit beside a little status, else only their icons (titles stay their
    /// names and tooltips).</summary>
    private void UpdateEditBarCompact()
    {
        if (editBar.Visibility != Visibility.Visible || editBar.ActualWidth <= 0) return;
        if (double.IsNaN(editBarLabelsWidth))
        {
            foreach (var action in editBarItems) action.Label.Visibility = Visibility.Visible;
            editBarActions.Measure(new(double.PositiveInfinity, EditBarHeight));
            editBarLabelsWidth = editBarActions.DesiredSize.Width;
            editBarCompact = false;
        }
        var compact = editBarLabelsWidth + 16 + 120 > editBar.ActualWidth;
        if (compact == editBarCompact && editBarItems.All(action => action.Label.Visibility == (compact ? Visibility.Collapsed : Visibility.Visible))) return;
        editBarCompact = compact;
        foreach (var action in editBarItems) action.Label.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
    }
}
