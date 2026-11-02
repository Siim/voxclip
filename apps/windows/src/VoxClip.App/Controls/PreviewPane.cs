using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;

namespace VoxClip.App.Controls;

internal sealed class PreviewPane : Grid
{
    private readonly ContentControl viewer = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private FrameworkElement? transport;
    private bool pointerInside;
    private bool timelineVisible = true;
    internal PreviewPane()
    {
        AutomationProperties.SetAutomationId(this, "Viewer.Pane");
        Children.Add(viewer);
        PointerEntered += (_, _) => { pointerInside = true; UpdateTransport(); };
        PointerExited += (_, _) =>
        {
            pointerInside = false; UpdateTransport();
        };
        SizeChanged += (_, _) => Height = EditorLayout.Viewer(ActualWidth).Height;
    }
    internal void Attach(FrameworkElement surface, FrameworkElement controls)
    {
        viewer.Content = surface;
        transport = controls;
        controls.VerticalAlignment = VerticalAlignment.Bottom;
        Children.Add(controls);
        controls.GotFocus += (_, _) => UpdateTransport();
        controls.LostFocus += (_, _) => DispatcherQueue.TryEnqueue(UpdateTransport);
        UpdateTransport();
    }
    internal void SetPlayback(double seconds, bool playing, bool timelineVisible)
    {
        this.timelineVisible = timelineVisible; UpdateTransport();
    }
    private void UpdateTransport()
    {
        if (transport is not null) transport.Opacity = !timelineVisible || pointerInside ||
            XamlRoot is not null && InputState.DescendsFrom(Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(XamlRoot) as DependencyObject, transport) ? 1 : 0;
    }
}
