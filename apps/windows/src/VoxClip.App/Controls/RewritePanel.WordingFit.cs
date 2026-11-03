using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

/// <summary>Automatic wording fit, inline in the Rewrite panel: running rounds with Stop, a billed connector's one Fit/Skip
/// approval, and the measured-length rewording after a take with its priced Make Take. No dialogs.</summary>
internal sealed partial class RewritePanel
{
    private readonly StackPanel wordingFit = Ui.Stack(8);
    private readonly StackPanel measuredFit = Ui.Stack(8);

    private void BuildWordingFit()
    {
        AutomationProperties.SetAutomationId(wordingFit, "Rewrite.WordingFit");
        SetName(wordingFit, "Automatic wording fit");
        AutomationProperties.SetAutomationId(measuredFit, "Rewrite.MeasuredFit");
        SetName(measuredFit, "Measured take wording recovery");
    }

    private TextBlock Wrapped(string text, bool small = true)
    {
        var label = small ? Small(text) : Ui.Text(text);
        label.TextWrapping = TextWrapping.Wrap;
        return label;
    }

    private void RenderWordingFit()
    {
        wordingFit.Children.Clear();
        if (session.WordingFitAwaitingApproval)
        {
            wordingFit.Children.Add(Wrapped(session.FitApprovalLine, small: false));
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var fit = Ui.Button("Fit", () => _ = session.FitWordingAsync(true));
            var skip = Ui.Button("Skip", session.StopWordingFit);
            AutomationProperties.SetAutomationId(fit, "Rewrite.FitApprove"); SetName(fit, "Fit wording automatically, up to 3 requests");
            AutomationProperties.SetAutomationId(skip, "Rewrite.FitSkip"); SetName(skip, "Skip automatic wording fit");
            actions.Children.Add(fit); actions.Children.Add(skip);
            wordingFit.Children.Add(actions);
            wordingFit.Children.Add(Wrapped($"Sends only these phrases and their timing to {session.Connector?.Name}. That approval covers this reply only."));
        }
        else if (session.WordingFitRunning)
        {
            var header = new Grid { ColumnSpacing = 8 };
            header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var title = Wrapped(session.FitRunningHeadline, small: false);
            AutomationProperties.SetAutomationId(title, "Rewrite.FitStatus");
            var stop = Ui.Button("Stop", session.StopWordingFit);
            AutomationProperties.SetAutomationId(stop, "Rewrite.FitStop"); SetName(stop, "Stop fitting wording");
            Grid.SetColumn(stop, 1);
            header.Children.Add(title); header.Children.Add(stop);
            wordingFit.Children.Add(header);
            var progress = new ProgressBar { Minimum = 0, Maximum = 3, Value = session.WordingFitRound, Height = 2, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(progress, "Rewrite.FitProgress");
            SetName(progress, $"Fitting wording, round {session.WordingFitRound} of 3");
            wordingFit.Children.Add(progress);
            foreach (var phrase in session.WordingFitPhrases) wordingFit.Children.Add(Wrapped(RewriteSession.FitPhraseLine(phrase)));
            wordingFit.Children.Add(Wrapped(session.FitNote));
        }
        else if (session.WordingFitStopped) wordingFit.Children.Add(Wrapped("Fitting stopped. Your latest proposal is kept."));
        if (session.WordingFitProblem.Length > 0)
            wordingFit.Children.Add(Themed(Wrapped(session.WordingFitProblem), TextBlock.ForegroundProperty, "VcStatusWarningBrush"));
        wordingFit.Visibility = wordingFit.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RenderMeasuredFit(RewriteGeneration generation)
    {
        measuredFit.Children.Clear();
        if (session.MeasuredWording is not { } suggestion || !ReferenceEquals(session.GenerationWindows.ElementAtOrDefault(suggestion.Window), generation))
        {
            measuredFit.Visibility = Visibility.Collapsed;
            return;
        }
        measuredFit.Visibility = Visibility.Visible;
        measuredFit.Children.Add(Wrapped(suggestion.Heading));
        if (suggestion.AwaitingApproval)
        {
            measuredFit.Children.Add(Wrapped("Fit wording automatically · 1 request · price unavailable · billed to your key"));
            var fit = Ui.Button("Fit", () => _ = session.ApproveMeasuredFitAsync());
            AutomationProperties.SetAutomationId(fit, "Rewrite.MeasuredFitApprove"); SetName(fit, "Fit wording using the measured take length");
            measuredFit.Children.Add(fit);
        }
        else if (suggestion.Preparing) measuredFit.Children.Add(Wrapped("Rewording with the measured length…"));
        else if (suggestion.Text is { } text)
        {
            var reworded = Wrapped("Reworded with the measured length: “" + text + "”", small: false);
            reworded.IsTextSelectionEnabled = true;
            measuredFit.Children.Add(reworded);
            if (session.MeasuredGeneration is { } window)
            {
                var title = window.IsPreparing || window.Quote is null ? "Make Take" : window.GenerationButtonTitle("Make Take");
                var make = new Button { Content = title, IsEnabled = window.CanExecute && session.GenerationIsCurrent && approval is null };
                AutomationProperties.SetAutomationId(make, "Rewrite.MeasuredMakeTake");
                SetName(make, "Make a new take with the reworded text. " + title);
                make.Click += async (_, _) => await session.MakeMeasuredTakeAsync((copy, token) =>
                    ConfirmVoiceActionAsync(window, copy, () => session.GenerationIsCurrent, token));
                measuredFit.Children.Add(make);
                measuredFit.Children.Add(Wrapped(RewriteGeneration.SendLine));
                if (window.Quote is { } quote) DispatcherQueue.TryEnqueue(() => window.MarkEstimateShown(quote));
            }
        }
        else if (suggestion.KeepOriginal) measuredFit.Children.Add(Wrapped("This phrase cannot fit naturally. Keep the original words or keep this take."));
        var keep = Ui.Button(suggestion.AwaitingApproval ? "Skip" : $"Keep Take {suggestion.Number}", () => _ = session.KeepMeasuredTakeAsync());
        AutomationProperties.SetAutomationId(keep, "Rewrite.MeasuredKeep");
        SetName(keep, suggestion.AwaitingApproval ? "Skip measured rewording" : $"Keep Take {suggestion.Number}");
        measuredFit.Children.Add(keep);
        if (suggestion.Problem.Length > 0)
            measuredFit.Children.Add(Themed(Wrapped(suggestion.Problem), TextBlock.ForegroundProperty, "VcStatusWarningBrush"));
    }
}
