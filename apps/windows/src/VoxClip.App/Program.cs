using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;
namespace VoxClip.App;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        VelopackApp.Build().Run();
        using var instance = new Mutex(true, @"Local\VoxConvo.VoxClip.Singleton", out var firstInstance);
        if (!firstInstance) return;
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(initialization =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
    }
}
