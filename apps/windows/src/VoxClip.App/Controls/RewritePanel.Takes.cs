using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.Controls;

internal sealed partial class RewritePanel
{
    private readonly ListView takeList = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = false,
        HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new(0) };
    private readonly StackPanel lengthBody = Ui.Stack(8);
    private readonly TextBlock lengthCopy = Ui.Text("");
    private readonly RadioButtons videoChoices = new() { Header = "How the video keeps up", SelectedIndex = -1, MaxColumns = 1 };
    private readonly TextBlock retimeCopy = Ui.Text("");
    private readonly StackPanel takeRecovery = Ui.Stack(6);
    private readonly TextBlock nextPace = Ui.Text("");
    private readonly Dictionary<Guid, (Button Play, Button? Reject)> takeButtons = [];
    private readonly Dictionary<Guid, Button> advisoryButtons = [];
    private IReadOnlyList<VoiceLabTakeRow> renderedRows = [];
    private Guid? renderedBest;
    private bool applyingTake;

    private void BuildTakes()
    {
        AutomationProperties.SetAutomationId(takeList, "Rewrite.Takes");
        SetName(takeList, "Generated takes");
        ScrollViewer.SetVerticalScrollBarVisibility(takeList, ScrollBarVisibility.Disabled);
        ScrollViewer.SetVerticalScrollMode(takeList, ScrollMode.Disabled);
        ScrollViewer.SetHorizontalScrollBarVisibility(takeList, ScrollBarVisibility.Disabled);
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(FrameworkElement.HeightProperty, 40d));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 40d));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        takeList.ItemContainerStyle = style;
        takeList.ContainerContentChanging += TakeContainerChanging;
        takeList.SelectionChanged += async (_, _) =>
        {
            if (updating || session.Generation is not { } generation) return;
            if (takeList.SelectedItem is VoiceLabTakeRow row) await generation.SelectTakeAsync(row.Id);
            RenderTakes(generation);
        };
        generationBody.Children.Add(takeExpression);
        generationBody.Children.Add(takeList);
        generationBody.Children.Add(nextPace);
        AutomationProperties.SetAutomationId(videoChoices, "Rewrite.VideoChoice");
        videoChoices.Items.Add(new RadioButton { Content = new TextBlock { Text = "Lip sync", TextWrapping = TextWrapping.Wrap }, IsEnabled = false });
        videoChoices.Items.Add(new RadioButton { Content = new TextBlock { Text = "Retimed source video", TextWrapping = TextWrapping.Wrap }, IsEnabled = false });
        videoChoices.SelectionChanged += (_, _) =>
        {
            if (updating || session.Generation is not { } generation) return;
            if (videoChoices.SelectedIndex >= 0) generation.ChooseVideo(videoChoices.SelectedIndex == 0 ? VoiceLabVideoMode.Lipsync : VoiceLabVideoMode.Retimed);
            RenderTakes(generation);
        };
        lengthBody.Children.Add(lengthCopy); lengthBody.Children.Add(videoChoices);
        lengthBody.Children.Add(Small("Lip sync is not available in this build."));
        lengthBody.Children.Add(retimeCopy);
        var shorter = new Button { Content = "Ask for shorter" };
        shorter.Click += async (_, _) =>
        {
            if (session.PricedVoiceHunks.ElementAtOrDefault(session.ActiveWindow) is not { } hunk || session.Review is null) return;
            if (session.Generation?.Selected?.Audio?.Fit is VoiceLabFitResult.ChangedDuration { ResidualSeconds: < 0 })
                session.ReviewSurroundingSentence(hunk.Ordinals[0]);
            else await AskForShorterAsync(hunk.Ordinals[0]);
        };
        var keep = Ui.Button("Keep original words", () =>
        {
            if (session.PricedVoiceHunks.ElementAtOrDefault(session.ActiveWindow) is { } hunk && session.Review is { } current)
                session.SetChangesIncluded(hunk.Ordinals, false);
        });
        takeRecovery.Children.Add(shorter); takeRecovery.Children.Add(keep);
        lengthBody.Children.Add(measuredFit);
        lengthBody.Children.Add(takeRecovery);
        generationBody.Children.Add(lengthBody);
    }
    private void TakeContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.Item is not VoiceLabTakeRow row) return;
        var content = TakeRowPresentation.From(row, session.Generation?.BestTakeId, session.Generation?.PhraseNumber ?? 1);
        args.ItemContainer.Height = content.JoinAdvisory ? double.NaN : 40;
        SetName(args.ItemContainer, content.AutomationName);
        AutomationProperties.SetAutomationId(args.ItemContainer, "Rewrite.Take" + (row.Index + 1));
        var grid = new Grid { Height = 40, ColumnSpacing = 4, Padding = new(0), HorizontalAlignment = HorizontalAlignment.Stretch };
        if (content.JoinAdvisory)
        {
            grid.Height = double.NaN;
            grid.RowSpacing = 4;
            grid.Padding = new(0, 4, 0, 4);
            grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
            var warning = Themed(Ui.Text(content.Copy), TextBlock.ForegroundProperty, "VcStatusWarningBrush");
            warning.TextWrapping = TextWrapping.Wrap;
            renderedTakeElements.Add(warning);
            grid.Children.Add(warning);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            var play = new Button { Content = "Play", MinWidth = 32, Height = 32, Padding = new(8, 0, 8, 0), IsTabStop = true };
            AutomationProperties.SetAutomationId(play, "Rewrite.PlayTake" + (row.Index + 1));
            play.Click += async (_, _) => { if (session.Generation is { } generation) await generation.PlayTakeAsync(row.Id); };
            var useAnyway = new Button { Content = "Use anyway", MinHeight = 32, IsTabStop = true };
            SetName(useAnyway, content.UseAnywayName);
            ToolTipService.SetToolTip(useAnyway, content.Copy);
            AutomationProperties.SetAutomationId(useAnyway, "Rewrite.UseTakeAnyway" + (row.Index + 1));
            useAnyway.Click += async (_, _) => { if (session.Generation is { } generation) await generation.UseTakeAnywayAsync(row.Id); };
            actions.Children.Add(play); actions.Children.Add(useAnyway);
            Grid.SetRow(actions, 1); grid.Children.Add(actions);
            takeButtons[row.Id] = (play, null);
            advisoryButtons[row.Id] = useAnyway;
        }
        else if (!content.Selectable)
        {
            var failure = Small(content.FailureText!);
            renderedTakeElements.Add(failure);
            failure.FontSize = 10; failure.TextWrapping = TextWrapping.NoWrap; failure.TextTrimming = TextTrimming.CharacterEllipsis;
            failure.VerticalAlignment = VerticalAlignment.Center;
            ToolTipService.SetToolTip(grid, content.FailureText);
            if (content.PlayName.Length > 0)
            {
                grid.ColumnDefinitions.Add(new() { Width = new GridLength(32) });
                grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
                var play = new Button { Content = new FontIcon { Glyph = "\uE768", FontSize = 12 }, Width = 32, Height = 32, Padding = new(0), IsTabStop = true };
                SetName(play, content.PlayName);
                ToolTipService.SetToolTip(play, content.PlayHelp);
                AutomationProperties.SetAutomationId(play, "Rewrite.PlayTake" + (row.Index + 1));
                play.Click += async (_, _) => { if (session.Generation is { } generation) await generation.PlayTakeAsync(row.Id); };
                Grid.SetColumn(failure, 1); grid.Children.Add(play);
                takeButtons[row.Id] = (play, null);
            }
            grid.Children.Add(failure);
        }
        else
        {
            foreach (var width in new[] { new GridLength(32), new GridLength(40), new GridLength(42), new GridLength(1, GridUnitType.Star), new GridLength(32) })
                grid.ColumnDefinitions.Add(new() { Width = width });
            var play = new Button { Content = new FontIcon { Glyph = "\uE768", FontSize = 12 }, Width = 32, Height = 32, Padding = new(0) };
            AutomationProperties.SetAutomationId(play, "Rewrite.PlayTake" + (row.Index + 1));
            play.Click += async (_, _) => { if (session.Generation is { } generation) await generation.PlayTakeAsync(row.Id); };
            var title = Small(content.Title); title.FontSize = 11;
            var duration = Small(content.Duration); duration.FontSize = 10;
            duration.FontFamily = (FontFamily)Application.Current.Resources["VcMonoFontFamily"];
            var note = Small(content.Note); note.FontSize = 10;
            foreach (var label in new[] { title, duration, note }) renderedTakeElements.Add(label);
            note.TextWrapping = TextWrapping.NoWrap; note.TextTrimming = TextTrimming.CharacterEllipsis;
            ToolTipService.SetToolTip(note, content.Note);
            foreach (var label in new[] { title, duration, note }) label.VerticalAlignment = VerticalAlignment.Center;
            title.TextWrapping = TextWrapping.NoWrap; duration.TextWrapping = TextWrapping.NoWrap;
            var reject = new Button { Content = new FontIcon { Glyph = "\uE711", FontSize = 12 }, Width = 32, Height = 32, Padding = new(0) };
            SetName(reject, content.RejectName); ToolTipService.SetToolTip(reject, content.RejectName);
            AutomationProperties.SetAutomationId(reject, "Rewrite.RejectTake" + (row.Index + 1));
            reject.Click += async (_, _) => { if (session.Generation is { } generation) await generation.RejectTakeAsync(row.Id); };
            FrameworkElement noteCell = content.BestMatch ? Themed(new Border { Child = note, BorderThickness = new(1),
                CornerRadius = new(4), Padding = new(4, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center }, Border.BorderBrushProperty, "VcLineStrongBrush") : note;
            if (noteCell is Border) renderedTakeElements.Add(noteCell);
            FrameworkElement[] cells = [play, title, duration, noteCell, reject];
            for (var index = 0; index < cells.Length; index++) { Grid.SetColumn(cells[index], index); grid.Children.Add(cells[index]); }
            takeButtons[row.Id] = (play, reject);
        }
        args.ItemContainer.Content = grid;
        args.Handled = true;
        if (session.Generation is { } current) RenderTakeButtons(current);
    }
    private void RenderTakes(RewriteGeneration generation)
    {
        RenderTakeExpression(generation);
        var rows = generation.Rows;
        updating = true;
        if (!renderedRows.SequenceEqual(rows) || renderedBest != generation.BestTakeId)
        {
            brushes.RemoveAll(binding => renderedTakeElements.Contains(binding.Target));
            renderedTakeElements.Clear();
            takeButtons.Clear(); advisoryButtons.Clear(); renderedRows = rows; renderedBest = generation.BestTakeId;
            takeList.ItemsSource = rows;
        }
        takeList.SelectedItem = rows.FirstOrDefault(row => row.Id == generation.SelectedTakeId);
        lengthBody.Visibility = generation.Selected is { Fits: false } ? Visibility.Visible : Visibility.Collapsed;
        takeRecovery.Visibility = generation.NeedsShorterWording ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in takeRecovery.Children.OfType<Button>()) button.IsEnabled = session.ReviewIsCurrent && !requestingApproval;
        if (takeRecovery.Children.OfType<Button>().FirstOrDefault() is { } retry)
            retry.Content = generation.Selected?.Audio?.Fit is VoiceLabFitResult.ChangedDuration { ResidualSeconds: < 0 } ? "Use surrounding sentence" : "Ask for shorter";
        nextPace.Text = generation.NextPace is { } pace && pace != 1 ? FormattableString.Invariant($"Next take at {pace:F2}× pace") : "";
        nextPace.Visibility = nextPace.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        lengthCopy.Text = generation.LengthCopy; retimeCopy.Text = generation.RetimeCopy;
        RenderMeasuredFit(generation);
        videoChoices.SelectedIndex = generation.VideoChoice is null ? -1 : 1;
        updating = false;
        RenderTakeButtons(generation);
        if (session.LocalAction is null)
        {
            var title = session.GenerationWindows.Count > 1 ? "Use Reviewed Takes" : generation.AcceptTitle;
            apply.Content = title; SetName(apply, title);
            AutomationProperties.SetAutomationId(apply, "Rewrite.UseTake");
            apply.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            apply.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            apply.IsEnabled = session.CanAcceptAll;
        }
        else AutomationProperties.SetAutomationId(apply, "Rewrite.Apply");
    }
    private readonly HashSet<DependencyObject> renderedTakeElements = [];
