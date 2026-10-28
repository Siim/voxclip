using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace VoxClip.App.Controls;

internal sealed class TranscriptOverlay : IDisposable
{
    private readonly FrameworkElement owner;
    private readonly Compositor compositor;
    private readonly ShapeVisual behind;
    private readonly ShapeVisual above;
    private EventHandler<object>? pendingDraw;
    private bool retriedLayout;
    private readonly VoxClip.App.ViewModels.TranscriptGeometryCache<Inline, Rect> bounds = new();
    internal bool NeedsLayout => bounds.NeedsLayout;
    internal void Invalidate() { bounds.Invalidate(); retriedLayout = false; }
    internal void DrawAfterLayout(Action draw)
    {
        if (!NeedsLayout || pendingDraw is not null || retriedLayout) return;
        retriedLayout = true;
        pendingDraw = (_, _) =>
        {
            CompositionTarget.Rendering -= pendingDraw;
            pendingDraw = null;
            owner.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                if (!owner.IsLoaded) return;
                draw();
            });
        };
        CompositionTarget.Rendering += pendingDraw;
    }
#if DEBUG
    internal void DebugClearAbove() => above.Shapes.Clear();
    internal IReadOnlyList<Rect> DebugCached(Inline inline) => Cached(inline);
    internal object DebugDiagnostics => new { owner.ActualWidth, owner.ActualHeight, Scale = owner.XamlRoot?.RasterizationScale,
        BehindSize = behind.Size, AboveSize = above.Size, BehindShapes = behind.Shapes.Count, AboveShapes = above.Shapes.Count,
        BehindViewBox = behind.ViewBox?.Size, AboveViewBox = above.ViewBox?.Size, above.IsVisible, above.Opacity, NeedsLayout };
