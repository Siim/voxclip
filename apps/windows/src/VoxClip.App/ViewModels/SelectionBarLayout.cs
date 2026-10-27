namespace VoxClip.App.ViewModels;

internal static class SelectionBarLayout
{
    internal static bool? Below(double top, double bottom, double viewport, bool clipAbove, bool clipBelow)
    {
        var below = top < 56 || clipAbove && !clipBelow;
        if (below && bottom + 56 > viewport) return top >= 56 ? false : null;
        return below;
    }
}
