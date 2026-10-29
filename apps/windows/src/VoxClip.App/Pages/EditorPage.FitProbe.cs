#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
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
        await DebugSettleColumnAsync();
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
        bool Presented(FrameworkElement element)
        {
            for (DependencyObject? ancestor = element; ancestor is not null; ancestor = VisualTreeHelper.GetParent(ancestor))
            {
                if (ancestor is UIElement presented && (presented.Visibility != Visibility.Visible || presented.Opacity == 0)) return false;
                if (ancestor == RightPane) return true;
            }
            return false;
        }
        var captionPanel = NativeDescendants(RightPane).OfType<CaptionsPanel>().SingleOrDefault();
        var rewritePanel = NativeDescendants(RightPane).OfType<RewritePanel>().SingleOrDefault();
        captionPanel?.DebugFitRealizeGallery();
        var required = ColumnBoundsGate.RequiredIds(state, captionPanel?.DebugFitAllGalleryIds() ?? [],
            rewritePanel?.DebugFitRequiresApply == true, rewritePanel?.DebugFitRequiresSettings == true, captionPanel?.DebugFitRequiresAccent == true);
        var scrollOffsets = NativeDescendants(RightPane).OfType<ScrollViewer>()
            .Select(viewer => (Viewer: viewer, Offset: viewer.VerticalOffset)).ToArray();
        var observations = new List<object>();
        var coverage = new List<object>();
        var unmeasurable = new List<object>();
        var failures = new List<string>();
        var scrollProofs = new List<object>();
        var deferredRealizations = new HashSet<string>();
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
                if (peer is FrameworkElementAutomationPeer { Owner: FrameworkElement nativeOwner }) owner = nativeOwner;
                if (!Presented(owner)) return;
                if (!identities.Add(((WinRT.IWinRTObject)peer).NativeObject.ThisPtr)) return;
                if (AutomationProperties.GetAccessibilityView(owner) != AccessibilityView.Raw && (peer.IsControlElement() || peer.IsContentElement()))
                    peers.Add(peer, owner);
                try
                {
                    if (peer.GetChildren() is { } children) foreach (var child in children) Collect(child, owner);
                }
                catch (Exception exception) when (exception is not OutOfMemoryException) { EnumerationFailed(owner, sample, exception); }
            }
            foreach (var element in NativeDescendants(RightPane).OfType<FrameworkElement>().Where(Presented))
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
                if (owner is ScrollBar && ScrollOwner(owner) is { } scrollOwner)
                {
                    owner = scrollOwner;
                    peer = FrameworkElementAutomationPeer.CreatePeerForElement(owner) ?? throw new InvalidOperationException("No owning viewport peer.");
                    role += " (owning viewport)";
                }
                ColumnScrollRegion? region = null;
                if (ScrollOwner(owner) is { } viewer)
                    region = new(AutomationProperties.GetAutomationId(viewer), ElementBounds(viewer), viewer.VerticalOffset * scale, viewer.ExtentHeight * scale,
                        FrameworkElementAutomationPeer.CreatePeerForElement(viewer) is { } viewportPeer && !viewportPeer.IsOffscreen());
                var bounds = Rectangle(peer.GetBoundingRectangle()).ToScreen(origin.X, origin.Y);
                var offscreen = peer.IsOffscreen();
                if (!bounds.Measurable && offscreen && region is not null && peer is FrameworkElementAutomationPeer { Owner: FrameworkElement nativeOwner }
                    && ReferenceEquals(nativeOwner, owner)) bounds = ElementBounds(owner);
                return new(id, name, role, bounds, offscreen, region);
            }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                unmeasurable.Add(new { Sample = sample, Id = id, Name = name, Role = role, Error = exception.GetType().Name });
                return new(id, name, role, default, true);
            }
        }
        bool HasId(KeyValuePair<AutomationPeer, FrameworkElement> entry, string id)
        {
            try { return entry.Key.GetAutomationId() == id; }
            catch (Exception exception) when (exception is not OutOfMemoryException) { EnumerationFailed(entry.Value, id, exception); return false; }
        }
        Dictionary<AutomationPeer, FrameworkElement> Observe(string sample)
        {
            var peers = CollectPeers(sample);
            foreach (var (peer, owner) in peers)
            {
                var measurement = ReadPeer(peer, owner, sample);
                var decision = ColumnBoundsGate.Assess(measurement, Rectangle(column), Rectangle(client));
                var virtualized = captionPanel?.DebugFitGalleryIdentity(owner);
                var virtualizedId = virtualized?.Id;
                var containerBounds = virtualized is { } identity ? ElementBounds(identity.Container) : default;
                ColumnRect? clippingAncestor = null;
                if (!decision.Accepted && measurement.Offscreen && virtualized is { } clipped && required.Contains(clipped.Id) &&
                    containerBounds.Contains(measurement.Bounds) && ReferenceEquals(ScrollOwner(clipped.Container), ScrollOwner(owner)) &&
                    FrameworkElementAutomationPeer.CreatePeerForElement(clipped.Container)?.IsOffscreen() == true)
                {
                    var ancestorDecision = ColumnBoundsGate.Assess(measurement with { Bounds = containerBounds }, Rectangle(column), Rectangle(client));
                    if (ancestorDecision.Accepted)
                    {
                        clippingAncestor = containerBounds;
                        decision = new(true, "scrolled with owning item/header; explicit required realization follows");
                    }
                }
                if (measurement.Offscreen && virtualized is { } parked && required.Contains(parked.Id) && containerBounds.Contains(measurement.Bounds) &&
                    FrameworkElementAutomationPeer.CreatePeerForElement(parked.Container)?.IsOffscreen() == true &&
                    measurement.Scroll is { } region && (containerBounds.Bottom < region.Viewport.Y - region.VerticalOffset - 1 ||
                    containerBounds.Y > region.Viewport.Y - region.VerticalOffset + region.ExtentHeight + 1))
                {
                    deferredRealizations.Add(parked.Id);
                    decision = new(true, "virtualized cache; explicit required realization follows");
                }
                var ancestors = new List<object>();
                if (!decision.Accepted)
                    for (DependencyObject? ancestor = owner; ancestor is not null; ancestor = VisualTreeHelper.GetParent(ancestor))
                        if (ancestor is FrameworkElement element) ancestors.Add(new { Type = element.GetType().Name,
                            Id = AutomationProperties.GetAutomationId(element), element.Visibility, element.Opacity,
                            Bounds = ElementBounds(element), Clip = element.Clip is RectangleGeometry clip ? (ColumnRect?)Rectangle(clip.Rect) : null,
                            Offscreen = FrameworkElementAutomationPeer.CreatePeerForElement(element)?.IsOffscreen(),
                            Scroll = element is ScrollViewer scroll ? new { scroll.ViewportWidth, scroll.ViewportHeight, scroll.HorizontalOffset,
                                scroll.VerticalOffset, scroll.ExtentWidth, scroll.ExtentHeight, scroll.ScrollableHeight } : null });
                if (sample == "initial" || !decision.Accepted)
                    observations.Add(new { Sample = sample, Peer = measurement, decision.Accepted, decision.Classification,
                        Control = peer.IsControlElement(), Content = peer.IsContentElement(), LayoutBounds = ElementBounds(owner),
                        ClippingAncestor = clippingAncestor, VirtualizedId = virtualizedId, Ancestors = ancestors });
                if (!measurement.Bounds.Measurable)
                {
                    if (sample == "initial") unmeasurable.Add(new { Sample = sample, measurement.Id, measurement.Name, measurement.Role, measurement.Bounds });
                }
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
                if (captionPanel?.DebugFitRealizeChoice(id) == true)
                {
                    await DebugSettleColumnAsync();
                    peers = CollectPeers("realize-" + id);
                }
                var matches = peers.Where(entry => HasId(entry, id)).ToArray();
                if (matches.Length == 0 && captionPanel?.DebugFitRealizeChoice(id) == true)
                {
                    await Task.Delay(120);
                    UpdateLayout();
                    peers = Observe("realize-" + id);
                    matches = peers.Where(entry => HasId(entry, id)).ToArray();
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
                            var before = ReadPeer(peer, owner, "ownership-before");
                            if (peer.GetPattern(PatternInterface.ScrollItem) is IScrollItemProvider scrollItem) scrollItem.ScrollIntoView();
                            else owner.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
                            await DebugSettleColumnAsync();
                            var after = ReadPeer(peer, owner, "ownership-after");
                            var proven = after.Scroll is { } scroll && scroll.Viewport.Contains(after.Bounds) &&
                                ColumnBoundsGate.Assess(after, Rectangle(column), Rectangle(client), required: true).Accepted;
                            scrollProofs.Add(new { Target = id, Before = before, After = after, Proven = proven });
                            if (!proven) failures.Add("scroll ownership not proven: " + id);
                            peers = Observe("scroll-to-" + id);
                        }
                    }
                    catch (Exception exception) when (exception is not OutOfMemoryException)
                    {
                        failures.Add(id + ": realization/ScrollItem failed: " + exception.GetType().Name);
                    }
                }
                var measured = peers.Where(entry => HasId(entry, id)).Select(entry => ReadPeer(entry.Key, entry.Value, id)).ToArray();
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
            State = state.ToString(), RequiredPeers = coverage, UnmeasurablePeers = unmeasurable, Elements = observations,
            DeferredRealizations = deferredRealizations, ScrollProofs = scrollProofs, Failures = failures
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

    private async Task DebugSettleColumnAsync()
    {
        ColumnRect[]? previous = null;
        var stable = 0;
        for (var attempt = 0; attempt < 60; attempt++)
        {
            await Task.Delay(50);
            UpdateLayout();
            var current = NativeDescendants(RightPane).OfType<FrameworkElement>().Select(element =>
            {
                var position = element.TransformToVisual(RightPane).TransformPoint(default);
                return new ColumnRect(position.X, position.Y, element.ActualWidth, element.ActualHeight);
            }).ToArray();
            stable = previous is not null && current.SequenceEqual(previous) ? stable + 1 : 0;
            if (stable >= 3) return;
            previous = current;
        }
        throw new InvalidOperationException("Right-column layout did not settle within three seconds.");
    }
}
#endif
