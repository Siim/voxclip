using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

/// <summary>Automatic fixes, inline under the takes (design.md R2, voice-lab.md §8.2.2): the live line with one Stop, the
/// fallback controls folded under "Choose yourself…", [Keep fixing · ≈ $y] at the cap, and Undo for a phrase kept as recorded.
/// No dialogs.</summary>
internal sealed partial class RewritePanel
{
    private readonly StackPanel autoFixBox = Ui.Stack(8);
    private readonly TextBlock autoFixAllowance = Ui.Text("");
    private string autoFixAnnouncement = "";
    /// <summary>The fallback controls (measured rewording, recovery buttons) show only when the fixes aren't running, or once
    /// "Choose yourself…" was opened.</summary>
    private bool FallbackShown => session.AutoFix.ChoicesShown;

    private void BuildAutoFix()
    {
        AutomationProperties.SetAutomationId(autoFixBox, "Rewrite.AutoFix");
        SetName(autoFixBox, "Automatic fixes");
        AutomationProperties.SetAutomationId(autoFixAllowance, "Rewrite.AutoFixAllowance");
        autoFixAllowance.TextWrapping = TextWrapping.Wrap;
        autoFixAllowance.FontSize = 11;
        Themed(autoFixAllowance, TextBlock.ForegroundProperty, "VcTextSecondaryBrush");
    }

    private void RenderAutoFix()
    {
        var state = session.AutoFix;
        autoFixAllowance.Text = session.AutoFixAllowanceLine ?? "";
        autoFixAllowance.Visibility = autoFixAllowance.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        autoFixBox.Children.Clear();
        if (state.Running)
        {
            var header = new Grid { ColumnSpacing = 8 };
            header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var line = Wrapped(state.Lines.Values.FirstOrDefault() ?? "Rewrite fixes stuck phrases on its own.", small: false);
            AutomationProperties.SetAutomationId(line, "Rewrite.AutoFixStatus");
            var stop = Ui.Button("Stop", () => session.StopAutoFix());
            AutomationProperties.SetAutomationId(stop, "Rewrite.AutoFixStop"); SetName(stop, "Stop automatic fixes");
            Grid.SetColumn(stop, 1);
            header.Children.Add(line); header.Children.Add(stop);
            autoFixBox.Children.Add(header);
            autoFixBox.Children.Add(Wrapped($"Spent {RewriteSession.Dollars(state.Spent)} of {RewriteSession.Dollars(state.Allowance)} on automatic fixes."));
            if (!state.ShowChoices)
            {
                var choose = new HyperlinkButton { Content = "Choose yourself…" };
                AutomationProperties.SetAutomationId(choose, "Rewrite.ChooseYourself");
                SetName(choose, "Choose yourself: show the next steps");
                choose.Click += (_, _) => session.ShowAutoFixChoices();
                autoFixBox.Children.Add(choose);
            }
        }
        else if (session.KeepFixingTitle is { } title)
        {
            autoFixBox.Children.Add(Wrapped(session.AutoFixCapLine ?? "", small: false));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var keep = new Button { Content = title, Style = (Style)Application.Current.Resources["AccentButtonStyle"],
                IsEnabled = session.GenerationIsCurrent && approval is null };
            AutomationProperties.SetAutomationId(keep, "Rewrite.KeepFixing"); SetName(keep, title);
            keep.Click += (_, _) => session.KeepFixing();
            var stop = Ui.Button("Stop", () => session.StopAutoFix());
            AutomationProperties.SetAutomationId(stop, "Rewrite.AutoFixStop"); SetName(stop, "Stop automatic fixes");
            actions.Children.Add(keep); actions.Children.Add(stop);
            autoFixBox.Children.Add(actions);
        }
        else if (state.Armed && state.Stopped)
            autoFixBox.Children.Add(Wrapped(state.StopReason.Length > 0 ? state.StopReason : "Automatic fixes stopped. Everything made so far is kept."));
        foreach (var index in session.LeftOutPhrases)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var note = Wrapped($"Phrase {index + 1} keeps your original words. Its takes stay listed.");
            note.VerticalAlignment = VerticalAlignment.Center;
            var phrase = index;
            var undo = Ui.Button("Undo", () => session.UndoKeepOriginal(phrase));
            AutomationProperties.SetAutomationId(undo, "Rewrite.UndoKeepOriginal" + (index + 1));
            SetName(undo, $"Undo keep original words for phrase {index + 1}");
            undo.IsEnabled = session.GenerationIsCurrent && !session.IsGeneratingBatch;
            row.Children.Add(note); row.Children.Add(undo);
            autoFixBox.Children.Add(row);
        }
        foreach (var note in state.Notes) autoFixBox.Children.Add(Wrapped(note));
        autoFixBox.Visibility = autoFixBox.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (IsLoaded && state.Announcement.Length > 0 && state.Announcement != autoFixAnnouncement)
        {
            autoFixAnnouncement = state.Announcement;
            Ui.Announce(this, autoFixAnnouncement, "rewrite", AutomationNotificationProcessing.CurrentThenMostRecent);
        }
    }
}
