using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Core.Tests.V2;

/// <summary>The ruler's ticks between the seconds (issue #41), with the same values as the Swift
/// <c>subsecondTicksAreHalvesTenthsThenFramesOnceSixPointsApart</c>.</summary>
public sealed class TimelineRulerSubsecondTests
{
    [Fact]
    public void SubsecondTicksAreHalvesTenthsThenFramesOnceSixPointsApart()
    {
        // Below 12 px/s a half second is under 6 px: whole seconds only.
        Assert.Empty(TimelineRuler.SubsecondTicks(new(10, 11), 11.9, 30));
        Assert.Equal([10.5, 11.5], TimelineRuler.SubsecondTicks(new(10, 12), 20, 30));
        var tenths = TimelineRuler.SubsecondTicks(new(10, 11), 60, 30);
        Assert.Equal(9, tenths.Count);
        Assert.Equal(10.1, tenths[0], 9);
        Assert.Equal(10.9, tenths[8], 9);
        // 30 fps frames are 6 px apart at 180 px/s; 24 fps already at 144 px/s.
        var frames = TimelineRuler.SubsecondTicks(new(10, 11), 180, 30);
        Assert.Equal(29, frames.Count);
        Assert.Equal(10 + 1.0 / 30, frames[0], 9);
        Assert.Equal(9, TimelineRuler.SubsecondTicks(new(10, 11), 179, 30).Count);
        Assert.Equal(23, TimelineRuler.SubsecondTicks(new(10, 11), 144, 24).Count);
        // Far into a long take the ticks stay on the grid, and never where 1 s minor ticks don't show.
        var late = TimelineRuler.SubsecondTicks(new(3_599, 3_600), 60, 30);
        Assert.Equal(9, late.Count);
        Assert.Equal(3_599.5, late[4], 9);
        Assert.Empty(TimelineRuler.SubsecondTicks(new(0, 100), 2, 30));
        Assert.Empty(TimelineRuler.SubsecondTicks(new(0, double.PositiveInfinity), 60, 30));
    }
}
