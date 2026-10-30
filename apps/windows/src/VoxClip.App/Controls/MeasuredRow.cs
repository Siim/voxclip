using Microsoft.UI.Xaml.Controls;
using VoxClip.App.ViewModels;
using Windows.Foundation;

namespace VoxClip.App.Controls;

public sealed class MeasuredRow : Panel
{
    public double Gap { get; set; } = 12;
    internal bool Stacked { get; private set; }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Children.Count != 2) return default;
        var leading = Children[0];
        var trailing = Children[1];
        leading.Measure(new(double.PositiveInfinity, availableSize.Height));
        trailing.Measure(new(double.PositiveInfinity, availableSize.Height));
        Stacked = EditorLayout.StackMeasuredRow(availableSize.Width, leading.DesiredSize.Width, trailing.DesiredSize.Width, Gap);
        var gap = leading.DesiredSize.Width > 0 ? Gap : 0;
        trailing.Measure(new(Stacked ? availableSize.Width : Math.Max(0, availableSize.Width - leading.DesiredSize.Width - gap), availableSize.Height));
        return new(double.IsFinite(availableSize.Width) ? availableSize.Width : leading.DesiredSize.Width + trailing.DesiredSize.Width + gap,
            Stacked ? leading.DesiredSize.Height + gap + trailing.DesiredSize.Height : Math.Max(leading.DesiredSize.Height, trailing.DesiredSize.Height));
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        if (Children.Count != 2) return finalSize;
        var leading = Children[0];
        var trailing = Children[1];
        var gap = leading.DesiredSize.Width > 0 ? Gap : 0;
        if (Stacked)
        {
            leading.Arrange(new(0, 0, finalSize.Width, leading.DesiredSize.Height));
            trailing.Arrange(new(0, leading.DesiredSize.Height + gap, finalSize.Width, trailing.DesiredSize.Height));
        }
        else
        {
            leading.Arrange(new(0, 0, leading.DesiredSize.Width, finalSize.Height));
            trailing.Arrange(new(leading.DesiredSize.Width + gap, 0, Math.Max(0, finalSize.Width - leading.DesiredSize.Width - gap), finalSize.Height));
        }
        return finalSize;
    }
}
