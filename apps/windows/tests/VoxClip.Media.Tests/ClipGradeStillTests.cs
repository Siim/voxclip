using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>Picture's stills (looks spec 2026-11-28, sections 7 and 11.3): the framed picture before the grade, the paused frame
/// with another colour state as the export renders it, and look tiles cut from the still through the export's grade.</summary>
public sealed class ClipGradeStillTests
{
    private const int Rate = 48_000;
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(20);

    private static ProjectClipControls Graded() => ClipGradeMediaTests.Basis with
    {
        Look = ClipLook.Warm, ColorAdjustments = new(4, 10, 0, 0),
        ColorGrade = new ClipColorGrade { Amount = 80, Exposure = 25, Highlights = -20, Vibrance = 30, Vignette = 40, Grain = 30 }
    };

    private static ProjectClipControls Other() => ClipGradeMediaTests.Basis with
    {
        Look = ClipLook.Bw, ColorGrade = new ClipColorGrade { Temperature = 40, Fade = 25, Vignette = 60, Grain = 15 }
    };

    /// <summary>The colour state removed: Compare's As filmed.</summary>
    private static ProjectClipControls AsFilmed(ProjectClipControls controls) =>
        controls with { Look = ClipLook.Original, ColorAdjustments = null, ColorGrade = null };

    private static ComposeSnapshot Snapshot(ProjectClipControls? controls, PixelSize? size = null, bool audio = true)
    {
        var output = size ?? new PixelSize(320, 180);
        const long samples = 96_000;
        return new(new("synthetic.mp4", samples / (double)Rate, new(output.Width, output.Height, 30, 0), audio ? new(Rate, 2) : null, output, "h264",
            audio ? "aac" : null, false, 0, 1, 0), TestPlan.FromKept(Rate, samples, [new(0, samples)]), null, new(output, 30, 1_000_000))
        { Clip = controls is null ? null : new(controls, null) };
    }

    private static PixelBuffer Copy(PixelBuffer frame) => new(frame.Pixels.ToArray(), frame.Width, frame.Height, frame.Stride);

