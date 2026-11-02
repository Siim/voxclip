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
#if DEBUG
    private CompositionSpriteShape? caretShape;
    internal Rect? DebugCaretBounds { get; private set; }
#endif
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
    internal void DebugClearCaret() { if (caretShape is not null) above.Shapes.Remove(caretShape); }
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
    internal IReadOnlyList<Rect> Rectangles(Inline inline) => Cached(inline);

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
#if DEBUG
        caretShape = null; DebugCaretBounds = null;
#endif
        bounds.BeginDraw();
        behind.Shapes.Clear();
        above.Shapes.Clear();
        behind.Size = above.Size = new((float)width + 168, (float)height + 16);
        behind.Offset = above.Offset = new(-82, -8, 0);
    }

    internal void Word(Run run, bool cut, bool filler, bool lowConfidence, bool corrected, bool ai, bool selected, bool playing, bool rewrite)
    {
        if (!cut && !filler && !lowConfidence && !corrected && !ai && !selected && !playing && !rewrite) return;
        var firstRectangle = true;
        foreach (var rect in Cached(run))
        {
            if (ai && !selected && !Ui.HighContrast) Rectangle(behind, rect, "VcAiTintBrush", 2, opacity: 0.10f);
            if (VoxClip.App.ViewModels.TranscriptWordHighlight.For(selected, false, Ui.HighContrast) is { } selection)
                Rectangle(behind, rect, selection.BackgroundBrush, 2);
            if (cut) Rectangle(above, new(rect.X, rect.Y + rect.Height * 0.52, rect.Width, 1), selected && Ui.HighContrast ? "VcAccentOnBrush" : "VcWordGoneBrush");
            if (lowConfidence) Pattern(rect.X, rect.Y + rect.Height + 1, rect.Width, "VcWordLowConfidenceBrush", 4, 7);
            if (corrected && firstRectangle) Rectangle(above, new(rect.X + 1, rect.Y + rect.Height + 4, 2, 2), "VcWordCorrectionDotBrush", 1);
            firstRectangle = false;
        }
    }

    internal void Strike(Inline inline)
    {
        foreach (var rect in Cached(inline)) Rectangle(above, new(rect.X, rect.Y + rect.Height * 0.52, rect.Width, 1), "VcWordGoneBrush");
    }
    internal void Diff(Run run, VoxClip.App.ViewModels.RewriteDiffKind kind)
    {
        foreach (var rect in Cached(run))
            switch (kind)
            {
                case VoxClip.App.ViewModels.RewriteDiffKind.Removed:
                    Rectangle(above, new(rect.X, rect.Y + rect.Height * 0.52, rect.Width, 1), "VcWordGoneBrush"); break;
                case VoxClip.App.ViewModels.RewriteDiffKind.Inserted:
                    if (!Ui.HighContrast) Rectangle(behind, rect, "VcChangeAddBrush", 2, opacity: 0.19f); break;
                case VoxClip.App.ViewModels.RewriteDiffKind.Bridge:
                    break;
            }
    }

    internal void Clip(double top, double bottom, bool selected, bool suggested, double gutter)
    {
        var key = "VcClipLabelBrush";
        if (!suggested) Rectangle(above, new(gutter, top, 2, Math.Max(1, bottom - top)), key);
        else for (var vertical = top; vertical < bottom; vertical += 8)
            Rectangle(above, new(gutter, vertical, 2, Math.Min(4, bottom - vertical)), key);
    }

    internal void Band(double top, double bottom, double width, bool rtl) => Rectangle(behind, new(rtl ? -44 : -80, top - 8, width + 124, bottom - top + 16), "VcEditorBandBrush");

    internal void ChangeBar(Rect rect, bool focused, bool excluded = false)
    {
        if (excluded) Pattern(rect.X, rect.Bottom - 1, rect.Width, "VcTextTertiaryBrush", 1, 3, 1);
        Rectangle(above, new(owner.FlowDirection == FlowDirection.RightToLeft ? owner.ActualWidth + 11 : -14, rect.Y, 3, rect.Height), "VcChangeAddBrush", 1.5, opacity: focused ? 1 : 0.5f);
    }

    internal void Caret(Run run, bool after, bool selected)
    {
        var pointer = after ? run.ContentEnd : run.ContentStart;
        var rect = pointer.GetCharacterRect(after ? LogicalDirection.Backward : LogicalDirection.Forward);
        var left = owner.FlowDirection == FlowDirection.RightToLeft && !after ? rect.Right : rect.X;
        var caret = new Rect(left, rect.Y, 2, rect.Height);
        var shape = Rectangle(above, caret, selected && Ui.HighContrast ? "VcAccentOnBrush" : "VcAccentTextBrush");
#if DEBUG
        caretShape = shape; DebugCaretBounds = caret;
#endif
    }

    private void Pattern(double left, double top, double width, string key, double dash, double period, double thickness = 2)
    {
        for (var horizontal = 0.0; horizontal < width; horizontal += period)
            Rectangle(above, new(left + horizontal, top, Math.Min(dash, width - horizontal), thickness), key);
    }

    private CompositionSpriteShape? Rectangle(ShapeVisual visual, Rect rect, string fill, double radius = 0, string? stroke = null, double thickness = 0, float opacity = 1)
    {
        if (rect.Width <= 0 || rect.Height <= 0 || !double.IsFinite(rect.X + rect.Y + rect.Width + rect.Height)) return null;
        var geometry = compositor.CreateRoundedRectangleGeometry();
        geometry.Offset = new((float)rect.X + 82, (float)rect.Y + 8);
        geometry.Size = new((float)rect.Width, (float)rect.Height);
        geometry.CornerRadius = new((float)radius);
        var shape = compositor.CreateSpriteShape(geometry);
        var color = ((SolidColorBrush)Ui.ThemeBrush(owner, fill)).Color;
        color.A = (byte)Math.Round(color.A * opacity);
        shape.FillBrush = compositor.CreateColorBrush(color);
        if (stroke is not null)
        {
            shape.StrokeBrush = compositor.CreateColorBrush(((SolidColorBrush)Ui.ThemeBrush(owner, stroke)).Color);
            shape.StrokeThickness = (float)thickness;
        }
        visual.Shapes.Add(shape);
        return shape;
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
