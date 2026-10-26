using Microsoft.UI.Xaml;
using VoxClip.App.Services;
using VoxClip.App.Controls;
using VoxClip.Core.Services.Project;
using Windows.ApplicationModel.Activation;
using System.Runtime.InteropServices;
namespace VoxClip.App;

/// <summary>WinUI application lifecycle; architecture §7.2. No native model/media work runs during startup.</summary>
public partial class App : Application
{
    private static AppServices? services;
    internal static AppServices Services => services ??= new();
    internal static List<MainWindow> Windows { get; } = [];
    internal static UpdateRestartCoordinator Restart { get; } = new(() => Windows.Cast<IUpdateRestartWindow>().ToArray());
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
        Window? termsHost = null;
        var screen = "home";
        try
        {
        var decision = await WindowsRuntimeTermsDialog.ShowAsync(WindowsRuntimeAgreement.ForCurrentUser());
        termsHost = decision.Host;
        if (!decision.Accepted) { termsHost?.Close(); termsHost = null; Exit(); return; }
        await Services.InitializeAsync(CancellationToken.None);
        window = NewWindow();
        termsHost?.Close();
        termsHost = null;
        if (Program.Instance is { } instance)
            instance.Activated += (_, activation) => window.DispatcherQueue.TryEnqueue(async () =>
            {
                var target = Windows.FirstOrDefault() ?? NewWindow();
                target.Activate();
                if (activation.Data is IFileActivatedEventArgs files && files.Files.FirstOrDefault() is { } file) await target.OpenPathAsync(file.Path);
                else if (activation.Data is ILaunchActivatedEventArgs launch && !string.IsNullOrWhiteSpace(launch.Arguments))
                {
                    var path = RedirectedLaunchPath(launch.Arguments);
                    if (path is not null) await target.OpenPathAsync(path);
                }
            });
#if DEBUG
            var restartProbeIndex = Array.IndexOf(Program.Arguments, "--restart-probe");
            if (restartProbeIndex >= 0 && restartProbeIndex + 1 < Program.Arguments.Length)
            {
                await RestartNativeProbe.RunAsync(window, Program.Arguments[restartProbeIndex + 1]);
                Exit();
                return;
            }
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
            termsHost?.Close();
            StartupDiagnostics.Failure(exception, "launch");
            if (window is null) { Environment.ExitCode = 1; Exit(); }
            else window.ShowError(exception, "Open project");
        }
        finally
        {
            if (window is not null) await StartupDiagnostics.ProbeAsync(screen == "settings" && Settings is not null ? Settings : window, screen);
        }
    }

    private static string? RedirectedLaunchPath(string commandLine)
    {
        var arguments = CommandLineToArgvW(commandLine, out var count);
        if (arguments == IntPtr.Zero) return null;
        try
        {
            var values = Enumerable.Range(0, count).Select(index => Marshal.PtrToStringUni(Marshal.ReadIntPtr(arguments, index * IntPtr.Size)) ?? "").ToArray();
            return RedirectedLaunchSelection.FilePath(values, Environment.ProcessPath);
        }
        finally { LocalFree(arguments); }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    internal static MainWindow NewWindow()
    {
        if (Restart.IsPreparing) return Windows[0];
        var window = new MainWindow();
        Windows.Add(window);
        window.Activate();
        return window;
    }

    internal static void OpenSettings()
    {
        if (Restart.IsPreparing) return;
        if (Settings is null)
        {
            Settings = new();
            Settings.Closed += (_, _) => Settings = null;
        }
        Settings.Activate();
    }
}
