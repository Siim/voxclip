#if DEBUG
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using VoxClip.App.Controls;
using VoxClip.App.Pages;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Services;

internal static class ShellRouteProbe
{
    internal static async Task RunAsync(MainWindow window, string output)
    {
        Directory.CreateDirectory(output);
        var observations = new List<object>();
        var report = Path.Combine(output, "routes.json");
        var status = "failed";
        string? failure = null;
        try
        {
            var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR") ?? throw new InvalidOperationException("Set VOXCLIP_SHARED_DIR.");
            var fixture = Path.Combine(shared, "fixtures", "projects", "interview-take.voxclip");
            var first = Path.Combine(output, "first.voxclip");
            var recentPath = Path.Combine(output, "recent.voxclip");
            var dropped = Path.Combine(output, "drop.voxclip");
            foreach (var path in new[] { first, recentPath, dropped }) File.Copy(fixture, path, false);
            Require(window.CurrentScreen == "home" && window.DebugEditor is null, "Each route iteration must start in a fresh process on Home.");
            await window.OpenPathAsync(first, ShellPath.Launch);
            await ObserveAsync("first-open", first, null);
            var prior = window.DebugEditor!;
            await App.Services.RememberAsync(recentPath, CancellationToken.None);
            window.DebugSelect(window.Shell.Home);
            var recent = window.Shell.Rows.Single(row => row.Kind == SidebarKind.Recent && row.Recent!.Path == recentPath);
            await window.DebugInvokeAsync(recent);
            await ObserveAsync("recent", recentPath, prior);
            prior = window.DebugEditor!;
            await window.OpenDroppedAsync(dropped);
            await ObserveAsync("drop", dropped, prior);
            prior = window.DebugEditor!;
            prior.ViewModel.SetMediaUnavailable(false);
            var captionOutput = Path.Combine(output, "caption-file-replacement");
            Directory.CreateDirectory(captionOutput);
            var checks = new List<string>();
            await prior.DebugCaptionGateAsync(window, captionOutput, checks);
            Require(checks.Any(check => check.StartsWith("actual project-file replacement", StringComparison.Ordinal)), "Caption-file replacement did not execute.");
            await ObserveAsync("caption-file-replacement", dropped, prior);
            status = "passed";

            async Task ObserveAsync(string route, string path, EditorPage? previous)
            {
                var editor = window.DebugEditor;
                Require(editor is not null && window.CurrentScreen == "editor" && window.ProjectPath == path,
                    route + " did not open its target: " + window.DebugOpenError);
                if (previous is not null) Require(!ReferenceEquals(previous, editor), route + " kept the old editor.");
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (!editor!.IsLoaded || editor.ActualWidth <= 0 || editor.ActualHeight <= 0)
                {
                    Require(DateTime.UtcNow < deadline, route + " never loaded.");
                    await Task.Delay(25);
                }
                var transcript = Descendants(editor).OfType<TranscriptView>().Single();
                var peer = FrameworkElementAutomationPeer.CreatePeerForElement(transcript);
                Require(peer is not null && !peer.IsOffscreen(), route + " has no visible transcript peer.");
                var bitmap = new RenderTargetBitmap();
                await bitmap.RenderAsync(window.Content);
                var pixels = (await bitmap.GetPixelsAsync()).ToArray();
                Require(StartupCheck.HasContent(pixels), route + " did not render content.");
                using var stream = File.Create(Path.Combine(output, route + ".png"));
                var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
                encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                    (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
                await encoder.FlushAsync();
                observations.Add(new { Route = route, Status = "passed", Path = path, RootLoaded = editor.IsLoaded,
                    Rendered = true, TranscriptVisible = true, ProcessId = Environment.ProcessId, At = DateTimeOffset.Now });
            }
        }
        catch (Exception exception) { failure = exception.ToString(); throw; }
        finally
        {
            await File.WriteAllTextAsync(report + ".tmp", JsonSerializer.Serialize(new { Status = status, Failure = failure,
                Architecture = RuntimeInformation.ProcessArchitecture.ToString(), SourceSha = typeof(ShellRouteProbe).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
                    .Cast<System.Reflection.AssemblyInformationalVersionAttribute>().Single().InformationalVersion.Split('+').ElementAtOrDefault(1),
                Routes = observations }, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(report + ".tmp", report, false);
        }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
#endif
