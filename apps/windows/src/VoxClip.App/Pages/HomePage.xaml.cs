using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
namespace VoxClip.App.Pages;

/// <summary>Home: drop bar, AI callout and the Recent projects grid; design §7 (ADR-R29), owned by win-ui.</summary>
public sealed partial class HomePage : Page
{
    private MainWindow? window;
    private CancellationTokenSource loads = new();
    private readonly Dictionary<string, DateTime> loadedAt = new(StringComparer.OrdinalIgnoreCase);
    private AiCallout? callout;
    private DateTime aiCheckedAt;
    /// <summary>The connector check in flight; a newer check cancels it and only the newest result is shown.</summary>
    private CancellationTokenSource? aiCheck;
    /// <summary>The connector settings the last check saw, and whether it must run again when Home is next shown.</summary>
    private string aiSettings = "";
    private bool aiStale = true;
    private (bool Words, string Style) cardSettings;
    /// <summary>UI-thread view model.</summary>
    public HomeViewModel ViewModel { get; } = new();
    /// <summary>Construct empty Home controls without calling unfinished services.</summary>
    public HomePage()
    {
        InitializeComponent();
        // Metadata, thumbnail and connector reads stop while Home is hidden; the next Refresh resumes the cancelled ones.
        Unloaded += (_, _) => { if (aiCheck is not null) aiStale = true; loads.Cancel(); loads = new(); };
    }
    internal void Attach(MainWindow owner)
    {
        window = owner;
        App.Services.SettingsChanged += SettingsChanged;
        TranscriptionActivity.Changed += TranscriptionChanged;
        cardSettings = CardSettings();
        StartupBar.Message = App.Services.StartupNotice;
        StartupBar.IsOpen = App.Services.StartupNotice.Length > 0;
        Refresh();
    }
    /// <summary>The window closed: stop reads and drop the app-wide subscriptions.</summary>
    internal void Detach()
    {
        loads.Cancel();
        App.Services.SettingsChanged -= SettingsChanged;
        TranscriptionActivity.Changed -= TranscriptionChanged;
    }
    private void SettingsChanged(object? sender, EventArgs args)
    {
        // Only a change to the chosen connector's settings looks at it again, and not while Home is hidden.
        if (ConnectorSettings(App.Services.Get("llm.connector", "")) != aiSettings)
        {
            aiStale = true;
            if (IsLoaded) _ = RefreshAiAsync();
        }
        // "Show transcript words on placeholders" or the default caption style changed: make every card again.
        if (CardSettings() == cardSettings) return;
        cardSettings = CardSettings();
        loadedAt.Clear();
        Refresh();
    }
    private static (bool Words, string Style) CardSettings() => (App.Services.ShowPlaceholderWords, App.Services.Get("captions.defaultStyleId", "vox-highlight"));
    private void TranscriptionChanged(object? sender, EventArgs args)
    {
        foreach (var row in ViewModel.RecentProjects) row.Transcription = TranscriptionActivity.Status(row.Path);
    }
    /// <summary>Home is cached per window (ADR-R29), so it re-reads the recent list, the open flags and any project file
    /// that changed since its card was made each time it is shown.</summary>
    internal void Refresh()
    {
        var paths = App.Services.Get<string[]>("general.recentProjects", []);
        foreach (var stale in ViewModel.RecentProjects.Where(row => !paths.Contains(row.Path, StringComparer.OrdinalIgnoreCase)).ToArray())
        {
            ViewModel.RecentProjects.Remove(stale);
            loadedAt.Remove(stale.Path);
        }
        for (var index = 0; index < paths.Length; index++)
        {
            var row = ViewModel.RecentProjects.FirstOrDefault(item => item.Path.Equals(paths[index], StringComparison.OrdinalIgnoreCase));
            if (row is null)
            {
                row = new RecentProject(paths[index], Path.GetFileNameWithoutExtension(paths[index]));
                ViewModel.RecentProjects.Insert(index, row);
            }
            else if (ViewModel.RecentProjects.IndexOf(row) is var current && current != index) ViewModel.RecentProjects.Move(current, index);
            row.IsOpen = App.Windows.Any(item => string.Equals(item.ProjectPath, row.Path, StringComparison.OrdinalIgnoreCase));
            row.Transcription = TranscriptionActivity.Status(row.Path);
            if (!loadedAt.TryGetValue(row.Path, out var stamp) || stamp != Stamp(row.Path)) _ = LoadRecentAsync(row, loads.Token);
        }
        // A CLI sign-in or a local server can change outside VoxClip; look again at most once a minute.
        if (HomeViewModel.ConnectorCheckDue(aiStale, aiCheck is { IsCancellationRequested: false }, aiCheckedAt, DateTime.UtcNow)) _ = RefreshAiAsync();
    }
    private static DateTime Stamp(string path)
    {
        try { return File.GetLastWriteTimeUtc(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return DateTime.MinValue; }
    }
    /// <summary>Read the project, resolve its video, set its caption card and make the poster frame, all off the UI thread
    /// (design §5.4.5). A read still pending after 300 ms sweeps the tile's sheen; nothing is ever written back.</summary>
    private async Task LoadRecentAsync(RecentProject row, CancellationToken ct)
    {
        var stamp = Stamp(row.Path);
        loadedAt[row.Path] = stamp;
        _ = StallAsync(row, ct);
        var (wordsVisible, defaultStyle) = cardSettings;
        try
        {
            var (project, media, card) = await Task.Run(async () =>
            {
                var project = ProjectSerialization.Deserialize(await File.ReadAllTextAsync(row.Path, ct));
                var media = await App.Services.Projects.ResolveMediaAsync(project.Media.Source, row.Path, ct);
                return (project, media, Card(project, wordsVisible, defaultStyle));
            }, ct);
            row.Load(project, media is null, DateTimeOffset.Now, card);
            var source = project.Media.Source;
            if (media is null || source.Video is null) { row.FramePath = null; return; }
            try { row.FramePath = await App.Services.Thumbnails.GetAsync(source.ContentKey, media, Thumbnails.Candidates(project, null), source.Video.RotationDegrees, ct); }
            catch (VoxClipException exception)
            {
                // The video is there but the decoder can't read it: the card with the warning chip, and Open (design §5.4.4 f).
                row.Unreadable = true;
                App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "home", $"action=Poster frame code={exception.WireCode}");
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // Not the video's fault: the card stands in.
                App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "home", $"action=Poster frame code={exception.GetType().Name}");
            }
        }
        catch (OperationCanceledException) { loadedAt.Remove(row.Path); }
        catch (Exception exception)
        {
            // An unreadable project keeps its tile so the user can show it in Explorer or remove it. It isn't read again
            // until the project file changes.
            if (!row.IsLoaded) row.Fail();
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "home", $"action=Recent project code={(exception is VoxClipException known ? known.WireCode : exception.GetType().Name)}");
        }
    }
    private static async Task StallAsync(RecentProject row, CancellationToken ct)
    {
        try { await Task.Delay(300, ct); }
        catch (OperationCanceledException) { return; }
        if (!row.IsLoaded) row.IsStalled = true;
    }
    /// <summary>The take's caption card; null, and stage black, when the caption resources can't be read.</summary>
    private static CaptionCard? Card(Project project, bool wordsVisible, string defaultStyle)
    {
        try { return App.Services.Cards?.Card(project, null, wordsVisible, defaultStyle); }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "home", $"action=Caption card code={exception.GetType().Name}");
            return null;
        }
    }
    /// <summary>The AI callout (delta §7): shown only when it gives a next step, hidden when the connector is ready. One
    /// check runs at a time: a newer one cancels it, hiding Home cancels it, and only the newest result is shown.</summary>
    private async Task RefreshAiAsync(bool detect = false)
    {
        aiCheck?.Cancel();
        using var check = CancellationTokenSource.CreateLinkedTokenSource(loads.Token);
        aiCheck = check;
        var selected = App.Services.Get("llm.connector", "");
        aiSettings = ConnectorSettings(selected);
        aiStale = false;
        aiCheckedAt = DateTime.UtcNow;
        try
        {
            var next = await CheckAiAsync(selected, detect, check.Token);
            if (aiCheck != check) return;
            callout = next;
            AiBar.IsOpen = next is not null;
            if (next is null) return;
            AiBar.Title = next.Title;
            AiBar.Message = next.Message;
            AiAction.Content = next.Action;
        }
        catch (OperationCanceledException) { if (aiCheck == check) aiStale = true; }
        finally { if (aiCheck == check) aiCheck = null; }
    }
    private static string ConnectorSettings(string selected) =>
        HomeViewModel.ConnectorSettings(selected, key => App.Services.Settings.Values.TryGetValue(key, out var value) ? value.GetRawText() : null);
    private static async Task<AiCallout?> CheckAiAsync(string selected, bool detect, CancellationToken ct)
    {
        try
        {
            var entry = selected.Length == 0 ? null : (await ProviderCatalog.ReadAsync(ct)).FirstOrDefault(item => item.WireId == selected);
            ConnectorStatus? status = null;
            if (entry is not null)
            {
                try { status = detect ? await ProviderCatalog.ProbeAsync(entry, App.Services.Connector(entry.Id), ct) : ProviderCatalog.LastStatus(entry); }
                catch (Exception exception) when (exception is not OperationCanceledException) { status = new ConnectorStatus.Unavailable(exception.GetType().Name); }
            }
            return HomeViewModel.Callout(entry?.ShortName, entry?.Group, status);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            App.Services.Log.Write(Core.Services.Logging.LogLevel.Warn, "home", $"action=AI callout code={exception.GetType().Name}");
            return null;
        }
    }
    private async void AiActionClicked(object sender, RoutedEventArgs args)
    {
        if (callout?.Action == "Check again") await RefreshAiAsync(true);
        else App.OpenSettings("Providers & Keys");
    }
    private void GridSizeChanged(object sender, SizeChangedEventArgs args)
    {
        // Adaptive cards (delta §7): 200–280 wide with a 16 gap, 16:9 thumbnails; four 226 × 127 cards at 1280.
        if (RecentGrid.ItemsPanelRoot is not ItemsWrapGrid panel) return;
        var available = args.NewSize.Width - RecentGrid.Padding.Left - RecentGrid.Padding.Right;
        var columns = Math.Max(1, (int)Math.Floor(available / 216));
        var card = Math.Floor(available / columns) - 16;
        panel.ItemWidth = card + 16;
        panel.ItemHeight = Math.Round(card * 9 / 16) + 64 + 16;
    }
    private void SearchChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) ViewModel.Query = sender.Text;
    }
    private void SortLastOpened(object sender, RoutedEventArgs args) => ViewModel.Sort = RecentSort.LastOpened;
    private void SortName(object sender, RoutedEventArgs args) => ViewModel.Sort = RecentSort.Name;
    private void ShowRecentInExplorer(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string path }) ShareHelpers.Reveal(path);
    }
    private async void RemoveRecent(object sender, RoutedEventArgs args)
    {
        if (sender is not FrameworkElement { Tag: string path } || window is null) return;
        try
        {
            var next = App.Services.Get<string[]>("general.recentProjects", []).Where(item => !item.Equals(path, StringComparison.OrdinalIgnoreCase)).ToArray();
            await App.Services.SetAsync("general.recentProjects", next);
            if (ViewModel.RecentProjects.FirstOrDefault(item => item.Path.Equals(path, StringComparison.OrdinalIgnoreCase)) is { } row) ViewModel.RecentProjects.Remove(row);
        }
        catch (Exception exception) { window.ShowError(exception, "Recent projects"); }
    }
    private async void OpenRecent(object sender, RoutedEventArgs args)
    {
        if (window is not null && sender is FrameworkElement { Tag: string path }) await window.OpenPathAsync(path, ShellPath.HomeTileOpen);
    }
    /// <summary>Locate opens the project through its save-before-leaving boundary, then offers the editor's video picker.</summary>
    private async void OpenMissingClicked(object sender, RoutedEventArgs args)
    {
        if (window is not null && sender is FrameworkElement { Tag: string path }) await window.LocateProjectAsync(path);
    }
    private void CancelTranscriptionClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string path }) TranscriptionActivity.Cancel(path);
    }
    private async void ImportClicked(object sender, RoutedEventArgs args) { if (window is not null) await window.ChooseAsync(false); }
    private async void OpenClicked(object sender, RoutedEventArgs args) { if (window is not null) await window.ChooseAsync(true); }
    private async void RecentClicked(object sender, ItemClickEventArgs args)
    {
        if (window is not null && args.ClickedItem is RecentProject project) await window.OpenPathAsync(project.Path, ShellPath.HomeTile);
    }
}
