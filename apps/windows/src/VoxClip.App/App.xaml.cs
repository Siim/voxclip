using Microsoft.UI.Xaml;
namespace VoxClip.App;

/// <summary>WinUI application lifecycle; architecture §7.2. No native model/media work runs during startup.</summary>
public partial class App : Application
{
    private Window? window;
    /// <summary>Initialize theme-aware WinUI resources.</summary>
    public App() => InitializeComponent();
    /// <inheritdoc />
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
    }
}
