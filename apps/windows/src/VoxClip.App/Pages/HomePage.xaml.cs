using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using Windows.Storage;
using Windows.Storage.FileProperties;
namespace VoxClip.App.Pages;

/// <summary>Home and recent projects shell; design Home layout, owned by win-ui.</summary>
public sealed partial class HomePage : Page
{
    private MainWindow? window;
    /// <summary>UI-thread view model.</summary>
    public HomeViewModel ViewModel { get; } = new();
    /// <summary>Construct empty Home controls without calling unfinished services.</summary>
    public HomePage() => InitializeComponent();
    internal void Attach(MainWindow owner)
    {
        window = owner;
        Refresh();
        if (App.Services.StartupNotice.Length > 0) ViewModel.Notice = App.Services.StartupNotice;
        else _ = RefreshModelStatusAsync();
    }
    /// <summary>Home is cached per window (ADR-R29), so it re-reads the recent list each time it is shown.</summary>
    internal void Refresh()
    {
        var paths = App.Services.Get<string[]>("general.recentProjects", []);
        foreach (var stale in ViewModel.RecentProjects.Where(row => !paths.Contains(row.Path, StringComparer.OrdinalIgnoreCase)).ToArray())
            ViewModel.RecentProjects.Remove(stale);
        for (var index = 0; index < paths.Length; index++)
        {
            var row = ViewModel.RecentProjects.FirstOrDefault(item => item.Path.Equals(paths[index], StringComparison.OrdinalIgnoreCase));
            if (row is null)
            {
                row = new RecentProject(paths[index], System.IO.Path.GetFileNameWithoutExtension(paths[index]));
                ViewModel.RecentProjects.Insert(index, row);
                _ = LoadRecentAsync(row);
            }
            else if (ViewModel.RecentProjects.IndexOf(row) is var current && current != index) ViewModel.RecentProjects.Move(current, index);
        }
        EmptyRecent.Visibility = ViewModel.RecentProjects.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
    }
    private async Task LoadRecentAsync(RecentProject row)
    {
        try
        {
            var project = ProjectSerialization.Deserialize(await System.IO.File.ReadAllTextAsync(row.Path));
            var age = DateTimeOffset.Now.Date - project.ModifiedAt.LocalDateTime.Date;
            var when = age.TotalDays switch { 0 => "today", 1 => "yesterday", <= 6 and >= 2 => project.ModifiedAt.ToLocalTime().ToString("dddd"), _ => project.ModifiedAt.ToLocalTime().ToString("d") };
            row.Detail = $"{EditorViewModel.Duration(project.Media.Source.DurationSeconds)} · {when}";
            if (!System.IO.File.Exists(project.Media.Source.AbsolutePath)) return;
            try
            {
                var video = await StorageFile.GetFileFromPathAsync(project.Media.Source.AbsolutePath);
                using var thumbnail = await video.GetThumbnailAsync(ThumbnailMode.VideosView, 160, ThumbnailOptions.UseCurrentScale);
                if (thumbnail is null || thumbnail.Size == 0) return;
                var image = new BitmapImage();
                await image.SetSourceAsync(thumbnail);
                row.Thumbnail = image;
            }
            catch (Exception) { /* Recent metadata stays available when Windows cannot make a thumbnail. */ }
        }
        catch (Exception) { row.Detail = "Project unavailable · Show in Explorer or remove from list"; }
    }
    private async Task RefreshModelStatusAsync()
    {
        try
        {
            if (App.Services.Get("transcription.engineMode", "local") == "elevenlabs") { ViewModel.Notice = "Transcribes with ElevenLabs"; return; }
            var installed = await App.Services.Downloads.ListInstalledAsync(CancellationToken.None);
            var ready = installed.FirstOrDefault(item => item.Verified);
            if (ready is not null)
            {
                var model = await App.Services.Models.GetModelAsync(ready.Id, CancellationToken.None);
                var language = model?.Languages.FirstOrDefault(code => code != "*") ?? "multilingual";
                ViewModel.Notice = $"Transcribes on this PC · {language} model ✓";
            }
            else
            {
                var models = await App.Services.Models.GetModelsAsync(CancellationToken.None);
                var recommended = models.FirstOrDefault(model => model.Id.StartsWith("whisper-large-v3-turbo-", StringComparison.Ordinal));
                ViewModel.Notice = recommended is null ? "No model yet · Download in Settings" : $"No model yet · Download ({recommended.TotalBytes / 1_000_000d:0} MB)";
            }
        }
        catch (Exception exception) { ViewModel.Notice = ViewModels.UiError.Message(exception, "Local models"); }
    }
    private void ShowRecentInExplorer(object sender, RoutedEventArgs args)
    {
        if (sender is MenuFlyoutItem { Tag: string path }) ShareHelpers.Reveal(path);
    }
    private async void RemoveRecent(object sender, RoutedEventArgs args)
    {
        if (sender is not MenuFlyoutItem { Tag: string path }) return;
        await Controls.Ui.RunAsync(RecentNotice, async () =>
        {
            var next = App.Services.Get<string[]>("general.recentProjects", []).Where(item => !item.Equals(path, StringComparison.OrdinalIgnoreCase)).ToArray();
            await App.Services.SetAsync("general.recentProjects", next);
            if (ViewModel.RecentProjects.FirstOrDefault(item => item.Path.Equals(path, StringComparison.OrdinalIgnoreCase)) is { } row) ViewModel.RecentProjects.Remove(row);
            EmptyRecent.Visibility = ViewModel.RecentProjects.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }, "Recent projects");
    }
    private async void ImportClicked(object sender, RoutedEventArgs args) { if (window is not null) await window.ChooseAsync(false); }
    private async void OpenClicked(object sender, RoutedEventArgs args) { if (window is not null) await window.ChooseAsync(true); }
    private void SettingsClicked(object sender, RoutedEventArgs args) => App.OpenSettings();
    private async void RecentClicked(object sender, ItemClickEventArgs args)
    {
        if (window is not null && args.ClickedItem is RecentProject project) await window.OpenPathAsync(project.Path);
    }
}
