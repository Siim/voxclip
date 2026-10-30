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
    private readonly Dictionary<Guid, (Button Play, Button Reject)> takeButtons = [];
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
        generationBody.Children.Add(takeList);
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
        generationBody.Children.Add(lengthBody);
    }
    private void TakeContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.Item is not VoiceLabTakeRow row) return;
        var content = TakeRowPresentation.From(row, session.Generation?.BestTakeId);
        SetName(args.ItemContainer, content.AutomationName);
        AutomationProperties.SetAutomationId(args.ItemContainer, "Rewrite.Take" + (row.Index + 1));
        var grid = new Grid { Height = 40, ColumnSpacing = 4, Padding = new(0), HorizontalAlignment = HorizontalAlignment.Stretch };
        if (!content.Selectable)
        {
            var failure = Small(content.FailureText!);
            renderedTakeElements.Add(failure);
            failure.FontSize = 10; failure.TextWrapping = TextWrapping.NoWrap; failure.TextTrimming = TextTrimming.CharacterEllipsis;
            failure.VerticalAlignment = VerticalAlignment.Center;
            ToolTipService.SetToolTip(grid, content.FailureText);
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
        var rows = generation.Rows;
        updating = true;
        if (!renderedRows.SequenceEqual(rows) || renderedBest != generation.BestTakeId)
        {
            brushes.RemoveAll(binding => renderedTakeElements.Contains(binding.Target));
            renderedTakeElements.Clear();
            takeButtons.Clear(); renderedRows = rows; renderedBest = generation.BestTakeId;
            takeList.ItemsSource = rows;
        }
        takeList.SelectedItem = rows.FirstOrDefault(row => row.Id == generation.SelectedTakeId);
        lengthBody.Visibility = generation.Selected is { Fits: false } ? Visibility.Visible : Visibility.Collapsed;
        lengthCopy.Text = generation.LengthCopy; retimeCopy.Text = generation.RetimeCopy;
        videoChoices.SelectedIndex = generation.VideoChoice is null ? -1 : 1;
        updating = false;
        RenderTakeButtons(generation);
        if (session.LocalAction is null)
        {
            apply.Content = generation.AcceptTitle; SetName(apply, generation.AcceptTitle);
            AutomationProperties.SetAutomationId(apply, "Rewrite.UseTake");
            apply.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            apply.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            apply.IsEnabled = generation.ReadyToAccept && !session.Editor.Busy && !session.Editor.IsReadOnly && !session.Editor.IsLeaving;
        }
        else AutomationProperties.SetAutomationId(apply, "Rewrite.Apply");
    }
    private readonly HashSet<DependencyObject> renderedTakeElements = [];
#if DEBUG
    internal void DebugValidateTakeRows()
    {
        for (var index = 0; index < renderedRows.Count; index++)
        {
            if (takeList.ContainerFromIndex(index) is not ListViewItem item || item.ActualHeight is <= 0 or > 40 ||
                item.Content is not Grid grid || grid.ActualHeight > 40 || grid.ActualWidth > item.ActualWidth + 1 ||
                AutomationProperties.GetName(item) != TakeRowPresentation.From(renderedRows[index], renderedBest).AutomationName)
                throw new InvalidOperationException("A Rewrite take row exceeds 40 epx, overflows its column, or has a stale accessible name.");
        }
    }
#endif
    private void RenderTakeButtons(RewriteGeneration generation)
    {
        foreach (var row in renderedRows)
        {
            if (!takeButtons.TryGetValue(row.Id, out var buttons)) continue;
            var content = TakeRowPresentation.From(row, generation.BestTakeId);
            var playing = generation.Audition is { IsPlaying: true } state && state.TakeId == row.Id;
            buttons.Play.Content = new FontIcon { Glyph = playing ? "\uE769" : "\uE768", FontSize = 12 };
            buttons.Play.IsEnabled = generation.CanPlayTake(row.Id);
            SetName(buttons.Play, playing ? content.PauseName : content.PlayName);
            ToolTipService.SetToolTip(buttons.Play, generation.Audition?.UnavailableReason ?? (playing ? content.PauseName : content.PlayName));
            buttons.Reject.IsEnabled = !generation.IsRunning;
        }
    }
}
