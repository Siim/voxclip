using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace VoxClip.App.Controls;

internal sealed class RightColumn : Grid
{
    private readonly Border fade = new() { Height = 12, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false };
    private readonly CaptionsPanel captions;
    private RewritePanel? rewrite;
    internal Control FocusTarget => rewrite?.FocusTarget ?? captions.FocusTarget;
    internal RightColumn(CaptionsPanel captions)
    {
        this.captions = captions;
        Children.Add(captions);
        Children.Add(fade);
        ActualThemeChanged += (_, _) => UpdateFade();
        UpdateFade();
    }
    internal void ShowRewrite(RewritePanel panel)
    {
        if (rewrite is not null) Children.Remove(rewrite);
        rewrite = panel;
        captions.Visibility = Visibility.Collapsed;
        Children.Insert(1, panel);
    }
    internal void CloseRewrite()
    {
        if (rewrite is not null) Children.Remove(rewrite);
        rewrite = null;
        captions.Visibility = Visibility.Visible;
    }
    private void UpdateFade()
    {
        var color = ((SolidColorBrush)Ui.ThemeBrush(this, "VcBgSurfaceBrush")).Color;
        var clear = color; clear.A = 0;
        fade.Background = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(0, 1), GradientStops = { new() { Color = clear, Offset = 0 }, new() { Color = color, Offset = 1 } } };
    }
}
