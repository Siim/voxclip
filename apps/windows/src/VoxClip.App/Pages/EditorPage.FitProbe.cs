#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using VoxClip.App.Controls;
using VoxClip.App.ViewModels;
using Windows.Foundation;

namespace VoxClip.App.Pages;

public sealed partial class EditorPage
{
    private async Task DebugRightColumnBoundsAsync(MainWindow window, string output, string label, ColumnFitState state = ColumnFitState.Captions)
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
        ColumnRect Rectangle(Rect bounds) => new(bounds.X, bounds.Y, bounds.Width, bounds.Height);
        ColumnRect ElementBounds(FrameworkElement element)
        {
            var position = element.TransformToVisual(root).TransformPoint(default);
            return new(origin.X + position.X * scale, origin.Y + position.Y * scale, element.ActualWidth * scale, element.ActualHeight * scale);
        }
        ScrollViewer? ScrollOwner(FrameworkElement element)
        {
            ScrollViewer? nearest = null;
            for (DependencyObject? ancestor = element; ancestor is not null; ancestor = VisualTreeHelper.GetParent(ancestor))
            {
                if (ancestor is UIElement { Visibility: not Visibility.Visible }) return null;
                if (ancestor == RightPane) return nearest;
                if (ancestor != element && ancestor is ScrollViewer viewer) nearest ??= viewer;
            }
            return null;
        }
        var captionPanel = NativeDescendants(RightPane).OfType<CaptionsPanel>().SingleOrDefault();
        var rewritePanel = NativeDescendants(RightPane).OfType<RewritePanel>().SingleOrDefault();
        captionPanel?.DebugFitRealizeGallery();
        var required = ColumnBoundsGate.RequiredIds(state, captionPanel?.DebugFitGalleryIds() ?? [],
            rewritePanel?.DebugFitRequiresApply == true, rewritePanel?.DebugFitRequiresSettings == true);
        var scrollOffsets = NativeDescendants(RightPane).OfType<ScrollViewer>()
            .Select(viewer => (Viewer: viewer, Offset: viewer.VerticalOffset)).ToArray();
        var observations = new List<object>();
        var coverage = new List<object>();
        var unmeasurable = new List<object>();
        var failures = new List<string>();
        void EnumerationFailed(FrameworkElement owner, string sample, Exception exception)
        {
            var id = AutomationProperties.GetAutomationId(owner);
            var name = AutomationProperties.GetName(owner);
            var role = owner.GetType().Name;
            unmeasurable.Add(new { Sample = sample, Id = id, Name = name, Role = role, Error = exception.GetType().Name });
            failures.Add(sample + ": cannot enumerate " + role + " " + name + " " + id + ": " + exception.GetType().Name);
        }
        Dictionary<AutomationPeer, FrameworkElement> CollectPeers(string sample)
        {
            var peers = new Dictionary<AutomationPeer, FrameworkElement>();
            var identities = new HashSet<nint>();
            void Collect(AutomationPeer peer, FrameworkElement owner)
            {
                if (!identities.Add(((WinRT.IWinRTObject)peer).NativeObject.ThisPtr)) return;
                if (!peers.TryAdd(peer, owner)) return;
                try
                {
                    if (peer.GetChildren() is { } children) foreach (var child in children) Collect(child, owner);
                }
                catch (Exception exception) when (exception is not OutOfMemoryException) { EnumerationFailed(owner, sample, exception); }
            }
            foreach (var element in NativeDescendants(RightPane).OfType<FrameworkElement>())
                try
                {
                    if (FrameworkElementAutomationPeer.CreatePeerForElement(element) is { } peer)
                    {
                        Collect(peer, element);
                    }
                }
                catch (Exception exception) when (exception is not OutOfMemoryException) { EnumerationFailed(element, sample, exception); }
            var identified = NativeDescendants(RightPane).OfType<FrameworkElement>()
                .Where(element => AutomationProperties.GetAutomationId(element).Length > 0)
                .GroupBy(AutomationProperties.GetAutomationId).Where(group => group.Count() == 1)
                .ToDictionary(group => group.Key, group => group.Single());
            foreach (var peer in peers.Keys.ToArray())
            {
                try
                {
                    if (peer is FrameworkElementAutomationPeer { Owner: FrameworkElement owner }) peers[peer] = owner;
                    else if (identified.TryGetValue(peer.GetAutomationId(), out var identifiedOwner)) peers[peer] = identifiedOwner;
                }
                catch (Exception exception) when (exception is not OutOfMemoryException) { EnumerationFailed(peers[peer], sample, exception); }
            }
            return peers;
        }
        ColumnPeer ReadPeer(AutomationPeer peer, FrameworkElement owner, string sample)
        {
            var id = AutomationProperties.GetAutomationId(owner);
            var name = AutomationProperties.GetName(owner);
            var role = owner.GetType().Name;
            try
            {
                id = peer.GetAutomationId(); name = peer.GetName();
                role = peer.GetAutomationControlType() + "/" + peer.GetClassName();
                ColumnScrollRegion? region = null;
                if (ScrollOwner(owner) is { } viewer)
                    region = new(AutomationProperties.GetAutomationId(viewer), ElementBounds(viewer), viewer.VerticalOffset * scale, viewer.ExtentHeight * scale,
                        FrameworkElementAutomationPeer.CreatePeerForElement(viewer) is { } viewportPeer && !viewportPeer.IsOffscreen());
                return new(id, name, role, Rectangle(peer.GetBoundingRectangle()).ToScreen(origin.X, origin.Y), peer.IsOffscreen(), region);
            }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                unmeasurable.Add(new { Sample = sample, Id = id, Name = name, Role = role, Error = exception.GetType().Name });
                return new(id, name, role, default, true);
            }
        }
        Dictionary<AutomationPeer, FrameworkElement> Observe(string sample)
        {
            var peers = CollectPeers(sample);
            foreach (var (peer, owner) in peers)
            {
                var measurement = ReadPeer(peer, owner, sample);
                var decision = ColumnBoundsGate.Assess(measurement, Rectangle(column), Rectangle(client));
                observations.Add(new { Sample = sample, Peer = measurement, decision.Accepted, decision.Classification });
                if (!measurement.Bounds.Measurable)
                    unmeasurable.Add(new { Sample = sample, measurement.Id, measurement.Name, measurement.Role, measurement.Bounds });
                else if (!decision.Accepted) failures.Add(sample + ": " + measurement.Role + " " + measurement.Name + " " + measurement.Id + ": " + decision.Classification + " " + measurement.Bounds);
            }
            return peers;
        }
        foreach (var item in Aspect.Items.Cast<CommunityToolkit.WinUI.Controls.SegmentedItem>())
        {
            if (item.ActualWidth <= 0 || item.Visibility != Visibility.Visible) failures.Add("A Frame segment disappeared: " + item.Content);
            foreach (var text in NativeDescendants(item).OfType<TextBlock>())
                if (text.IsTextTrimmed) failures.Add("A Frame label was truncated: " + text.Text);
        }
        if (AutomationProperties.GetName(Aspect) != "Frame") failures.Add("Frame automation name changed.");
        ColumnRect InBar(FrameworkElement element)
        {
            var position = element.TransformToVisual(TransportRow).TransformPoint(default);
            return new(position.X, position.Y, element.ActualWidth, element.ActualHeight);
        }
        var transport = new
        {
            Bar = new ColumnRect(0, 0, TransportRow.ActualWidth, TransportRow.ActualHeight), Back = InBar(PreviewBack), Play = InBar(PreviewPlay),
            Forward = InBar(PreviewForward), Tag = AiModified.Visibility == Visibility.Visible ? InBar(AiModified) : (ColumnRect?)null, Time = InBar(TransportTime)
        };
        failures.AddRange(ColumnBoundsGate.TransportFailures(transport.Bar, transport.Back, transport.Play, transport.Forward, transport.Tag,
            transport.Time, TransportRow.Stacked, TransportRow.Gap));
        try
        {
            var peers = Observe("initial");
            foreach (var id in required)
            {
                var matches = peers.Where(entry => ReadPeer(entry.Key, entry.Value, id).Id == id).ToArray();
                if (matches.Length == 0 && captionPanel?.DebugFitRealizeChoice(id) == true)
                {
                    await Task.Delay(120);
                    UpdateLayout();
                    peers = Observe("realize-" + id);
                    matches = peers.Where(entry => ReadPeer(entry.Key, entry.Value, id).Id == id).ToArray();
                }
                if (matches.Length > 0)
                {
                    var preferred = matches.FirstOrDefault(entry => entry.Key is FrameworkElementAutomationPeer);
                    var (peer, owner) = preferred.Key is null ? matches[0] : preferred;
                    try
                    {
                        if (peer.GetPattern(PatternInterface.VirtualizedItem) is IVirtualizedItemProvider unrealized) unrealized.Realize();
                        if (ScrollOwner(owner) is not null)
                        {
                            if (peer.GetPattern(PatternInterface.ScrollItem) is IScrollItemProvider scrollItem) scrollItem.ScrollIntoView();
                            else owner.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
                            await Task.Delay(120);
                            UpdateLayout();
                            peers = Observe("scroll-to-" + id);
                        }
                    }
                    catch (Exception exception) when (exception is not OutOfMemoryException)
                    {
                        failures.Add(id + ": realization/ScrollItem failed: " + exception.GetType().Name);
                    }
                }
                var measured = peers.Select(entry => ReadPeer(entry.Key, entry.Value, id)).Where(peer => peer.Id == id).ToArray();
                if (id == "PreviewStage" && measured.Length > 0)
                    measured = [.. measured, new ColumnPeer(id, AutomationProperties.GetName(PreviewStage), "Stage layout",
                        ElementBounds(PreviewStage), PreviewStage.Visibility != Visibility.Visible)];
                var rejected = ColumnBoundsGate.RequiredFailures([id], measured, Rectangle(column), Rectangle(client));
                coverage.Add(new { RequiredId = id, Found = measured, Failures = rejected });
                failures.AddRange(rejected);
                if (measured.Length == 0) unmeasurable.Add(new { Id = id, Name = id, Role = "required peer", Error = "missing or unrealized" });
            }
        }
        finally
        {
            foreach (var entry in scrollOffsets) entry.Viewer.ChangeView(null, entry.Offset, null, true);
            await Task.Delay(120);
            UpdateLayout();
        }
        await File.WriteAllTextAsync(Path.Combine(output, label + "-bounds.json"), JsonSerializer.Serialize(new
        {
            Column = column, Client = client, FrameStacked = FrameRow.Stacked, TransportStacked = TransportRow.Stacked, Transport = transport,
            State = state.ToString(), RequiredPeers = coverage, UnmeasurablePeers = unmeasurable, Elements = observations, Failures = failures
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
