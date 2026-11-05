using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Zoom motion cues on the synthetic frame (design §6.7, Mac FrameCompositor): the composer crops the finished picture by the
/// cue's eased keyframes and fills the frame with it, after the clip's orientation and look and before overlays, in output
/// coordinates, so a flipped clip zooms where it is seen. No FFmpeg: the after-scale stages run on the frame directly.</summary>
public sealed class MotionCueRenderTests(ITestOutputHelper output)
{
    private const int Rate = 48_000;

    /// <summary>A 10 s, 640 × 360 source; nothing cut, so source time is edited time.</summary>
    private static ComposeSnapshot Snapshot(ClipRenderInput clip) => new(
        new("synthetic.mp4", 10, new(640, 360, 30, 0), new(Rate, 2), new(640, 360), "h264", "aac", false, 0, 1, 0),
        TestPlan.FromKept(Rate, 480_000, [new(0, 480_000)]), null, new(new(640, 360), 30, 1_000_000)) { Clip = clip };

    /// <summary>0.5 → 2.5 s: from the whole frame to 1.3× by the left and lower part.</summary>
    private static readonly MotionCue Zoom = new("c-zoom-0", "c", 0.5, 2.5, [new(0, 1, 0.5, 0.5), new(1, 1.3, 0.25, 0.75)]);

    private static PixelBuffer Copy(PixelBuffer frame) => new(frame.Pixels.ToArray(), frame.Width, frame.Height, frame.Stride);

    private static PixelBuffer Finish(PixelBuffer frame, ClipRenderInput clip, double editedTime, bool forPreview = false)
    {
        var result = Copy(frame);
        new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot).FinishClipFrame(result, Snapshot(clip), editedTime, frame.Width, frame.Height,
            new(0, 0, frame.Width, frame.Height), CancellationToken.None, forPreview);
        return result;
    }

    private static PixelBuffer Oriented(PixelBuffer frame, ProjectClipControls controls)
    {
        var (width, height) = ClipPicture.OrientedSize(frame.Width, frame.Height, controls);
        var target = new byte[width * height * 4];
        ClipPicture.Orient(frame, target, controls, CancellationToken.None);
        return new(target, width, height, width * 4);
    }

    /// <summary>The reference fill: <paramref name="crop"/> of <paramref name="source"/> stretched over the whole frame, bilinear.</summary>
    private static PixelBuffer Filled(PixelBuffer source, RectD crop)
    {
        var pixels = new byte[source.Pixels.Length];
        var input = source.Pixels.ToArray();
        for (var row = 0; row < source.Height; row++)
            for (var column = 0; column < source.Width; column++)
            {
                var x = Math.Clamp(crop.X + (column + 0.5) * crop.Width / source.Width - 0.5, 0, source.Width - 1);
                var y = Math.Clamp(crop.Y + (row + 0.5) * crop.Height / source.Height - 0.5, 0, source.Height - 1);
                int x0 = (int)x, y0 = (int)y, x1 = Math.Min(source.Width - 1, x0 + 1), y1 = Math.Min(source.Height - 1, y0 + 1);
                double fx = x - x0, fy = y - y0;
                for (var channel = 0; channel < 4; channel++)
                {
                    double Sample(int sx, int sy) => input[sy * source.Stride + sx * 4 + channel];
                    pixels[row * source.Stride + column * 4 + channel] = (byte)Math.Round(
                        (Sample(x0, y0) * (1 - fx) + Sample(x1, y0) * fx) * (1 - fy) + (Sample(x0, y1) * (1 - fx) + Sample(x1, y1) * fx) * fy);
                }
            }
        return new(pixels, source.Width, source.Height, source.Stride);
    }

    private static double MeanDifference(PixelBuffer left, PixelBuffer right)
    {
        Assert.Equal((left.Width, left.Height), (right.Width, right.Height));
        long total = 0;
        for (var index = 0; index < left.Pixels.Length; index++) total += Math.Abs(left.Pixels.Span[index] - right.Pixels.Span[index]);
        return total / (double)left.Pixels.Length;
    }

    [Fact]
    public void AZoomAtAGivenProgressCropsByItsEasedScaleAndAnchor()
    {
        var source = ClipRenderMediaTests.SyntheticFrame();
        var clip = new ClipRenderInput(null, null) { Motion = [Zoom] };
        // 1.5 s is halfway: the smoothstep's ½ gives 1.15× by (0.375, 0.625).
        var transform = MotionCueRendering.Transform(clip.Motion, 1.5);
        Assert.Equal((1.15, 0.375, 0.625), (Math.Round(transform.Scale, 12), Math.Round(transform.AnchorX, 12), Math.Round(transform.AnchorY, 12)));
        var zoomed = Finish(source, clip, 1.5);
        var expected = Filled(source, transform.Crop(640, 360));
        var difference = MeanDifference(expected, zoomed);
        var unzoomed = MeanDifference(source, zoomed);
        // The crop placed by the other anchor is visibly a different picture.
        var mirroredAnchor = MeanDifference(Filled(source, new MotionCropTransform(1.15, 0.625, 0.375).Crop(640, 360)), zoomed);
        output.WriteLine($"zoom vs bilinear reference: mean {difference:F3}; vs unzoomed {unzoomed:F3}; vs the other anchor {mirroredAnchor:F3}");
        Assert.True(difference < 2, $"{difference}");
        Assert.True(unzoomed > 4 * difference && mirroredAnchor > 4 * difference, $"{unzoomed} / {mirroredAnchor} vs {difference}");
        // Outside the cue, and in a preview with Windows' animation effects off, the frame is untouched.
        Assert.Equal(source.Pixels.ToArray(), Finish(source, clip, 0.4).Pixels.ToArray());
        Assert.Equal(source.Pixels.ToArray(), Finish(source, clip, 2.5).Pixels.ToArray());
        Assert.Equal(source.Pixels.ToArray(), Finish(source, clip with { ReduceMotionInPreview = true }, 1.5, forPreview: true).Pixels.ToArray());
        // Export ignores the preview setting.
        Assert.Equal(zoomed.Pixels.ToArray(), Finish(source, clip with { ReduceMotionInPreview = true }, 1.5).Pixels.ToArray());
    }

    [Fact]
    public void AZoomOnAFlippedClipZoomsWhereThePictureIsSeen()
    {
        var source = ClipRenderMediaTests.SyntheticFrame();
        var flip = new ProjectClipControls("c", 1, null, ClipLook.Original, 0, 0, 0, false, true, 0);
        var flipped = Oriented(source, flip);
        var clip = new ClipRenderInput(flip, null) { Motion = [Zoom] };
        // At 2.4 s the cue is nearly at 1.3× by the left and lower part of what is seen.
        var transform = MotionCueRendering.Transform(clip.Motion, 2.4);
        var zoomed = Finish(flipped, clip, 2.4);
        var expected = Filled(flipped, transform.Crop(640, 360));
        // Zooming the source first and flipping after would zoom by the mirrored side.
        var sourceFirst = Oriented(Finish(source, new ClipRenderInput(null, null) { Motion = [Zoom] }, 2.4), flip);
        var difference = MeanDifference(expected, zoomed);
        var wrongSide = MeanDifference(sourceFirst, zoomed);
        output.WriteLine($"flipped zoom vs reference: mean {difference:F3}; vs zoom-then-flip {wrongSide:F3}; scale {transform.Scale:F4}");
        Assert.True(transform.Scale > 1.29, $"{transform.Scale}");
        Assert.True(difference < 2, $"{difference}");
        Assert.True(wrongSide > 4 * difference, $"{wrongSide} vs {difference}");
    }
}
