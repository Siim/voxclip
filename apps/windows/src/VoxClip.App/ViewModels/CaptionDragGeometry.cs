using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal static class CaptionDragGeometry
{
    internal static CaptionPosition Snap(double horizontal, double vertical)
    {
        static double SnapAxis(double value)
        {
            var clamped = Math.Clamp(value, 0, 1);
            foreach (var guide in new[] { 1.0 / 3, 0.5, 2.0 / 3 }) if (Math.Abs(guide - clamped) < 0.025) return guide;
            return clamped;
        }
        return new(SnapAxis(horizontal), SnapAxis(vertical));
    }
    internal static IReadOnlyList<RectD> Zones(double width, double height) => width * 10 < height * 9
        ? [new(0, 0, 1, 0.12), new(0, 0.78, 1, 0.22), new(0.88, 0, 0.12, 1)]
        : [new(0, width * 9 > height * 10 ? 0.9 : 0.88, 1, width * 9 > height * 10 ? 0.1 : 0.12)];
}