    private static PixelBuffer Finished(PixelBuffer frame, ComposeSnapshot snapshot, double editedTime, FrameStill still = default)
    {
        var result = Copy(frame);
        new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot).FinishClipFrame(result, snapshot, editedTime, frame.Width, frame.Height,
            new(0, 0, frame.Width, frame.Height), CancellationToken.None, still: still);
        return result;
    }

    [Fact]
    public void AStillBeforeTheGradeIsTheFramedPicture()
    {
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        var snapshot = Snapshot(Graded());
        Assert.NotEqual(frame.Pixels.ToArray(), Finished(frame, snapshot, 1).Pixels.ToArray());
        Assert.Equal(frame.Pixels.ToArray(), Finished(frame, snapshot, 1, new(true, null)).Pixels.ToArray());
        Assert.Equal(frame.Pixels.ToArray(), Finished(frame, snapshot, 1, new(true, Other())).Pixels.ToArray());
    }

    [Fact]
    public void AStillWithAnotherColourStateIsThatStatesExportFrame()
    {
        var frame = ClipGradeMediaTests.Gradient(320, 180);
        var graded = Graded();
        var other = Other();
        // Only the colour state comes from the override: the clip keeps its speed, so the grain is the rendered frame's.
        var timed = graded with { Speed = 1.5 };
        Assert.Equal(Finished(frame, Snapshot(timed with { Look = other.Look, ColorAdjustments = null, ColorGrade = other.ColorGrade }), 1.2).Pixels.ToArray(),
            Finished(frame, Snapshot(timed), 1.2, new(false, other with { Speed = 3 })).Pixels.ToArray());
        // Compare: the export with the colour state removed is the framed picture.
        Assert.Equal(frame.Pixels.ToArray(), Finished(frame, Snapshot(graded), 1.2, new(false, AsFilmed(graded))).Pixels.ToArray());
    }

    [Fact]
    public void ALookTileIsTheExportFrameCutToItsSquare()
    {
        // A 1:1 tile: the square of the still is the tile, so the only difference allowed is none. A tile's vignette sits on the
        // tile itself and it shows no grain (section 7.4).
        var still = TestCard(256, 320);
        var square = new RectD(0, 32, 256, 256);
        var library = ClipLookLibrary.Load(FixtureLoader.SharedRoot);
        var fix = new ClipColorFix(-15, 25, 10);
        foreach (var look in library.Looks)
        {
            var colour = ClipGradeMediaTests.Basis.WithLook(look, 100, fix);
            var tile = ClipLookTiles.Render(still, square, 256, colour, CancellationToken.None);
            Assert.Equal((256, 256), (tile.Width, tile.Height));
            // The export's picture before stage F, cut to the square.
            var preFinish = colour with { ColorGrade = colour.ColorGrade is { } grade ? grade with { Vignette = 0, Grain = 0 } : null };
            var export = Finished(still, Snapshot(preFinish, new(256, 320)), 1);
            var expected = new PixelBuffer(export.Pixels.Slice(32 * export.Stride, 256 * export.Stride).ToArray(), 256, 256, export.Stride);
            ClipPicture.Finish(expected, ClipGradeRecipe.For(colour), 0, null, CancellationToken.None, grain: false);
            Assert.True(expected.Pixels.Span.SequenceEqual(tile.Pixels.Span), look.Id);
        }
        // A smaller tile scales the square down first.
        var small = ClipLookTiles.Render(still, square, 72, ClipGradeMediaTests.Basis.WithLook(library.Look("bw")!), CancellationToken.None);
        Assert.Equal((72, 72, 72 * 4), (small.Width, small.Height, small.Stride));
        var pixel = small.Pixels.Span.Slice((36 * 72 + 36) * 4, 3);
        Assert.True(pixel[0] == pixel[1] && pixel[1] == pixel[2]);
    }

    /// <summary>shared/looks/test-card.png stretched to <paramref name="width"/> × <paramref name="height"/>, BGRA.</summary>
    internal static PixelBuffer TestCard(int width, int height)
    {
        using var card = SKBitmap.Decode(Path.Combine(FixtureLoader.SharedRoot, "looks", "test-card.png"));
        using var bitmap = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Opaque));
        using (var canvas = new SKCanvas(bitmap))
        using (var image = SKImage.FromBitmap(card))
            canvas.DrawImage(image, new SKRect(0, 0, card.Width, card.Height), new SKRect(0, 0, width, height), new SKSamplingOptions(SKFilterMode.Nearest), null);
        return new(bitmap.Bytes, width, height, bitmap.RowBytes);
    }

    private sealed class Worker : IPreviewVideoWorker
    {
        internal List<(double Source, bool Exact)> Reads { get; } = [];
        public Task Ready => Task.CompletedTask;
        public double Position { get; private set; }
        public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
        {
            lock (Reads) Reads.Add((source, exact));
            Position = source;
            var pixels = new byte[4 * 2 * 4];
            Array.Fill(pixels, (byte)(10 + (int)(source * 40)));
            return Task.FromResult(new PixelBuffer(pixels, 4, 2, 16));
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class Composer : IFrameComposer
    {
        internal List<(byte Decoded, PixelSize Output, ProjectClipControls? Controls, double Edited, bool Preview)> Calls { get; } = [];
        public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
        {
            lock (Calls) Calls.Add((decoded.Pixels.Span[0], new(output.Width, output.Height), snapshot.Clip?.Controls, editedTime, forPreview));
            output.Pixels.Span.Fill(forPreview ? (byte)1 : (byte)2);
        }
    }

    [Fact]
    public async Task APausedStillComposesTheExportFrameWithoutPresentingIt()
    {
        var ct = TestContext.Current.CancellationToken;
        var worker = new Worker();
        var composer = new Composer();
        await using var preview = new PreviewEngine(composer, initialize: _ => { }, createWorker: (_, _) => worker);
        IPreviewEngine contract = preview;
        var graded = Graded() with { Speed = 1.25 };
        await preview.LoadAsync(Snapshot(graded, audio: false), null, ct).WaitAsync(Timeout, ct);
        await preview.SeekAsync(0.75, true, ct).WaitAsync(Timeout, ct);
        int presented;
        lock (composer.Calls) presented = composer.Calls.Count(call => call.Preview);
        var position = preview.Position;
        var other = Other();
        var still = await contract.StillAsync(other, ct).WaitAsync(Timeout, ct);
        Assert.Equal((320, 180, 320 * 4), (still.Width, still.Height, still.Stride));
        Assert.All(still.Pixels.ToArray(), value => Assert.Equal(2, value));
        lock (composer.Calls)
        {
            Assert.Equal(presented, composer.Calls.Count(call => call.Preview));
            var call = composer.Calls[^1];
            Assert.False(call.Preview);
            Assert.Equal(0.75, call.Edited);
            Assert.Equal((byte)(10 + 30), call.Decoded);
            Assert.Equal(graded with { Look = other.Look, ColorAdjustments = other.ColorAdjustments, ColorGrade = other.ColorGrade }, call.Controls);
        }
        lock (worker.Reads) Assert.Equal((0.75, true), worker.Reads[^1]);
        Assert.Equal(position, preview.Position);
        // Only the shared frame composer can stop before the grade.
        await Assert.ThrowsAsync<NotSupportedException>(() => contract.StillBeforeGradeAsync(ct).WaitAsync(Timeout, ct));
    }

    [Fact]
    public async Task StillsNeedAPausedPreview()
    {
        var ct = TestContext.Current.CancellationToken;
        var clock = 0.0;
        await using var preview = new PreviewEngine(new Composer(), initialize: _ => { }, createWorker: (_, _) => new Worker(),
            clockOverride: () => Volatile.Read(ref clock));
        await preview.LoadAsync(Snapshot(Graded(), audio: false), null, ct).WaitAsync(Timeout, ct);
        await preview.PlayAsync(ct).WaitAsync(Timeout, ct);
        await Assert.ThrowsAsync<InvalidOperationException>(() => preview.StillAsync(Other(), ct).WaitAsync(Timeout, ct));
        await preview.PauseAsync(ct).WaitAsync(Timeout, ct);
        var still = await preview.StillAsync(Other(), ct).WaitAsync(Timeout, ct);
        Assert.Equal(320, still.Width);
    }

    /// <summary>Hover, focus and Compare previews equal the export compositor's frame byte for byte, and the tiles start from the
    /// frame before the grade (sections 7.2, 7.8 and 11.3). The real compositor scales with FFmpeg.</summary>
    [Fact]
    [Trait("Category", "RequiresFFmpeg")]
    public async Task PreviewStillsAreTheExportCompositorsFrames()
    {
        await NativeTest.RequireAsync();
        var ct = TestContext.Current.CancellationToken;
        var worker = new CardWorker();
        var composer = new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot);
        await using var preview = new PreviewEngine(composer, initialize: _ => { }, createWorker: (_, _) => worker);
        var graded = Graded();
        var snapshot = Snapshot(graded, new(180, 320), audio: false);
        await preview.LoadAsync(snapshot, null, ct).WaitAsync(Timeout, ct);
        await preview.SeekAsync(1.1, true, ct).WaitAsync(Timeout, ct);
        var reference = new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot);
        PixelBuffer Export(ComposeSnapshot value, bool pictureOnly = false)
        {
            var frame = new PixelBuffer(new byte[180 * 320 * 4], 180, 320, 180 * 4);
            reference.PrepareSnapshot(value);
            try { reference.Compose(worker.Frame, frame, value, 1.1, false, null, ct, pictureOnly: pictureOnly); }
            finally { reference.ReleaseSnapshot(value); }
            return frame;
        }
        foreach (var colour in new[] { Other(), AsFilmed(graded), graded })
        {
            var still = await preview.StillAsync(colour, ct).WaitAsync(Timeout, ct);
            var expected = Export(snapshot with { Clip = new(graded with { Look = colour.Look, ColorAdjustments = colour.ColorAdjustments, ColorGrade = colour.ColorGrade }, null) });
            Assert.True(expected.Pixels.Span.SequenceEqual(still.Pixels.Span));
        }
        var before = await preview.StillBeforeGradeAsync(ct).WaitAsync(Timeout, ct);
        Assert.True(Export(snapshot, pictureOnly: true).Pixels.Span.SequenceEqual(before.Pixels.Span));
    }

    private sealed class CardWorker : IPreviewVideoWorker
    {
        internal PixelBuffer Frame { get; } = TestCard(360, 640);
        public Task Ready => Task.CompletedTask;
        public double Position { get; private set; }
        public Task<PixelBuffer> ReadAsync(double source, bool exact, CancellationToken ct)
        {
            Position = source;
            return Task.FromResult(Frame);
        }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
