using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Context-demo placements on Windows (doc/spec/context-demo.md; Mac FrameCompositor's demo layer and
/// ContextDemoCompositionTests): the screen recording replaces the picture over its placement on the edited clock, half-open,
/// upright by its own rotation and never by the clip's flip or turn; a missing or changed recording stops the render. Synthetic frames
/// stand in for the decoder, so no FFmpeg is needed.</summary>
public sealed class ContextDemoRenderTests
{
    private const int Rate = 48_000;

    private static Project Fixture() => ProjectSerialization.Deserialize(FixtureLoader.ReadText("fixtures/context-demo/v4-project.voxclip"));

    /// <summary>A 320 × 180 recording frame: red on the left, blue on the right, a white band along the top, and green carrying the
    /// source time in hundredths, so a pixel says which frame and which way up it is.</summary>
    internal static PixelBuffer Recording(double sourceTime)
    {
        const int width = 320, height = 180;
        var pixels = new byte[width * height * 4];
        var green = (byte)Math.Round(sourceTime * 100);
        for (var row = 0; row < height; row++)
            for (var column = 0; column < width; column++)
            {
                var offset = (row * width + column) * 4;
                var band = row < 30;
                pixels[offset] = band ? (byte)255 : column < width / 2 ? (byte)0 : (byte)200;
                pixels[offset + 1] = band ? (byte)255 : green;
                pixels[offset + 2] = band ? (byte)255 : column < width / 2 ? (byte)200 : (byte)0;
                pixels[offset + 3] = 255;
            }
        return new(pixels, width, height, width * 4);
    }

    /// <summary><paramref name="frame"/> stored a quarter turn anticlockwise, as a file whose display rotation is 90° clockwise holds it.</summary>
    private static PixelBuffer StoredTurned(PixelBuffer frame)
    {
        int width = frame.Height, height = frame.Width;
        var pixels = new byte[width * height * 4];
        var input = frame.Pixels.Span;
        for (var row = 0; row < frame.Height; row++)
            for (var column = 0; column < frame.Width; column++)
                input.Slice(row * frame.Stride + column * 4, 4).CopyTo(pixels.AsSpan(((frame.Width - 1 - column) * width + row) * 4, 4));
        return new(pixels, width, height, width * 4);
    }

    private sealed class Frames(int rotation = 0) : IContextDemoFrames
    {
        internal List<(string AssetId, double SourceTime)> Reads { get; } = [];
        internal int Disposed { get; private set; }
        public (PixelBuffer Frame, int Rotation) Read(string assetId, double sourceTime, CancellationToken ct)
        {
            Reads.Add((assetId, sourceTime));
            var frame = Recording(sourceTime);
            return (rotation == 90 ? StoredTurned(frame) : frame, rotation);
        }
        public void Dispose() => Disposed++;
    }

    private static ComposeSnapshot Snapshot(ProjectClipControls? controls = null, PixelSize? size = null)
    {
        var project = Fixture();
        var plan = TestPlan.FromKept(Rate, 336_000, [new(0, 336_000)]);
        var output = size ?? new PixelSize(640, 360);
        var layers = ContextDemoRendering.Resolve(project, null, new RenderTimeline.Legacy(plan), "/data");
        return new(new("synthetic.mp4", 7, new(640, 360, 30, 0), new(Rate, 1), new(640, 360), "h264", "aac", false, 0, 1, 0), plan, null,
            new(output, 30, 1_000_000)) { ContextDemo = layers, Clip = controls is null ? null : new(controls, null) };
    }

    private static PixelBuffer Grey(PixelSize size)
    {
        var pixels = new byte[size.Width * size.Height * 4];
        Array.Fill(pixels, (byte)90);
        return new(pixels, size.Width, size.Height, size.Width * 4);
    }

    private static PixelBuffer Draw(ComposeSnapshot snapshot, double editedTime, IContextDemoFrames frames)
    {
        var composer = new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot, _ => frames);
        composer.PrepareSnapshot(snapshot);
        var output = Grey(snapshot.Output.Size);
        composer.DrawContextDemo(output, snapshot, editedTime, false, CancellationToken.None);
        composer.FinishClipFrame(output, snapshot, editedTime, 640, 360, new(0, 0, 640, 360), CancellationToken.None);
        composer.ReleaseSnapshot(snapshot);
        return output;
    }

    private static (byte Blue, byte Green, byte Red) Pixel(PixelBuffer frame, double x, double y)
    {
        var offset = (int)(y * (frame.Height - 1)) * frame.Stride + (int)(x * (frame.Width - 1)) * 4;
        var span = frame.Pixels.Span;
        return (span[offset], span[offset + 1], span[offset + 2]);
    }

    private static double MeanDifference(PixelBuffer left, PixelBuffer right)
    {
        Assert.Equal((left.Width, left.Height), (right.Width, right.Height));
        long total = 0;
        for (var index = 0; index < left.Pixels.Length; index++) total += Math.Abs(left.Pixels.Span[index] - right.Pixels.Span[index]);
        return total / (double)left.Pixels.Length;
    }

    [Fact]
    public void APlacementShowsItsRecordingAtItsTimeAndTheSourcePictureOtherwise()
    {
        var snapshot = Snapshot();
        Assert.NotNull(snapshot.ContextDemo);
        var frames = new Frames();
        // Before the placement and at its end (half-open) the source picture stays.
        Assert.Equal((90, 90, 90), Pixel(Draw(snapshot, 0.99, frames), 0.5, 0.5));
        Assert.Equal((90, 90, 90), Pixel(Draw(snapshot, 2, frames), 0.5, 0.5));
        Assert.Empty(frames.Reads);
        // Edited 1.25 s is a quarter second into placement-a: demo-a's frame at 0.25 s fills the frame, upright.
        var shown = Draw(snapshot, 1.25, frames);
        Assert.Equal(("demo-a", 0.25), Assert.Single(frames.Reads));
        Assert.Equal((0, 25, 200), Pixel(shown, 0.25, 0.6));
        Assert.Equal((200, 25, 0), Pixel(shown, 0.75, 0.6));
        Assert.Equal((255, 255, 255), Pixel(shown, 0.5, 0.05));
        // A different shape centre-crops the recording to fill it, like any picture.
        var portrait = Draw(Snapshot(size: new(360, 640)), 1.5, frames);
        Assert.Equal((0, 50, 200), Pixel(portrait, 0.3, 0.6));
        Assert.Equal((200, 50, 0), Pixel(portrait, 0.7, 0.6));
    }

    [Fact]
    public void SnapshotsThatOnlyChangeCaptionsShareTheRecordingsUntilTheLastIsReleased()
    {
        var frames = new Frames();
        var opened = 0;
        var composer = new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot, _ => { opened++; return frames; });
        var first = Snapshot();
        var captioned = first with { Captions = null, Output = first.Output with { VideoBitrate = 2_000_000 } };
        composer.PrepareSnapshot(first);
        composer.PrepareSnapshot(captioned);
        Assert.Equal(1, opened);
        composer.ReleaseSnapshot(first);
        Assert.Equal(0, frames.Disposed);
        composer.DrawContextDemo(Grey(captioned.Output.Size), captioned, 1.5, true, CancellationToken.None);
        composer.ReleaseSnapshot(captioned);
        Assert.Equal(1, frames.Disposed);
        Assert.Throws<InvalidOperationException>(() => composer.DrawContextDemo(Grey(first.Output.Size), first, 1.5, true, CancellationToken.None));
        // Outside a placement nothing is read, so a released snapshot still composes its source picture.
        composer.DrawContextDemo(Grey(first.Output.Size), first, 0.5, true, CancellationToken.None);
    }

    [Theory]
    [InlineData(true, 0)]
    [InlineData(false, 180)]
    [InlineData(true, 90)]
    public void AFlippedOrTurnedClipLeavesTheScreenRecordingUpright(bool flip, int degrees)
    {
        var controls = new ProjectClipControls("clip-main", 1, ClipShape.Landscape, ClipLook.Original, 0, 0, 0, false, flip, degrees);
        var size = new PixelSize(640, 360);
        var upright = Draw(Snapshot(size: size), 1.5, new Frames());
        var turned = Draw(Snapshot(controls, size), 1.5, new Frames());
        Assert.Equal(0, MeanDifference(upright, turned));
        Assert.Equal((0, 50, 200), Pixel(turned, 0.25, 0.6));
        Assert.Equal((255, 255, 255), Pixel(turned, 0.5, 0.05));
    }

    [Fact]
    public void ARecordingStoredOnItsSideShowsUprightByItsOwnRotation()
    {
        var upright = Draw(Snapshot(), 1.5, new Frames());
        var stored = Draw(Snapshot(), 1.5, new Frames(rotation: 90));
        Assert.True(MeanDifference(upright, stored) < 1, $"{MeanDifference(upright, stored)}");
        Assert.Equal((0, 50, 200), Pixel(stored, 0.25, 0.6));
    }

    [Fact]
    public void AMissingChangedOrLinkedRecordingStopsTheRender()
    {
        var root = Directory.CreateTempSubdirectory("voxclip-context-demo-render-").FullName;
        try
        {
            var project = Fixture();
            var plan = TestPlan.FromKept(Rate, 336_000, [new(0, 336_000)]);
            var layers = ContextDemoRendering.Resolve(project, null, new RenderTimeline.Legacy(plan), root)!;
            var asset = layers.Input.Assets.Single();
            void Stops()
            {
                var error = Assert.Throws<VoxClipException>(() => ContextDemoFrames.Open(layers, CancellationToken.None));
                Assert.Equal((VoxClipErrorCode.ExportFailed, ContextDemoRendering.AssetMessage), (error.Code, error.Message));
            }
            Stops();
            // An MP4 of the recorded size whose bytes are not the recording's.
            var path = layers.AssetPath(asset);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var bytes = new byte[asset.ByteSize];
            bytes[3] = 24;
            System.Text.Encoding.ASCII.GetBytes("ftypisom").CopyTo(bytes, 4);
            File.WriteAllBytes(path, bytes);
            ContextDemoFrames.RequirePresent(layers);
            Stops();
            // A link in its place.
            var elsewhere = Path.Combine(root, "elsewhere.mp4");
            File.Move(path, elsewhere);
            File.CreateSymbolicLink(path, elsewhere);
            Assert.Throws<VoxClipException>(() => ContextDemoFrames.RequirePresent(layers));
            Stops();
        }
        finally { Directory.Delete(root, true); }
    }
}
