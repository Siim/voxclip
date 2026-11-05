using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Effects;

namespace VoxClip.App.Controls;

/// <summary>While a blur, pixelate, arrow or circle is being adjusted, its box draws on the viewer and drags to move, one undo step on
/// release (design §6.8 Adjust). The box maps through the open clip's flip and quarter turns and the export's crop
/// (<see cref="AskClaudeRectGeometry"/>), so it sits on the rendered effect; a drag maps back to the rect as filmed.</summary>
public sealed class AskClaudeBoxOverlay : UserControl
{
    private readonly Canvas surface = new();
    private readonly Rectangle box = new() { StrokeThickness = 2, StrokeDashArray = [6, 3], Fill = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    private EditorViewModel? model;
    private bool dragging;
    private Windows.Foundation.Point origin;
    private double offsetX, offsetY;

    public AskClaudeBoxOverlay()
    {
        IsTabStop = false;
        Content = surface;
        surface.Children.Add(box);
        box.Visibility = Visibility.Collapsed;
        AutomationProperties.SetName(box, "Effect box; drag to move it");
        AutomationProperties.SetAutomationId(box, "AskClaude.ViewerBox");
        ToolTipService.SetToolTip(box, "Drag to move the effect's box");
        box.PointerPressed += Pressed;
        box.PointerMoved += Moved;
        box.PointerReleased += Released;
        box.PointerCanceled += (_, _) => Cancel();
        box.PointerCaptureLost += (_, _) => { if (dragging) Cancel(); };
        SizeChanged += (_, _) => Refresh();
        ActualThemeChanged += (_, _) => Refresh();
    }

    /// <summary>Follows <paramref name="value"/>'s Adjust row, project and playhead.</summary>
    internal void Attach(EditorViewModel value)
    {
        if (model is not null) { model.AskClaudeChanged -= ModelChanged; model.Changed -= ModelChanged; model.PropertyChanged -= Moved; }
        model = value;
        model.AskClaudeChanged += ModelChanged;
        model.Changed += ModelChanged;
        model.PropertyChanged += Moved;
        Refresh();
    }

    private void ModelChanged(object? sender, EventArgs args) => DispatcherQueue.TryEnqueue(Refresh);
    private void Moved(object? sender, System.ComponentModel.PropertyChangedEventArgs args) { if (args.PropertyName == nameof(EditorViewModel.SourceTime) && !dragging) Refresh(); }

    /// <summary>The picture's area on this overlay: the clip's frame fitted and centred, as the preview image is.</summary>
    private (double X, double Y, double Width, double Height) Stage()
    {
        if (model is null) return (0, 0, 0, 0);
        var project = model.Project;
        var video = project.Media.Source.Video;
        var oriented = video is null ? new VoxClip.Core.Domain.Shared.PixelSize(1920, 1080)
            : video.RotationDegrees is 90 or 270 ? new(video.Height, video.Width) : new(video.Width, video.Height);
        var frame = ClipControlsRendering.OutputSize(oriented, project.Export.Aspect, AskClaudeRectGeometry.Controls(project));
        if (frame.Width <= 0 || frame.Height <= 0 || ActualWidth <= 0 || ActualHeight <= 0) return (0, 0, 0, 0);
        var scale = Math.Min(ActualWidth / frame.Width, ActualHeight / frame.Height);
        var width = frame.Width * scale; var height = frame.Height * scale;
        return ((ActualWidth - width) / 2, (ActualHeight - height) / 2, width, height);
    }

    private ClipEffectRect? Shown(ClipEffect effect, double time) =>
        effect.Track.Count == 0 ? effect.Rect : effect.Track.MinBy(sample => Math.Abs(sample.T - time)).Rect;

    private void Refresh()
    {
        if (model?.AskClaudeAdjustingRect is not { } adjusting || Shown(adjusting.Effect, model.SourceTime) is not { } rect)
        {
            box.Visibility = Visibility.Collapsed;
            return;
        }
        var stage = Stage();
        if (AskClaudeRectGeometry.Frame(rect, model.Project, stage.Width, stage.Height) is not { } frame) { box.Visibility = Visibility.Collapsed; return; }
        box.Stroke = Ui.ThemeBrush(this, "VcAccentTextBrush");
        box.Width = Math.Max(4, frame.Width); box.Height = Math.Max(4, frame.Height);
        Canvas.SetLeft(box, stage.X + frame.X + offsetX); Canvas.SetTop(box, stage.Y + frame.Y + offsetY);
        box.Visibility = Visibility.Visible;
    }

    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        if (model?.AskClaudeAdjustingRect is null || !args.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        dragging = true; origin = args.GetCurrentPoint(this).Position; offsetX = offsetY = 0;
        box.CapturePointer(args.Pointer); args.Handled = true;
    }

    private void Moved(object sender, PointerRoutedEventArgs args)
    {
        if (!dragging) return;
        var point = args.GetCurrentPoint(this).Position;
        offsetX = point.X - origin.X; offsetY = point.Y - origin.Y;
        Refresh(); args.Handled = true;
    }

    private void Released(object sender, PointerRoutedEventArgs args)
    {
        if (!dragging) return;
        var (dx, dy) = (offsetX, offsetY);
        dragging = false; offsetX = offsetY = 0;
        box.ReleasePointerCapture(args.Pointer); args.Handled = true;
        if (model?.AskClaudeAdjustingRect is { } adjusting && adjusting.Effect.Rect is { } filmed && (dx != 0 || dy != 0))
        {
            var stage = Stage();
            model.SetAskClaudeBox(adjusting.Id, AskClaudeRectGeometry.Dragged(filmed, dx, dy, model.Project, stage.Width, stage.Height));
        }
        Refresh();
    }

    private void Cancel() { dragging = false; offsetX = offsetY = 0; Refresh(); }
}