#if DEBUG
    internal void DebugValidateTakeRows()
    {
        for (var index = 0; index < renderedRows.Count; index++)
        {
            var advisory = renderedRows[index].HasJoinAdvisory;
            if (takeList.ContainerFromIndex(index) is not ListViewItem item || item.ActualHeight <= 0 || !advisory && item.ActualHeight > 40 ||
                item.Content is not Grid grid || !advisory && grid.ActualHeight > 40 || grid.ActualWidth > item.ActualWidth + 1 ||
                AutomationProperties.GetName(item) != TakeRowPresentation.From(renderedRows[index], renderedBest, session.Generation?.PhraseNumber ?? 1).AutomationName)
                throw new InvalidOperationException("A Rewrite take row exceeds 40 epx, overflows its column, or has a stale accessible name.");
        }
    }
#endif
    private void RenderTakeButtons(RewriteGeneration generation)
    {
        foreach (var row in renderedRows)
        {
            if (!takeButtons.TryGetValue(row.Id, out var buttons)) continue;
            var content = TakeRowPresentation.From(row, generation.BestTakeId, generation.PhraseNumber);
            var playing = generation.Audition is { IsPlaying: true } state && state.TakeId == row.Id;
            buttons.Play.Content = content.JoinAdvisory ? playing ? "Pause" : "Play" : new FontIcon { Glyph = playing ? "\uE769" : "\uE768", FontSize = 12 };
            buttons.Play.IsEnabled = generation.CanPlayTake(row.Id);
            SetName(buttons.Play, playing ? content.PauseName : content.PlayName);
            ToolTipService.SetToolTip(buttons.Play, generation.Audition?.UnavailableReason ?? (content.Selectable && playing ? content.PauseName : content.PlayHelp));
            if (buttons.Reject is { } reject) reject.IsEnabled = !generation.IsRunning;
            if (advisoryButtons.TryGetValue(row.Id, out var useAnyway))
                useAnyway.IsEnabled = generation.CanUseTakeAnyway(row.Id);
        }
    }
}
