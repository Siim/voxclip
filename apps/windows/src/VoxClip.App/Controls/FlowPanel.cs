using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace VoxClip.App.Controls;

/// <summary>Chips in a row that wraps, each at its own width, <see cref="Spacing"/> apart (design §6.8's flow layout).</summary>
internal sealed class FlowPanel : Panel
{
    internal double Spacing { get; init; } = 6;

    protected override Size MeasureOverride(Size availableSize)
    {
        double x = 0, y = 0, line = 0, widest = 0;
        foreach (var child in Children)
        {
            child.Measure(new(availableSize.Width, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > availableSize.Width) { y += line + Spacing; x = 0; line = 0; }
            x += size.Width + Spacing;
            line = Math.Max(line, size.Height);
            widest = Math.Max(widest, x - Spacing);
        }
        return new(double.IsInfinity(availableSize.Width) ? widest : Math.Min(widest, availableSize.Width), y + line);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, line = 0;
        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > finalSize.Width) { y += line + Spacing; x = 0; line = 0; }
            child.Arrange(new(x, y, Math.Min(size.Width, finalSize.Width), size.Height));
            x += size.Width + Spacing;
            line = Math.Max(line, size.Height);
        }
        return finalSize;
    }
}
