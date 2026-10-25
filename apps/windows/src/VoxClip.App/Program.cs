using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;
using Microsoft.Windows.AppLifecycle;
using System.Runtime.InteropServices;
using VoxClip.App.Services;
namespace VoxClip.App;

internal static class Program
{
    internal static string[] Arguments { get; private set; } = [];
    internal static AppInstance? Instance { get; private set; }
    [STAThread]
    private static void Main(string[] args)
    {
        Arguments = args;
        try { StartupDiagnostics.Initialize(args); Start(); }
        catch (Exception exception)
        {
            StartupDiagnostics.Failure(exception, "process");
            Environment.ExitCode = 1;
        }
    }
    private static void Start()
    {
        VelopackApp.Build().Run();
        XamlCheckProcessRequirements();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Instance = AppInstance.FindOrRegisterForKey("VoxClip");
        if (!Instance.IsCurrent)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            Task.Run(async () => await Instance.RedirectActivationToAsync(activation)).GetAwaiter().GetResult();
            return;
        }
        Application.Start(initialization =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
    }
    [DllImport("Microsoft.ui.xaml.dll")]
    private static extern void XamlCheckProcessRequirements();
}
