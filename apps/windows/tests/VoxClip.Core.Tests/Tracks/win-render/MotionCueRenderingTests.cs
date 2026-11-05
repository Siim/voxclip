using VoxClip.Core.Domain.ContextDemo;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>Zoom motion cues at render time (twin of Mac MotionCue.transform and CompositionFrameGeometry.crop): keyframes eased with a
/// smoothstep, the earliest cue covering a time wins, nothing outside a cue, and the crop sits by its anchor in top-left pixels.</summary>
public sealed class MotionCueRenderingTests
{
    private static MotionCue Cue(string id, double start, double end, params MotionKeyframe[] keyframes) => new(id, "c1", start, end, keyframes);

    [Fact]
    public void AZoomAtAGivenProgressEasesBetweenItsKeyframes()
    {
        var cue = Cue("zoom", 2, 4, new(0, 1, 0.5, 0.5), new(1, 1.3, 0.25, 0.75));
        Assert.Equal(MotionCropTransform.Identity, MotionCueRendering.Transform(cue, 1.999));
        Assert.Equal(new MotionCropTransform(1, 0.5, 0.5), MotionCueRendering.Transform(cue, 2));
        // Halfway the smoothstep is ½; a quarter in it is 0.15625.
        var half = MotionCueRendering.Transform(cue, 3);
        Assert.Equal((1.15, 0.375, 0.625), (Math.Round(half.Scale, 12), Math.Round(half.AnchorX, 12), Math.Round(half.AnchorY, 12)));
        var quarter = MotionCueRendering.Transform(cue, 2.5);
        Assert.Equal(1 + 0.3 * 0.15625, quarter.Scale, 12);
        // The end is exclusive: the picture is whole again on the cue's last instant.
        Assert.Equal(MotionCropTransform.Identity, MotionCueRendering.Transform(cue, 4));
        // Three keyframes: the middle one holds and the second span eases from it.
        var held = Cue("held", 0, 3, new(0, 1.2, 0.5, 0.5), new(0.5, 1.2, 0.5, 0.5), new(1, 1, 0.5, 0.5));
        Assert.Equal(1.2, MotionCueRendering.Transform(held, 1.2).Scale, 12);
        Assert.Equal(1.1, MotionCueRendering.Transform(held, 2.25).Scale, 12);
    }

    [Fact]
    public void TheEarliestCueCoveringATimeWinsAndTiesGoByIdentity()
    {
        var late = Cue("b-late", 1, 5, new(0, 1.3, 0.5, 0.5), new(1, 1.3, 0.5, 0.5));
        var early = Cue("z-early", 0, 2, new(0, 1.1, 0.5, 0.5), new(1, 1.1, 0.5, 0.5));
        var twin = Cue("a-twin", 0, 2, new(0, 1.2, 0.5, 0.5), new(1, 1.2, 0.5, 0.5));
        Assert.Equal(1.1, MotionCueRendering.Transform([late, early], 1.5).Scale, 12);
        Assert.Equal(1.3, MotionCueRendering.Transform([late, early], 3).Scale, 12);
        Assert.Equal(1.2, MotionCueRendering.Transform([late, early, twin], 1.5).Scale, 12);
        Assert.Equal(MotionCropTransform.Identity, MotionCueRendering.Transform([late, early], 6));
        Assert.Equal(MotionCropTransform.Identity, MotionCueRendering.Transform([late], double.NaN));
    }

    [Fact]
    public void TheCropSitsByItsAnchorInTopLeftPixels()
    {
        // Mac crops bottom-up with (1 − anchorY); top-down that is anchorY from the top.
        Assert.Equal(new(0, 0, 500, 250), new MotionCropTransform(2, 0, 0).Crop(1000, 500));
        Assert.Equal(new(500, 250, 500, 250), new MotionCropTransform(2, 1, 1).Crop(1000, 500));
        Assert.Equal(new(250, 125, 500, 250), new MotionCropTransform(2, 0.5, 0.5).Crop(1000, 500));
        Assert.Equal(new(0, 0, 1000, 500), MotionCropTransform.Identity.Crop(1000, 500));
    }
}
