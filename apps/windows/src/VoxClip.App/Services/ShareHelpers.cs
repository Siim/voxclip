using System.Diagnostics;
using Windows.ApplicationModel.DataTransfer;

namespace VoxClip.App.Services;

internal static class ShareHelpers
{
    internal static void Reveal(string path)
    {
        var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = true };
        start.ArgumentList.Add("/select," + Path.GetFullPath(path));
        using var process = Process.Start(start);
    }
    internal static void Copy(string caption)
    {
        var data = new DataPackage(); data.SetText(caption); Clipboard.SetContent(data); Clipboard.Flush();
    }
    internal static async Task OpenComposerAsync(string destination, string caption, string path)
    {
        Copy(caption); Reveal(path);
        var uri = destination switch
        {
            "x" => new Uri("https://x.com/intent/post?text=" + Uri.EscapeDataString(caption)),
            "linkedin" => new Uri("https://www.linkedin.com/feed/?shareActive=true&text=" + Uri.EscapeDataString(caption)),
            _ => throw new ArgumentException("Unsupported share destination.", nameof(destination))
        };
        if (uri.Scheme != "https" || uri.Host is not ("x.com" or "www.linkedin.com")) throw new InvalidOperationException("Invalid composer address.");
        if (!await Windows.System.Launcher.LaunchUriAsync(uri)) throw new InvalidOperationException("Browser could not open.");
    }
}
