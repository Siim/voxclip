using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class PipelineTests
{
    [Fact]
    public void PreviewPoolIsBoundedAndOnlyReusesReleasedBuffers()
    {
        var pool = new PreviewFramePool(new(4, 4));
        var leases = Enumerable.Range(0, 8).Select(index => pool.TryRent(index, index, 1)!).ToArray();
        Assert.Null(pool.TryRent(9, 9, 1));
        var firstPixels = leases[0].Frame.Buffer.Pixels;
        firstPixels.Span.Fill(42);
        leases[0].Dispose(); leases[0].Dispose();
        Assert.Throws<ObjectDisposedException>(() => leases[0].Frame);
        using var replacement = pool.TryRent(10, 10, 2)!;
        Assert.Equal(firstPixels, replacement.Frame.Buffer.Pixels);
        Assert.Equal(42, replacement.Frame.Buffer.Pixels.Span[0]);
        Assert.Null(pool.TryRent(11, 11, 2));
        foreach (var lease in leases) lease.Dispose();
    }

    [Theory]
    [InlineData(false, "h264_mf (software)", true)]
    [InlineData(true, "h264_mf", false)]
    public async Task SoftwareFlagReflectsTheSelectedRungWithoutChangingTheConstructor(bool hardwareAvailable, string expectedEncoder, bool expectedSoftware)
    {
        var media = new MediaInfo("missing.mp4", 1, new(640, 360, 30, 0), null, new(640, 360), "h264", null, false, 0, -1, 0);
        var snapshot = new ComposeSnapshot(media, TestPlan.FromKept(48_000, 48_000, [new(0, 48_000)]), null, new(new(640, 360), 30, 2_000_000));
        var exporter = new Exporter(new FrameComposer(new TestRasterizer()), new StubEncoderProbe(hardwareAvailable),
            (job, encoder, progress, ct) => new(job.OutputPath, null, 1, 640, 360, 30, 30, 48_000, 0, "h264", encoder, 0));
        var result = await exporter.ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, "unused.mp4", null), null, TestContext.Current.CancellationToken);
        Assert.Equal(expectedEncoder, result.Encoder);
        Assert.Equal(expectedSoftware, result.SoftwareEncoding);
    }

    private sealed class StubEncoderProbe(bool hardwareAvailable) : IEncoderProbe
    {
        public Task<IReadOnlyList<EncoderInfo>> ProbeAsync(EncoderCacheKey key, IProgress<MediaProgress>? progress, CancellationToken ct)
            => Task.FromResult<IReadOnlyList<EncoderInfo>>([new(EncoderProbe.SoftwareMediaFoundation, true, null), new("h264_mf", hardwareAvailable, null)]);
    }

    [Theory]
    [InlineData(0, 1000, 240, 240, 0)]
    [InlineData(999, 1000, 240, 240, 0)]
    [InlineData(120, 1000, 240, 240, 0.5)]
    [InlineData(879, 1000, 240, 240, 0.5)]
    [InlineData(500, 1000, 240, 240, 1)]
    [InlineData(0, 1000, 0, 0, 1)]
    public void FadeHasExactSilentEdges(long index, long length, long fadeIn, long fadeOut, float expected)
    {
        var start = fadeIn > 0 ? 1 : 0;
        var plan = TestPlan.FromKept(48_000, start + length + (fadeOut > 0 ? 1 : 0), [new(start, start + length)]);
        Assert.Equal(BitConverter.SingleToInt32Bits(expected), BitConverter.SingleToInt32Bits((float)plan.JoinGain(index)));
    }

    [Theory]
    [InlineData(44_100)]
    [InlineData(48_000)]
    public void SharedJoinGainsPreserveEveryLegacyFadeSample(int rate)
    {
        var plan = TestPlan.FromKept(rate, 5000, [new(0, 1000), new(2000, 2007), new(3000, 4000)]);
        long outputIndex = 0;
        foreach (var range in plan.Kept)
        {
            var length = range.EndSample - range.StartSample;
            var fade = Math.Min((long)Math.Floor(0.005 * rate + 0.5), length / 2);
            var fadeIn = range.StartSample > 0 ? fade : 0;
            var fadeOut = range.EndSample < plan.TotalSamples ? fade : 0;
            for (long index = 0; index < length; index++, outputIndex++)
            {
                var expected = 1f;
                if (index < fadeIn) expected *= (float)((double)index / fadeIn);
                var remaining = length - 1 - index;
                if (remaining < fadeOut) expected *= (float)((double)remaining / fadeOut);
                Assert.Equal(BitConverter.SingleToInt32Bits(expected), BitConverter.SingleToInt32Bits((float)plan.JoinGain(outputIndex)));
            }
        }
        Assert.Equal(plan.OutputSamples, outputIndex);
    }

    [Fact]
    public void AudioRingWrapsWithoutDroppingOrOverwritingUnreadBytes()
    {
        var ring = new AudioRing(48_000, 2, 16);
        Assert.Equal(12, ring.Write(Enumerable.Range(1, 12).Select(value => (byte)value).ToArray()));
        var first = new byte[8]; ring.Read(first);
        Assert.Equal(Enumerable.Range(1, 8).Select(value => (byte)value), first);
        Assert.Equal(12, ring.Write(Enumerable.Range(13, 12).Select(value => (byte)value).ToArray()));
        Assert.Equal(0, ring.Write([255]));
        var rest = new byte[20]; ring.Read(rest);
        Assert.Equal(Enumerable.Range(9, 16).Select(value => (byte)value), rest.Take(16));
        Assert.All(rest.Skip(16), value => Assert.Equal(0, value));
    }

    [Fact]
    public void TimelineConsumerUsesFollowingRangeAtJoinAndSourceEndAtEof()
    {
        var plan = TestPlan.FromKept(1000, 4000, [new(0, 500), new(1000, 1500), new(2000, 3500)]);
        Assert.Equal(2500, plan.OutputSamples);
        Assert.Equal(new Join[] { new(500, 5, 5), new(1000, 5, 5), new(2500, 5, 0) }, plan.Joins);
        var cursor = new TimelineCursor(plan);
        Assert.Equal(0, cursor.Source(0));
        Assert.Equal(1, cursor.Source(0.5));
        Assert.Equal(2, cursor.Source(1));
        Assert.Equal(4, cursor.Source(2.5));
        Assert.Equal(0.2, cursor.Source(0.2));
    }

    [Fact]
    public async Task EverythingCutFailsBeforeLoadingNativeLibraries()
    {
        var info = new MediaInfo("missing.mp4", 1, new(640, 360, 30, 0), null, new(640, 360), "h264", null, false, 0, -1, 0);
        var snapshot = new ComposeSnapshot(info, TestPlan.FromKept(48_000, 48_000, []), null, new(new(640, 360), 30, 2_000_000));
        var exception = await Assert.ThrowsAsync<VoxClipException>(() => new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(),
            ExportAspect.Source, ExportQuality.Standard, "unused.mp4", null), null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.EverythingCut, exception.Code);
    }

    [Fact]
    public void ComposerObservesCancellationBeforeTouchingNativeLibraries()
    {
        var buffer = new PixelBuffer(new byte[4], 1, 1, 4);
        Assert.Throws<OperationCanceledException>(() => new FrameComposer(new TestRasterizer()).Compose(buffer, buffer, null!, 0, false, new(true)));
    }

    [Theory]
    [InlineData(3840, 2160, ExportAspect.Source, 1920, 1080)]
    [InlineData(2160, 3840, ExportAspect.Source, 1080, 1920)]
    [InlineData(640, 360, ExportAspect.Portrait, 1080, 1920)]
    [InlineData(640, 360, ExportAspect.Square, 1080, 1080)]
    [InlineData(640, 360, ExportAspect.Landscape, 1920, 1080)]
    public void OutputPresetHasSpecifiedCapAndCrops(int width, int height, ExportAspect aspect, int expectedWidth, int expectedHeight)
    {
        var size = ExportPresets.OutputSize(new(width, height), aspect);
        Assert.Equal(new(expectedWidth, expectedHeight), size);
        var crop = ExportPresets.CenterCrop(new(width, height), size);
        Assert.Equal(width / 2.0, crop.X + crop.Width / 2, 6);
        Assert.Equal(height / 2.0, crop.Y + crop.Height / 2, 6);
    }
}

internal sealed class TestRasterizer : ICaptionRasterizer
{
    internal readonly List<double> Times = [];
    public void Draw(CaptionRenderRequest request, PixelBuffer target, CancellationToken ct)
    { ct.ThrowIfCancellationRequested(); Times.Add(request.Time); target.Pixels.Span[..4].Fill(255); }
    public Task<PixelBuffer> RenderAsync(CaptionRenderRequest request, CancellationToken ct)
    {
        var output = new PixelBuffer(new byte[request.Track.Frame.Width * request.Track.Frame.Height * 4], request.Track.Frame.Width, request.Track.Frame.Height, request.Track.Frame.Width * 4);
        Draw(request, output, ct); return Task.FromResult(output);
    }
}
