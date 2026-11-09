using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Thumbnails;
using Xunit;

namespace VoxClip.Media.Tests.Thumbnails;

/// <summary>"9:16 follows your face" in still frames (ADR-R48 part 2): <see cref="CurrentFrames"/> moves a clip's 9:16 and 1:1 crop to its
/// measured face, as the composer does for preview and export, and keeps it inside the picture; 16:9 and clips without a face centre keep
/// the centre crop.</summary>
public sealed class CurrentFrameCropTests
{
    /// <summary>A 160 × 90 frame: each 10 px column holds its own grey level, so a crop's left edge reads back as a level.</summary>
    private static PixelBuffer Columns()
    {
        var pixels = new byte[160 * 90 * 4];
        for (var y = 0; y < 90; y++)
            for (var x = 0; x < 160; x++)
            {
                var level = (byte)(x / 10 * 16);
                var offset = (y * 160 + x) * 4;
                (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]) = (level, level, level, 255);
            }
        return new(pixels, 160, 90, 160 * 4);
    }

    private static ProjectClipControls Face(double x) =>
        new("c1", 1, null, ClipLook.Original, 0, 0, 0, false, false, 0, new ReframeSettings(ReframeSettings.FaceMode, 1, x, 0.5));

    /// <summary>The grey level of the output's middle row at column <paramref name="x"/>.</summary>
    private static byte Level(PixelBuffer frame, int x) => frame.Pixels.Span[(frame.Height / 2 * frame.Width + x) * 4];

    [Fact]
    public void APortraitStillFollowsTheFaceAndStaysInsideThePicture()
    {
        // 9:16 of a 16:9 source: a crop about 51 px wide of 160, centred at 80 without a face.
        var output = new PixelSize(18, 32);
        var centred = CurrentFrames.Transform(Columns(), 0, output);
        var left = CurrentFrames.Transform(Columns(), 0, output, controls: Face(0.2));
        var edge = CurrentFrames.Transform(Columns(), 0, output, controls: Face(0.0));
        Assert.Equal(Level(centred, 0), Level(CurrentFrames.Transform(Columns(), 0, output, controls: new("c1", 1.5, null, ClipLook.Original, 0, 0, 0, false, false, 0)), 0));
        Assert.True(Level(left, 0) < Level(centred, 0), "the crop moved left, to the face");
        Assert.Equal(0, Level(edge, 0));
        Assert.True(Level(edge, 0) <= Level(left, 0), "kept inside the picture at its left edge");
        // A flip or turn is not drawn in a still frame, so the face is read where it is in the source.
        var flipped = CurrentFrames.Transform(Columns(), 0, output, controls: Face(0.2) with { FlipHorizontal = true });
        Assert.Equal(Level(left, 0), Level(flipped, 0));
    }

    [Fact]
    public void ALandscapeStillKeepsTheCentreCrop()
    {
        var output = new PixelSize(32, 18);
        Assert.Equal(Level(CurrentFrames.Transform(Columns(), 0, output), 0), Level(CurrentFrames.Transform(Columns(), 0, output, controls: Face(0.1)), 0));
    }
}
