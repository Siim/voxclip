using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.Controls;

public sealed class CaptionPositionOverlay : UserControl
{
    private readonly Canvas surface = new();
    private readonly ContentControl handle = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Border outline = new() { BorderThickness = new(1), CornerRadius = new(4) };
    private readonly List<Border> guides = [];
    private EditorViewModel? model;
    private CaptionTrack? track;
    private double time;
    private bool dragging;
    internal bool IsDragging => dragging;
    private CaptionPosition pending;
    private CaptionPosition origin;
    internal void Attach(EditorViewModel value) => model = value;
    public CaptionPositionOverlay()
    {
        IsTabStop = false; Content = surface;
        for (var index = 0; index < 9; index++) { var guide = new Border { IsHitTestVisible = false, Visibility = Visibility.Collapsed }; guides.Add(guide); surface.Children.Add(guide); }
        handle.Content = outline; surface.Children.Add(handle);
        AutomationProperties.SetName(handle, "Caption position. Drag to move captions.");
        AutomationProperties.SetHelpText(handle, "Use Position in Captions for keyboard control.");
        ToolTipService.SetToolTip(handle, "Drag to move captions");
        handle.PointerPressed += Pressed; handle.PointerMoved += Moved; handle.PointerReleased += Released;
        handle.PointerCanceled += (_, _) => Cancel(); handle.PointerCaptureLost += (_, _) => { if (dragging) Cancel(); };
        handle.KeyDown += (_, args) => { if (args.Key == Windows.System.VirtualKey.Escape) { Cancel(); args.Handled = true; } };
        SizeChanged += (_, _) => Refresh(); ActualThemeChanged += (_, _) => Refresh();
    }
    internal void Update(CaptionTrack? value, double editedTime)
    {
        if (!ReferenceEquals(track, value) && dragging) Cancel();
        track = value; time = editedTime; Refresh();
    }
    internal void Position(double editedTime) { time = editedTime; if (!dragging) Refresh(); }
    internal void Cancel() { dragging = false; handle.ReleasePointerCaptures(); Refresh(); }
    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        if (track?.Style.Position.UserDraggable != true || model is null || model.Busy || !args.GetCurrentPoint(handle).Properties.IsLeftButtonPressed) return;
        origin = new(track.Style.Position.X, track.Style.Position.Y); pending = origin;
        dragging = true; handle.CapturePointer(args.Pointer); Refresh(); args.Handled = true;
    }
    private void Moved(object sender, PointerRoutedEventArgs args)
    {
        if (!dragging) return;
        var point = args.GetCurrentPoint(this).Position;
        pending = CaptionDragGeometry.Snap(point.X / Math.Max(1, ActualWidth), point.Y / Math.Max(1, ActualHeight));
        Refresh(); args.Handled = true;
    }
    private void Released(object sender, PointerRoutedEventArgs args)
    {
        if (!dragging) return;
        Moved(sender, args); dragging = false; handle.ReleasePointerCapture(args.Pointer);
        model?.MoveCaptionAnchor(pending); Refresh(); args.Handled = true;
    }
    private void Refresh()
    {
        foreach (var guide in guides) guide.Visibility = Visibility.Collapsed;
        if (track is not { Pages.Count: > 0 } current || !current.Style.Position.UserDraggable || model is null)
        { handle.Visibility = Visibility.Collapsed; return; }
        handle.Visibility = Visibility.Visible;
        var page = CaptionEvaluator.PageAt(current, time) ?? current.Pages.FirstOrDefault(page => page.Start >= time) ?? current.Pages[^1];
        var visual = page.Visual;
        handle.Width = Math.Max(1, visual.Width / current.Frame.Width * ActualWidth);
        handle.Height = Math.Max(1, visual.Height / current.Frame.Height * ActualHeight);
        Canvas.SetLeft(handle, visual.X / current.Frame.Width * ActualWidth + (dragging ? (pending.X - origin.X) * ActualWidth : 0));
        Canvas.SetTop(handle, visual.Y / current.Frame.Height * ActualHeight + (dragging ? (pending.Y - origin.Y) * ActualHeight : 0));
        var clear = ((SolidColorBrush)Ui.ThemeBrush(this, "VcStageBrush")).Color; clear.A = 0;
        outline.Background = new SolidColorBrush(clear);
        outline.BorderBrush = Ui.ThemeBrush(this, "VcChipMediaForegroundBrush"); outline.Opacity = dragging ? 0.8 : 0.001;
        if (!dragging) return;
        var shade = ((SolidColorBrush)Ui.ThemeBrush(this, "VcStageBrush")).Color; shade.A = 77;
        var index = 0;
        foreach (var zone in CaptionDragGeometry.Zones(current.Frame.Width, current.Frame.Height))
            Place(guides[index++], zone.X * ActualWidth, zone.Y * ActualHeight, zone.Width * ActualWidth, zone.Height * ActualHeight, new SolidColorBrush(shade));
        foreach (var fraction in new[] { 1.0 / 3, 0.5, 2.0 / 3 })
        {
            Place(guides[index++], fraction * ActualWidth, 0, 1, ActualHeight, Ui.ThemeBrush(this, "VcChipMediaForegroundBrush"));
            Place(guides[index++], 0, fraction * ActualHeight, ActualWidth, 1, Ui.ThemeBrush(this, "VcChipMediaForegroundBrush"));
        }
    }
    private static void Place(Border element, double left, double top, double width, double height, Brush brush)
    {
        element.Width = width; element.Height = height; element.Background = brush; element.Visibility = Visibility.Visible;
        Canvas.SetLeft(element, left); Canvas.SetTop(element, top);
    }
}
