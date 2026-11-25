using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace VoxClip.App.Controls;

internal static class StoryPartStyle
{
    private static readonly Color[] Colors =
    [
        Color.FromArgb(255, 90, 169, 255), Color.FromArgb(255, 180, 140, 255), Color.FromArgb(255, 95, 211, 168),
        Color.FromArgb(255, 255, 179, 92), Color.FromArgb(255, 255, 122, 168), Color.FromArgb(255, 154, 210, 90)
    ];

    internal static SolidColorBrush Brush(FrameworkElement owner, int number) => Ui.HighContrast
        ? (SolidColorBrush)Ui.ThemeBrush(owner, "VcTimelineClipBracketBrush")
        : new(Colors[(number - 1) % Colors.Length]);
}
