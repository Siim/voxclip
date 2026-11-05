using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Music;
using Windows.Storage.Pickers;

namespace VoxClip.App.Controls;

/// <summary>The Music section under the Captions panel's rows (doc/spec/music.md §6): a MUSIC heading with Remove while a track is in use,
/// Claude's best three (or the Music folder's first files), each with ▶, its source badge and Use (a generation not yet made shows
/// "Make · $x" with the line saying what it sends: that click is the approval), the search field and Add a file…, then Volume
/// while a track is in use, and a footer that names the next step. Inline only: no dialogs (the file picker is the system's).</summary>
internal sealed class MusicSection : UserControl
{
    private readonly EditorViewModel editor;
    private readonly MusicPanelModel model;
    private readonly Func<nint> window;
    private readonly StackPanel rows = Ui.Stack(4);
    private readonly TextBlock notes = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar failure = Ui.Notice();
    private readonly TextBox search = new() { PlaceholderText = "Search music or add a file…" };
    private readonly Button remove;
    private readonly Slider volume = new() { Minimum = -40, Maximum = 0, StepFrequency = 0.5, Header = "Volume" };
    private readonly TextBlock footer = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private bool syncing;

    internal MusicSection(EditorViewModel editor, Func<nint> window)
    {
        this.editor = editor;
        this.window = window;
        model = editor.Music;
        IsTabStop = false;
        var body = Ui.Stack(8);
        var heading = new Grid();
        heading.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.Children.Add(new TextBlock { Text = "MUSIC", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        remove = Ui.Button("Remove", model.Remove);
        AutomationProperties.SetAutomationId(remove, "Music.Remove");
        Grid.SetColumn(remove, 1); heading.Children.Add(remove);
        body.Children.Add(heading);
        body.Children.Add(rows);
        body.Children.Add(notes);
        failure.Title = "Music";
        failure.Closed += (_, _) => model.DismissFailure();
        body.Children.Add(failure);
        AutomationProperties.SetAutomationId(search, "Music.Search");
        search.KeyDown += (_, args) => { if (args.Key == Windows.System.VirtualKey.Enter) { model.Query = search.Text; _ = model.SearchAsync(); } };
        var searchRow = new Grid { ColumnSpacing = 8 };
        searchRow.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        searchRow.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        searchRow.Children.Add(search);
        var add = Ui.Button("Add a file…", () => _ = AddFileAsync());
        AutomationProperties.SetAutomationId(add, "Music.AddFile");
        Grid.SetColumn(add, 1); searchRow.Children.Add(add);
        body.Children.Add(searchRow);
        AutomationProperties.SetAutomationId(volume, "Music.Volume");
        AutomationProperties.SetName(volume, "Music volume under the voice");
        // Applied when the drag ends, as one undo step.
        volume.PointerCaptureLost += (_, _) => { if (!syncing) model.SetGain(volume.Value); };
        volume.KeyUp += (_, _) => { if (!syncing) model.SetGain(volume.Value); };
        body.Children.Add(volume);
        footer.Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush");
        AutomationProperties.SetAutomationId(footer, "Music.Footer");
        body.Children.Add(footer);
        Content = body;
        model.Changed += (_, _) => DispatcherQueue.TryEnqueue(Render);
        editor.Changed += (_, _) => DispatcherQueue.TryEnqueue(Render);
        Loaded += (_, _) => { model.LoadFolder(); Render(); };
        Unloaded += (_, _) => model.StopAudition();
    }

    private void Render()
    {
        syncing = true;
        try
        {
            rows.Children.Clear();
            var current = model.Current;
            foreach (var candidate in model.Rows) rows.Children.Add(Row(candidate, current));
            if (model.EmptyText is { } empty) rows.Children.Add(new TextBlock { Text = empty, FontSize = 12, TextWrapping = TextWrapping.Wrap });
            notes.Text = string.Join("\n", model.Notes);
            notes.Visibility = model.Notes.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            if (model.Failure is { } message) Ui.Show(failure, message, InfoBarSeverity.Warning); else failure.IsOpen = false;
            remove.Visibility = current is null ? Visibility.Collapsed : Visibility.Visible;
            remove.IsEnabled = !editor.IsReadOnly;
            volume.Visibility = current is null ? Visibility.Collapsed : Visibility.Visible;
            if (current is not null) volume.Value = current.GainDb;
            volume.IsEnabled = !editor.IsReadOnly;
            footer.Text = model.Footer;
        }
        finally { syncing = false; }
    }

    private FrameworkElement Row(MusicCandidate candidate, ProjectMusic? current)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var using_ = current is not null && candidate.Id == MusicPanelModel.UsingRowId(current);
        var labels = Ui.Stack(2);
        labels.Children.Add(new TextBlock { Text = candidate.Title + "  ·  " + MusicPanelModel.Badge(candidate), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        if (MusicPanelModel.Detail(candidate) is { Length: > 0 } detail)
            labels.Children.Add(new TextBlock { Text = detail, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush") });
        if (MusicPanelModel.SendsLine(candidate) is { } sends)
            labels.Children.Add(new TextBlock { Text = sends, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Ui.ThemeBrush(this, "VcTextSecondaryBrush") });
        Grid.SetColumn(labels, 1); grid.Children.Add(labels);
        // A generation not yet made has no ▶: there is nothing to play before it is made.
        if (!candidate.NeedsGeneration)
        {
            var play = Ui.Button(model.Playing == candidate.Id ? "■" : "▶", () => model.ToggleAudition(candidate));
            AutomationProperties.SetName(play, (model.Playing == candidate.Id ? "Stop " : "Play ") + candidate.Title);
            grid.Children.Add(play);
        }
        Button? action = null;
        if (using_) labels.Children.Insert(0, new TextBlock { Text = "Using", FontSize = 11, Foreground = Ui.ThemeBrush(this, "VcAccentTextBrush") });
        else
        {
            var making = model.Phase == MusicPanelPhase.Using && model.UsingId == candidate.Id;
            action = Ui.Button(making ? "Getting it…" : MusicPanelModel.MakeLabel(candidate) ?? "Use", () => _ = model.UseAsync(candidate), accent: candidate.NeedsGeneration);
            action.IsEnabled = !editor.IsReadOnly && !making && (!candidate.NeedsGeneration || MusicPanelModel.MakeLabel(candidate) is not null);
            AutomationProperties.SetName(action, (MusicPanelModel.MakeLabel(candidate) ?? "Use") + ", " + candidate.Title);
            Grid.SetColumn(action, 2); grid.Children.Add(action);
        }
        return grid;
    }

    private async Task AddFileAsync()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary };
        foreach (var type in new[] { ".mp3", ".m4a", ".wav", ".aif", ".aiff" }) picker.FileTypeFilter.Add(type);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, window());
        if (await picker.PickSingleFileAsync() is not { } file || VoxClip.Core.Services.Music.MusicLibraryFolder.Candidate(file.Path) is not { } candidate) return;
        await model.UseAsync(candidate with { Reason = "Your file" });
    }
}
