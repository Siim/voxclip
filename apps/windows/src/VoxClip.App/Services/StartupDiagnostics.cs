using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using VoxClip.Core.Services.Logging;

namespace VoxClip.App.Services;

internal static class StartupDiagnostics
{
    internal static ILog Log { get; } = new Log();
    private static string? reportPath;
    private static string screen = "home";
    private static bool failed;
    private static bool rootLoaded;

    internal static void Initialize(string[] arguments)
    {
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Failure(args.ExceptionObject as Exception ?? new InvalidOperationException("Unhandled runtime failure"), "runtime");
        TaskScheduler.UnobservedTaskException += (_, args) => Failure(args.Exception, "background");
        var index = Array.IndexOf(arguments, "--self-check");
        if (index < 0) return;
        reportPath = index + 1 < arguments.Length && !arguments[index + 1].StartsWith('-')
            ? Path.GetFullPath(arguments[index + 1])
            : Path.Combine(Core.Services.Project.DataLocations.Resolve().Logs, "startup-self-check.json");
        Directory.CreateDirectory(Path.GetDirectoryName(reportPath)!);
        Write(new("starting", screen, false, false, 0, 0));
    }

    internal static void Failure(Exception exception, string stage)
    {
        failed = true;
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            var detail = current is Microsoft.UI.Xaml.Markup.XamlParseException or System.Resources.MissingManifestResourceException
                ? current.Message : "";
            Log.Write(LogLevel.Error, "startup", $"stage={stage} type={current.GetType().FullName} hresult=0x{current.HResult:X8} {detail}");
        }
        Write(new("failed", screen, rootLoaded, false, 0, 0));
        try { Log.FlushAsync(CancellationToken.None).Wait(TimeSpan.FromSeconds(2)); }
        catch (Exception) { }
    }

    internal static async Task ProbeAsync(Window window, string expectedScreen)
    {
        if (reportPath is null) return;
        screen = expectedScreen;
        try
        {
            if (window.Content is not FrameworkElement root) throw new InvalidOperationException("XAML root is missing");
            if (window is MainWindow main && main.CurrentScreen != screen) throw new InvalidOperationException("Requested screen did not load");
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            void Rendered(object? sender, object args)
            {
                if (root.IsLoaded && root.XamlRoot is not null && root.ActualWidth > 0 && root.ActualHeight > 0) ready.TrySetResult();
            }
            CompositionTarget.Rendering += Rendered;
            try { await ready.Task.WaitAsync(TimeSpan.FromSeconds(20)); }
            finally { CompositionTarget.Rendering -= Rendered; }
            rootLoaded = true;
            var bitmap = new RenderTargetBitmap();
            await bitmap.RenderAsync(root, 640, 400).AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            var pixels = await bitmap.GetPixelsAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
            var rendered = StartupCheck.HasContent(pixels.ToArray());
            if (!rendered) throw new InvalidOperationException("XAML root rendered an empty or uniform image");
            if (failed) return;
            Write(new("ready", screen, true, true, bitmap.PixelWidth, bitmap.PixelHeight)
            {
                WindowHandle = WinRT.Interop.WindowNative.GetWindowHandle(window).ToInt64(),
                RasterizationScale = root.XamlRoot.RasterizationScale
            });
            Log.Write(LogLevel.Info, "startup", $"self-check ready screen={screen} rootLoaded=true rendered=true");
        }
        catch (Exception exception) { Failure(exception, "self-check"); }
    }

    private static void Write(StartupCheck check)
    {
        if (reportPath is null) return;
        try { check.Save(reportPath); }
        catch (Exception exception) { Log.Write(LogLevel.Error, "startup", $"self-check report unavailable type={exception.GetType().Name}"); }
    }
}
