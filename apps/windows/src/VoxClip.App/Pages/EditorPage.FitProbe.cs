#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Foundation;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private async Task DebugRightColumnBoundsAsync(MainWindow window, string output, string label)
    {
        await Task.Delay(120);
        UpdateLayout();
        NativeRequire(Math.Abs(RightPane.ActualWidth - RightColumn.ActualWidth) < 0.1, "Right content did not lay out at the column width.");
        var root = (FrameworkElement)window.Content;
        var origin = new NativeGateInput.NativePoint();
        NativeRequire(NativeGateInput.ClientToScreen(WinRT.Interop.WindowNative.GetWindowHandle(window), ref origin), "No client origin.");
        var scale = XamlRoot.RasterizationScale;
        var offset = RightPane.TransformToVisual(root).TransformPoint(default);
        var column = new Rect(origin.X + offset.X * scale, origin.Y + offset.Y * scale, RightPane.ActualWidth * scale, RightPane.ActualHeight * scale);
        var client = new Rect(origin.X, origin.Y, root.ActualWidth * scale, root.ActualHeight * scale);
        var peers = new HashSet<AutomationPeer>();
        void Collect(AutomationPeer peer)
        {
            if (!peers.Add(peer)) return;
            if (peer.GetChildren() is { } children) foreach (var child in children) Collect(child);
        }
        foreach (var element in NativeDescendants(RightPane).OfType<FrameworkElement>())
            if (FrameworkElementAutomationPeer.CreatePeerForElement(element) is { } peer) Collect(peer);
        var observations = new List<object>();
        var failures = new List<string>();
        foreach (var item in Aspect.Items.Cast<CommunityToolkit.WinUI.Controls.SegmentedItem>())
        {
            NativeRequire(item.ActualWidth > 0 && item.Visibility == Visibility.Visible, "A Frame segment disappeared.");
            foreach (var text in NativeDescendants(item).OfType<TextBlock>())
                NativeRequire(!text.IsTextTrimmed, "A Frame label was truncated: " + text.Text);
        }
        NativeRequire(AutomationProperties.GetName(Aspect) == "Frame", "Frame automation name changed.");
        foreach (var peer in peers)
        {
            var bounds = peer.GetBoundingRectangle();
            if (bounds.Width <= 0 || bounds.Height <= 0) continue;
            var offscreen = peer.IsOffscreen();
            bool Fits(Rect container) => bounds.Left >= container.Left - 1 && bounds.Right <= container.Right + 1 &&
                bounds.Top >= container.Top - 1 && bounds.Bottom <= container.Bottom + 1;
            var name = peer.GetName();
            var horizontal = bounds.Left >= Math.Max(column.Left, client.Left) - 1 && bounds.Right <= Math.Min(column.Right, client.Right) + 1;
            var fits = offscreen ? horizontal : Fits(column) && Fits(client);
            observations.Add(new { Name = name, Type = peer.GetClassName(), Bounds = bounds, Offscreen = offscreen, Fits = fits });
            if (!fits) failures.Add(name + " " + bounds);
        }
        NativeRequire(observations.Count > 10, "Right-column UIA coverage was empty or incomplete.");
        await File.WriteAllTextAsync(Path.Combine(output, label + "-bounds.json"), JsonSerializer.Serialize(new
        {
            Column = column, Client = client, FrameStacked = FrameRow.Stacked, TransportStacked = TransportRow.Stacked,
            Elements = observations, Failures = failures
        }, new JsonSerializerOptions { WriteIndented = true }));
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(RightPane);
        using var stream = File.Create(Path.Combine(output, label + "-right-column.png"));
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream.AsRandomAccessStream());
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, (await bitmap.GetPixelsAsync()).ToArray());
        await encoder.FlushAsync();
        NativeRequire(failures.Count == 0, label + " overflowed: " + string.Join("; ", failures));
    }
}
#endif
