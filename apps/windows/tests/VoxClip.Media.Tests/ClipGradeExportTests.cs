using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

/// <summary>The export seam (looks spec 2026-11-28, section 11.2): each exporter frame before the encoder is the grade of the same
/// frame before the grade, P through T and the mix, then the finish at each pixel with the frame's own index.
/// Needs Windows' H.264 encoder and FFmpeg; hosted Windows CI runs it.</summary>
[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class ClipGradeExportTests(ITestOutputHelper output)
{
    private static readonly long[] Frames = [0, 15, 45];

    private static PixelBuffer Copy(PixelBuffer frame) => new(frame.Pixels.ToArray(), frame.Width, frame.Height, frame.Stride);

    private static unsafe Exporter CreateExporter(Dictionary<long, (PixelBuffer Decoded, PixelBuffer Composed)> captured)
        => new(new FrameComposer(), new EncoderProbe(), frameObserver: (index, decoded, composed, _) =>
        {
            if (Frames.Contains(index)) captured[index] = (Copy(decoded), Copy(composed));
        });

    [Fact]
    public async Task ExportedFramesAreTheReferenceGradeOfTheFrameBeforeIt()
    {
        await NativeTest.RequireAsync(windows: true);
        var ct = TestContext.Current.CancellationToken;
        var source = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "counter-1080p.mp4");
        var media = await new FfmpegMediaProbe().ProbeAsync(source, ct);
        var samples = checked((long)Math.Round(media.DurationSeconds * 48_000));
        var library = ClipLookLibrary.Load(FixtureLoader.SharedRoot);
        var look = ClipGradeMediaTests.Basis.WithLook(library.Look("warmPrint")!, 70, new(20, 30, -10));
        var controls = look with { ColorGrade = look.ColorGrade! with { Vignette = 35, Grain = 25 } };
        var spec = ClipControlsRendering.Output(media.OrientedSize, media.Video!.FrameRate, ExportAspect.Source, ExportQuality.Standard, controls);
        var snapshot = new ComposeSnapshot(media, TestPlan.FromKept(48_000, samples, [new(0, samples)]), null, spec) { Clip = new(controls, null) };
        var captured = new Dictionary<long, (PixelBuffer Decoded, PixelBuffer Composed)>();
        var exporter = CreateExporter(captured);
        var directory = Directory.CreateTempSubdirectory("voxclip-grade-export-");
        try
        {
            await exporter.ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard,
                Path.Combine(directory.FullName, "graded.mp4"), null) { Loudness = Core.Domain.Loudness.ExportLoudness.Off }, null, ct);
        }
        finally { directory.Delete(true); }
        Assert.Equal(Frames, captured.Keys.Order());
        var composer = new FrameComposer(new TestRasterizer(), FixtureLoader.SharedRoot);
        var recipe = ClipGradeRecipe.For(controls);
        var worst = 0;
        foreach (var index in Frames)
        {
            var (decoded, composed) = captured[index];
            var editedTime = Exporter.EditedTime(snapshot, index, spec.FrameRate);
            var before = new PixelBuffer(new byte[composed.Pixels.Length], composed.Width, composed.Height, composed.Stride);
            composer.PrepareSnapshot(snapshot);
            try { composer.Compose(decoded, before, snapshot, editedTime, false, null, ct, still: new(true, null)); }
            finally { composer.ReleaseSnapshot(snapshot); }
            var hash = ClipGrain.FrameHash(FrameComposer.RenderedFrameIndex(snapshot, editedTime));
            Assert.Equal(ClipGrain.FrameHash((uint)index), hash);
            // The export frame is the grade of the frame before it, then the finish with the frame's own index, exactly.
            var graded = new PixelBuffer(before.Pixels.ToArray(), before.Width, before.Height, before.Stride);
            ClipPicture.Grade(graded, recipe, ct);
            var finished = new PixelBuffer(graded.Pixels.ToArray(), graded.Width, graded.Height, graded.Stride);
            ClipPicture.Finish(finished, recipe, hash, null, ct);
            Assert.True(finished.Pixels.Span.SequenceEqual(composed.Pixels.Span), $"frame {index}");
            // And that grade is the Core reference chain within one level; the finish's own replay is ClipGradeMediaTests'.
            for (var y = 0; y < composed.Height; y += 7)
                for (var x = 0; x < composed.Width; x += 7)
                {
                    var offset = y * composed.Stride + x * 4;
                    var input = new[] { before.Pixels.Span[offset + 2] / 255.0, before.Pixels.Span[offset + 1] / 255.0, before.Pixels.Span[offset] / 255.0 };
                    var expected = recipe.Apply(input).Select(ClipGradeRecipe.Byte).ToArray();
                    int[] found = [graded.Pixels.Span[offset + 2], graded.Pixels.Span[offset + 1], graded.Pixels.Span[offset]];
                    var distance = found.Zip(expected).Max(pair => Math.Abs(pair.First - pair.Second));
                    worst = Math.Max(worst, distance);
                    Assert.True(distance <= 1, $"frame {index} ({x},{y}): {string.Join(",", found)} vs {string.Join(",", expected)}");
                }
        }
        output.WriteLine($"export seam: largest channel difference from the reference chain {worst}");
    }
}
