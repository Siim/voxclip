using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace VoxClip.App.Controls;

internal sealed class RightColumn : Grid
{
    private readonly Border fade = new() { Height = 12, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false };
    internal RightColumn(CaptionsPanel captions)
    {
        Children.Add(captions);
        Children.Add(fade);
        ActualThemeChanged += (_, _) => UpdateFade();
        UpdateFade();
    }
    private void UpdateFade()
    {
        var color = ((SolidColorBrush)Ui.ThemeBrush(this, "VcBgSurfaceBrush")).Color;
        var clear = color; clear.A = 0;
        fade.Background = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(0, 1), GradientStops = { new() { Color = clear, Offset = 0 }, new() { Color = color, Offset = 1 } } };
    }
}
