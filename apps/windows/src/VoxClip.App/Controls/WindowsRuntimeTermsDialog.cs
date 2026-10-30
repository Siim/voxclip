using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.Core.Services.Project;

namespace VoxClip.App.Controls;

/// <summary>First-launch decision before normal app services or a project window exist.</summary>
internal static class WindowsRuntimeTermsDialog
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

    internal static async Task<(bool Accepted, Window? Host)> ShowAsync(WindowsRuntimeAgreement agreement)
    {
        // Check the receipt before creating a temporary window. This also avoids a
        // blank flash on every subsequent launch with unchanged terms.
        WindowsRuntimeTerms terms;
        InvalidDataException? loadError = null;
        try { terms = agreement.LoadTerms(); }
        catch (InvalidDataException error) { terms = null!; loadError = error; }
        if (loadError is null && agreement.IsAccepted(terms)) return (true, null);

        var host = new Window { Title = "VoxClip · Windows component terms" };
        var root = new Grid();
        host.Content = root;
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(host);
        var scale = GetDpiForWindow(hwnd) / 96.0;
        var workArea = DisplayArea.GetFromWindowId(host.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        host.AppWindow.Resize(new Windows.Graphics.SizeInt32(
            Math.Min((int)Math.Round(780 * scale), workArea.Width - 32),
            Math.Min((int)Math.Round(720 * scale), workArea.Height - 32)));

        var loaded = new TaskCompletionSource<XamlRoot?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        ContentDialog? activeDialog = null;
        host.Closed += (_, _) =>
        {
            loaded.TrySetResult(null);
            closed.TrySetResult();
            try { activeDialog?.Hide(); }
            catch (Exception) { } // The host is already closed; the pending task completes through closed.
        };
        root.Loaded += (_, _) => loaded.TrySetResult(root.XamlRoot);
        host.Activate();
        var xamlRoot = await loaded.Task;
        if (xamlRoot is null || closed.Task.IsCompleted) return (false, null);

        async Task<ContentDialogResult> ShowUntilClosedAsync(ContentDialog dialog)
        {
            activeDialog = dialog;
            if (closed.Task.IsCompleted) return ContentDialogResult.None;
            var showTask = ShowDialogAsync(dialog);
            if (await Task.WhenAny(showTask, closed.Task) != showTask)
            {
                // The host can close while the WinUI dialog is still completing.
                _ = showTask.ContinueWith(task => _ = task.Exception, TaskContinuationOptions.OnlyOnFaulted);
                return ContentDialogResult.None;
            }
            try { return await showTask; }
            catch (Exception) when (closed.Task.IsCompleted) { return ContentDialogResult.None; }
            finally { activeDialog = null; }
        }

        if (loadError is not null)
        {
            await ShowUntilClosedAsync(new ContentDialog
            {
                XamlRoot = xamlRoot,
                Title = "Windows component terms unavailable",
                Content = loadError.Message,
                CloseButtonText = "Quit",
                DefaultButton = ContentDialogButton.Close
            });
            return (false, closed.Task.IsCompleted ? null : host);
        }

        var content = new StackPanel
        {
            Spacing = 12,
            Width = Math.Max(260, Math.Min(500, xamlRoot.Size.Width - 96))
        };
        content.Children.Add(new TextBlock
        {
            Text = "VoxClip includes Microsoft Windows components. Review and accept their terms to use this Windows build. VoxClip itself remains open source under MIT.",
            TextWrapping = TextWrapping.Wrap
        });
        var termsText = new TextBox
        {
            Header = "Windows App SDK terms",
            AcceptsReturn = true,
            Text = terms.DisplayText,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            Height = Math.Max(140, Math.Min(410, xamlRoot.Size.Height - 300))
        };
        AutomationProperties.SetName(termsText, "Windows App SDK terms");
        content.Children.Add(termsText);
        var dialog = new ContentDialog
        {
            XamlRoot = xamlRoot,
            Title = "Windows component terms",
            Content = content,
            PrimaryButtonText = "Accept and continue",
            CloseButtonText = "Quit",
            DefaultButton = ContentDialogButton.Close
        };
        if (await ShowUntilClosedAsync(dialog) != ContentDialogResult.Primary || closed.Task.IsCompleted)
            return (false, closed.Task.IsCompleted ? null : host);
        try { agreement.Accept(terms, terms.Sha256); return (true, host); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            if (!closed.Task.IsCompleted)
                await ShowUntilClosedAsync(new ContentDialog
                {
                    XamlRoot = xamlRoot,
                    Title = "Could not save acceptance",
                    Content = "VoxClip could not save the Windows component terms acceptance. " + error.Message,
                    CloseButtonText = "Quit",
                    DefaultButton = ContentDialogButton.Close
                });
            return (false, closed.Task.IsCompleted ? null : host);
        }
    }

    private static async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog) => await dialog.ShowAsync();
}
