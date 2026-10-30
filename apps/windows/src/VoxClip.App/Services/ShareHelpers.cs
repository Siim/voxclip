using System.Diagnostics;
using VoxClip.App.ViewModels;
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
    /// <summary>Copies the caption and reveals the file at once. The X text is cut on the thread pool, keeping
    /// <paramref name="disclosureLine"/> last (voice-lab §11.3), and the await resumes on the UI thread's dispatcher, which launches
    /// the composer.</summary>
    internal static async Task OpenComposerAsync(string destination, string caption, string path, string? disclosureLine)
    {
        var address = destination switch
        {
            "x" => "https://x.com/intent/post?text=",
            "linkedin" => "https://www.linkedin.com/feed/?shareActive=true&text=",
            _ => throw new ArgumentException("Unsupported share destination.", nameof(destination))
        };
        Copy(caption); Reveal(path);
        var text = destination == "x" ? await Task.Run(() => ShareDisclosurePresentation.ComposerText(destination, caption, disclosureLine)) : caption;
        var uri = new Uri(address + Uri.EscapeDataString(text));
        if (uri.Scheme != "https" || uri.Host is not ("x.com" or "www.linkedin.com")) throw new InvalidOperationException("Invalid composer address.");
        if (!await Windows.System.Launcher.LaunchUriAsync(uri)) throw new InvalidOperationException("Browser could not open.");
    }
}