#endif
    private IReadOnlyList<Rect> Cached(Inline inline)
    {
        return bounds.Get(inline, inline is not Run { Text.Length: 0 }, Bounds);
    }
    internal void Measure(Inline inline) => _ = Cached(inline);

    internal TranscriptOverlay(FrameworkElement owner, FrameworkElement background, FrameworkElement foreground)
    {
        this.owner = owner;
        compositor = ElementCompositionPreview.GetElementVisual(owner).Compositor;
        behind = compositor.CreateShapeVisual();
        above = compositor.CreateShapeVisual();
        ElementCompositionPreview.SetElementChildVisual(background, behind);
        ElementCompositionPreview.SetElementChildVisual(foreground, above);
    }

    internal void Clear(double width, double height)
    {
        bounds.BeginDraw();
        behind.Shapes.Clear();
        above.Shapes.Clear();
        behind.Size = above.Size = new((float)width + 4, (float)height + 8);
        behind.Offset = above.Offset = new(-2, -4, 0);
    }

    internal void Word(Run run, bool cut, bool filler, bool lowConfidence, bool corrected, bool ai, bool selected, bool playing, bool rewrite)
    {
        if (!cut && !filler && !lowConfidence && !corrected && !ai && !selected && !playing && !rewrite) return;
        var firstRectangle = true;
        foreach (var rect in Cached(run))
        {
            if (rewrite) Rectangle(behind, new(rect.X - 2, rect.Y, rect.Width + 4, rect.Height), "VcAccentSoftBrush", 4, "VcAccentTextBrush", 1);
            if (selected && !playing && !rewrite) Rectangle(behind, rect, "VcSelectionTranscriptBrush");
            if (playing) Rectangle(behind, new(rect.X - 2, rect.Y, rect.Width + 4, rect.Height), "VcWordPlayingBackgroundBrush", 4);
            if (cut) Rectangle(above, new(rect.X, rect.Y + rect.Height * 0.52, rect.Width, 1.5), "VcCutStrokeBrush");
            if (filler) Pattern(rect.X, rect.Y + rect.Height - 2, rect.Width, "VcWordFillerBrush", 2, 4);
            if (lowConfidence) Pattern(rect.X, rect.Y + rect.Height + 1, rect.Width, "VcWordLowConfidenceBrush", 4, 7);
            if (corrected && firstRectangle) Rectangle(above, new(rect.X + 1, rect.Y + rect.Height + 4, 2, 2), "VcWordCorrectionDotBrush", 1);
            if (ai) Pattern(rect.X, rect.Y + rect.Height - 1, rect.Width, "VcAccentTextBrush", 5, 9);
            firstRectangle = false;
        }
    }

    internal void Strike(Inline inline)
    {
        foreach (var rect in Cached(inline)) Rectangle(above, new(rect.X, rect.Y + rect.Height * 0.52, rect.Width, 1.5), "VcCutStrokeBrush");
    }
    internal void Diff(Run run, VoxClip.App.ViewModels.RewriteDiffKind kind)
    {
        foreach (var rect in Cached(run))
            switch (kind)
            {
                case VoxClip.App.ViewModels.RewriteDiffKind.Removed:
                    Rectangle(above, new(rect.X, rect.Y + rect.Height * 0.52, rect.Width, 1.5), "VcCutStrokeBrush"); break;
                case VoxClip.App.ViewModels.RewriteDiffKind.Inserted:
                    Rectangle(above, new(rect.X, rect.Y + rect.Height - 1, rect.Width, 1.5), "VcAccentTextBrush"); break;
                case VoxClip.App.ViewModels.RewriteDiffKind.Bridge:
                    Pattern(rect.X, rect.Y + rect.Height - 1, rect.Width, "VcAccentTextBrush", 4, 7, 1); break;
            }
    }

    internal void Clip(double top, double bottom, bool selected, bool suggested, double gutter)
    {
        var key = selected ? "VcAccentTextBrush" : "VcLineStrongBrush";
        if (!suggested) Rectangle(above, new(gutter, top, 2, Math.Max(1, bottom - top)), key);
        else for (var vertical = top; vertical < bottom; vertical += 8)
            Rectangle(above, new(gutter, vertical, 2, Math.Min(4, bottom - vertical)), key);
    }

    private void Pattern(double left, double top, double width, string key, double dash, double period, double thickness = 2)
    {
        for (var horizontal = 0.0; horizontal < width; horizontal += period)
            Rectangle(above, new(left + horizontal, top, Math.Min(dash, width - horizontal), thickness), key);
    }

    private void Rectangle(ShapeVisual visual, Rect rect, string fill, double radius = 0, string? stroke = null, double thickness = 0)
    {
        if (rect.Width <= 0 || rect.Height <= 0 || !double.IsFinite(rect.X + rect.Y + rect.Width + rect.Height)) return;
        var geometry = compositor.CreateRoundedRectangleGeometry();
        geometry.Offset = new((float)rect.X + 2, (float)rect.Y + 4);
        geometry.Size = new((float)rect.Width, (float)rect.Height);
        geometry.CornerRadius = new((float)radius);
        var shape = compositor.CreateSpriteShape(geometry);
        shape.FillBrush = compositor.CreateColorBrush(((SolidColorBrush)Ui.ThemeBrush(owner, fill)).Color);
        if (stroke is not null)
        {
            shape.StrokeBrush = compositor.CreateColorBrush(((SolidColorBrush)Ui.ThemeBrush(owner, stroke)).Color);
            shape.StrokeThickness = (float)thickness;
        }
        visual.Shapes.Add(shape);
    }

    internal static IReadOnlyList<Rect> Bounds(Inline inline)
    {
        var result = new List<Rect>();
        var length = inline is Run run ? run.Text.TrimEnd().Length : 1;
        for (var index = 0; index < length; index++)
        {
            var pointer = inline.ContentStart.GetPositionAtOffset(index, LogicalDirection.Forward);
            if (pointer is null) break;
            var rect = pointer.GetCharacterRect(LogicalDirection.Forward);
            var next = pointer.GetPositionAtOffset(1, LogicalDirection.Forward)?.GetCharacterRect(LogicalDirection.Forward);
            if (rect.Width < 0.1 && next is { } end && Math.Abs(rect.Y - end.Y) < 1) rect.Width = Math.Abs(end.X - rect.X);
            if (!double.IsFinite(rect.X + rect.Y + rect.Width + rect.Height)) return [];
            if (rect.Width <= 0 || rect.Height <= 0) continue;
            if (result.Count > 0 && Math.Abs(result[^1].Y - rect.Y) < 1)
            {
                var previous = result[^1];
                var left = Math.Min(previous.X, rect.X);
                result[^1] = new(left, previous.Y, Math.Max(previous.Right, rect.Right) - left, Math.Max(previous.Height, rect.Height));
            }
            else result.Add(rect);
        }
        return result;
    }

    public void Dispose()
    {
        CompositionTarget.Rendering -= pendingDraw;
        pendingDraw = null;
        behind.Dispose();
        above.Dispose();
    }
}
