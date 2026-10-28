using VoxClip.App.ViewModels;
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
#if DEBUG
        var captureAppearance = Program.Arguments.FirstOrDefault(argument => argument.StartsWith("--capture-appearance=", StringComparison.Ordinal))?.Split('=')[1];
        if (captureAppearance is "light" or "dark") await Services.SetAsync("general.appearance", captureAppearance);
#endif
        window = NewWindow();
        termsHost?.Close();
        termsHost = null;
        var frameProbeIndex = Array.IndexOf(Program.Arguments, "--transcript-frame-probe");
        if (frameProbeIndex >= 0 && frameProbeIndex + 1 < Program.Arguments.Length)
        {
            await TranscriptFrameProbe.RunAsync(window, Program.Arguments[frameProbeIndex + 1]);
            Exit();
            return;
        }
        if (Program.Instance is { } instance)
            instance.Activated += (_, activation) => window.DispatcherQueue.TryEnqueue(async () =>
            {
                var target = Windows.FirstOrDefault() ?? NewWindow();
                target.Activate();
                if (activation.Data is IFileActivatedEventArgs files && files.Files.FirstOrDefault() is { } file) await target.OpenPathAsync(file.Path, ShellPath.FileActivation);
                else if (activation.Data is ILaunchActivatedEventArgs launch && !string.IsNullOrWhiteSpace(launch.Arguments))
                {
                    var path = RedirectedLaunchPath(launch.Arguments);
                    if (path is not null) await target.OpenPathAsync(path, ShellPath.FileActivation);
                }
            });
#if DEBUG
            var routeProbeIndex = Array.IndexOf(Program.Arguments, "--shell-route-probe");
            if (routeProbeIndex >= 0 && routeProbeIndex + 1 < Program.Arguments.Length)
            {
                await ShellRouteProbe.RunAsync(window, Program.Arguments[routeProbeIndex + 1]);
                Exit();
                return;
            }
            var restartProbeIndex = Array.IndexOf(Program.Arguments, "--restart-probe");
            if (restartProbeIndex >= 0 && restartProbeIndex + 1 < Program.Arguments.Length)
            {
                await RestartNativeProbe.RunAsync(window, Program.Arguments[restartProbeIndex + 1]);
                Exit();
                return;
            }
            var shellProbeIndex = Array.IndexOf(Program.Arguments, "--shell-probe");
            if (shellProbeIndex >= 0 && shellProbeIndex + 1 < Program.Arguments.Length)
            {
                await ShellNativeProbe.RunAsync(window, Program.Arguments[shellProbeIndex + 1]);
                Exit();
                return;
            }
            var demoIndex = Array.IndexOf(Program.Arguments, "--demo-project");
            if (demoIndex >= 0 && demoIndex + 1 < Program.Arguments.Length)
            {
                await window.OpenPathAsync(Program.Arguments[demoIndex + 1], ShellPath.Launch, true);
                if (Program.Arguments.Contains("--capture-fixture") && window.DebugEditor?.ViewModel is { } captureModel && captureModel.Words.Count >= 6)
                {
                    if (captureModel.KeptClips.Count == 0) { captureModel.Select(0); captureModel.Select(2, true); captureModel.MakeClip(); }
                    if (captureModel.KeptClips.Count == 1) { captureModel.Select(captureModel.Words.Count - 3); captureModel.Select(captureModel.Words.Count - 1, true); captureModel.MakeClip(); }
                    captureModel.Apply(new VoxClip.Core.Domain.Editing.EditOperation.SetActiveClip(null));
                }
                screen = "editor";
                var screenIndex = Array.IndexOf(Program.Arguments, "--demo-screen");
                if (screenIndex >= 0 && screenIndex + 1 < Program.Arguments.Length)
                {
                    if (Program.Arguments[screenIndex + 1] == "home") { window.ShowHome(ShellPath.SidebarHome); screen = "home"; }
                    else if (Program.Arguments[screenIndex + 1] == "settings") { OpenSettings(); screen = "settings"; }
                }
                return;
            }
#endif
            var path = Program.Arguments.Where((argument, index) => !argument.StartsWith('-') && (index == 0 || Program.Arguments[index - 1] != "--self-check")).FirstOrDefault();
            if (path is not null) await window.OpenPathAsync(path, ShellPath.Launch);
            else if (Services.Get("general.openLastProject", false) && Services.Get<string[]>("general.recentProjects", []).FirstOrDefault() is { } recent) await window.OpenPathAsync(recent, ShellPath.Launch);
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
    /// <summary>Open Settings at one section, named by its tag; Find clips' Change… and Set up AI… open the connector section.</summary>
    internal static void OpenSettings(string section)
    {
        OpenSettings();
        Settings?.ShowSection(section);
    }
}
