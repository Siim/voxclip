using Microsoft.UI.Xaml;
using VoxClip.App.Services;
using Windows.ApplicationModel.Activation;
namespace VoxClip.App;

/// <summary>WinUI application lifecycle; architecture §7.2. No native model/media work runs during startup.</summary>
public partial class App : Application
{
    internal static AppServices Services { get; } = new();
    internal static List<MainWindow> Windows { get; } = [];
    internal static SettingsWindow? Settings { get; private set; }
    /// <summary>Initialize theme-aware WinUI resources.</summary>
    public App()
    {
        UnhandledException += (_, args) => StartupDiagnostics.Failure(args.Exception, "xaml");
        InitializeComponent();
    }
    /// <inheritdoc />
    protected override async void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        MainWindow? window = null;
        var screen = "home";
        try
        {
        await Services.InitializeAsync(CancellationToken.None);
        window = NewWindow();
        if (Program.Instance is { } instance)
            instance.Activated += (_, activation) => window.DispatcherQueue.TryEnqueue(async () =>
            {
                var target = Windows.FirstOrDefault() ?? NewWindow();
                target.Activate();
                if (activation.Data is IFileActivatedEventArgs files && files.Files.FirstOrDefault() is { } file) await target.OpenPathAsync(file.Path);
                else if (activation.Data is ILaunchActivatedEventArgs launch && !string.IsNullOrWhiteSpace(launch.Arguments)) await target.OpenPathAsync(launch.Arguments.Trim('"'));
            });
#if DEBUG
            var demoIndex = Array.IndexOf(Program.Arguments, "--demo-project");
            if (demoIndex >= 0 && demoIndex + 1 < Program.Arguments.Length)
            {
                await window.OpenPathAsync(Program.Arguments[demoIndex + 1], true);
                screen = "editor";
                var screenIndex = Array.IndexOf(Program.Arguments, "--demo-screen");
                if (screenIndex >= 0 && screenIndex + 1 < Program.Arguments.Length)
                {
                    if (Program.Arguments[screenIndex + 1] == "home") { await window.GoHomeAsync(); screen = "home"; }
                    else if (Program.Arguments[screenIndex + 1] == "settings") { OpenSettings(); screen = "settings"; }
                }
                return;
            }
#endif
            var path = Program.Arguments.Where((argument, index) => !argument.StartsWith('-') && (index == 0 || Program.Arguments[index - 1] != "--self-check")).FirstOrDefault();
            if (path is not null) await window.OpenPathAsync(path);
            else if (Services.Get("general.openLastProject", false) && Services.Get<string[]>("general.recentProjects", []).FirstOrDefault() is { } recent) await window.OpenPathAsync(recent);
            else if (!Program.Arguments.Contains("--self-check") && !Services.Get("onboarding.completed", false)) await window.ShowOnboardingAsync();
            screen = window.CurrentScreen;
        }
        catch (Exception exception)
        {
            StartupDiagnostics.Failure(exception, "launch");
            if (window is null) { Environment.ExitCode = 1; Exit(); }
            else window.ShowError(exception, "Open project");
        }
        finally
        {
            if (window is not null) await StartupDiagnostics.ProbeAsync(screen == "settings" && Settings is not null ? Settings : window, screen);
        }
    }

    internal static MainWindow NewWindow()
    {
        var window = new MainWindow();
        Windows.Add(window);
        window.Activate();
        return window;
    }

    internal static void OpenSettings()
    {
        if (Settings is null)
        {
            Settings = new();
            Settings.Closed += (_, _) => Settings = null;
        }
        Settings.Activate();
    }
}
