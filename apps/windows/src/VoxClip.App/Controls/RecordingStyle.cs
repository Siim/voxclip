using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.App.Controls;

internal static class RecordingStyle
{
    internal static SolidColorBrush Brush(FrameworkElement host, ProjectClock.Region region, bool alternate = false)
    {
        var primary = (SolidColorBrush)Ui.ThemeBrush(host, $"VcRecording{region.ColourIndex + 1}Brush");
        if (!alternate) return primary;
        var surface = ((SolidColorBrush)Ui.ThemeBrush(host, "VcBgSurfaceBrush")).Color;
        var color = primary.Color;
        static byte Blend(byte source, byte background) => (byte)(source * 0.77 + background * 0.23);
        return new(Windows.UI.Color.FromArgb(color.A, Blend(color.R, surface.R), Blend(color.G, surface.G), Blend(color.B, surface.B)));
    }

    internal static FrameworkElement Label(FrameworkElement host, ProjectClock.Region region, string? title = null)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        label.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = Brush(host, region), VerticalAlignment = VerticalAlignment.Center });
        label.Children.Add(new TextBlock { Text = title ?? region.Label, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis });
        return label;
    }
}
