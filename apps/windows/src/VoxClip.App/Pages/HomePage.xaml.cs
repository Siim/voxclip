using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
namespace VoxClip.App.Pages;

/// <summary>Home and recent projects shell; design Home layout, owned by win-ui.</summary>
public sealed partial class HomePage : Page
{
    private SettingsWindow? settings;
    /// <summary>UI-thread view model.</summary>
    public HomeViewModel ViewModel { get; } = new();
    /// <summary>Construct empty Home controls without calling unfinished services.</summary>
    public HomePage() => InitializeComponent();
    private void ImportClicked(object sender, RoutedEventArgs args) => Frame.Navigate(typeof(EditorPage));
    private void OpenClicked(object sender, RoutedEventArgs args) => Frame.Navigate(typeof(EditorPage));
    private void SettingsClicked(object sender, RoutedEventArgs args)
    {
        settings ??= new SettingsWindow();
        settings.Closed += (_, _) => settings = null;
        settings.Activate();
    }
}
