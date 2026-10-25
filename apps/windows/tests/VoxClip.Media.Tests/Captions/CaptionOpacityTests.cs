using System.Runtime.InteropServices;
using VoxClip.Core.Domain.Captions;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

[Trait("Category", "Captions")]
public sealed class CaptionOpacityTests
{
    [Theory]
    [InlineData(0.0)]
    [InlineData(1.0 / 255)]
    [InlineData(0.125)]
    [InlineData(0.5)]
    [InlineData(0.875)]
    [InlineData(1.0)]
    public void AlphaRampScalesEveryPremultipliedChannelAndCompositesOnTargets(double opacity)
    {
        const int width = 256, height = 1, left = 2, top = 1, stride = (width + 4) * 4 + 8;
        var source = new byte[width * 4];
        for (var value = 0; value < width; value++)
        {
            source[value * 4] = (byte)value;
            source[value * 4 + 1] = (byte)(value / 2);
            source[value * 4 + 2] = (byte)(value / 4);
            source[value * 4 + 3] = (byte)value;
        }
        foreach (var backgroundAlpha in new byte[] { 0, 128, 255 })
        {
            var background = new byte[stride * 3];
            for (var offset = 0; offset < background.Length; offset += 4)
            {
                background[offset] = (byte)(backgroundAlpha / 3);
                background[offset + 1] = (byte)(backgroundAlpha / 2);
                background[offset + 2] = backgroundAlpha;
                background[offset + 3] = backgroundAlpha;
            }
            var expected = background.ToArray();
            ReferenceComposite(source, width * 4, expected, stride, left, top, width, height, opacity);
            var actual = background.ToArray();
            SkiaCaptionRasterizer.CompositePremultipliedOpacity(source, width * 4, actual, stride,
                left, top, width, height, opacity, CancellationToken.None);
            Assert.Equal(expected, actual);
            for (var pixel = 0; pixel < actual.Length / 4; pixel++)
                for (var channel = 0; channel < 3; channel++)
                    Assert.True(actual[pixel * 4 + channel] <= actual[pixel * 4 + 3], $"Invalid premultiplication at {pixel}");
            if (opacity == 0.875 && backgroundAlpha == 0)
            {
                Assert.Equal(1, actual[top * stride + (left + 1) * 4 + 3]);
                Assert.Equal(2, actual[top * stride + (left + 2) * 4 + 3]);
            }
        }
    }

    [Theory]
    [InlineData(1.0)]
    [InlineData(0.5)]
    public async Task AnimatedNeonFadeMatchesFullOpacityIntermediateOnTransparentAndOpaqueFrames(double scale)
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/layout/neon-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(fixture.RootElement.GetProperty("input"));
        var sample = fixture.RootElement.GetProperty("expected").GetProperty("samples")[1];
        var request = new CaptionRenderRequest(track, sample.GetProperty("t").GetDouble(), Scale: scale);
        var opacity = CaptionEvaluator.Evaluate(track, request.Time)!.PageAlpha;
        Assert.InRange(Math.Abs(0.875 - opacity), 0, 0.000002);
        Assert.Equal(1, sample.GetProperty("pageScale").GetDouble());
        var full = await new SkiaCaptionRasterizer().RenderAsync(request with { ReduceMotion = true }, CancellationToken.None);
        var fullBytes = full.Pixels.ToArray();
        var renderer = new SkiaCaptionRasterizer();
        var bandUnscaled = new byte[full.Pixels.Length];
        renderer.TestOpacityBandReady = (bitmap, left, top, width, height) =>
        {
            var raw = new byte[bitmap.ByteCount];
            Marshal.Copy(bitmap.GetPixels(), raw, 0, raw.Length);
            for (var row = 0; row < height; row++)
                raw.AsSpan(row * bitmap.RowBytes, width * 4).CopyTo(bandUnscaled.AsSpan((top + row) * full.Stride + left * 4, width * 4));
        };
        foreach (var backgroundAlpha in new byte[] { 0, 128, 255 })
        {
            var background = new byte[full.Pixels.Length];
            for (var offset = 0; offset < background.Length; offset += 4)
            {
                var column = offset / 4 % full.Width;
                var row = offset / 4 / full.Width;
                background[offset] = (byte)(backgroundAlpha * ((column / 9 + row / 4) % 256) / 255);
                background[offset + 1] = (byte)(backgroundAlpha * ((column / 5 + row / 7) % 256) / 255);
                background[offset + 2] = (byte)(backgroundAlpha * ((column / 3 + row / 11) % 256) / 255);
                background[offset + 3] = backgroundAlpha;
            }
            var expected = background.ToArray();
            ReferenceComposite(full.Pixels.Span, full.Stride, expected, full.Stride, 0, 0, full.Width, full.Height, opacity);
            var actual = new PixelBuffer(background, full.Width, full.Height, full.Stride);
            renderer.Draw(request, actual, CancellationToken.None);
            if (backgroundAlpha == 0)
                Assert.True(fullBytes.AsSpan().SequenceEqual(bandUnscaled),
                    $"Neon full-opacity intermediate differs from the band at byte {FirstDifference(fullBytes, bandUnscaled)}");
            Assert.True(expected.AsSpan().SequenceEqual(actual.Pixels.Span),
                $"Neon fade differs on alpha {backgroundAlpha}, scale {scale}, first byte {FirstDifference(expected, actual.Pixels.Span)}");
            for (var offset = 0; offset < actual.Pixels.Length; offset += 4)
                for (var channel = 0; channel < 3; channel++)
                    Assert.True(actual.Pixels.Span[offset + channel] <= actual.Pixels.Span[offset + 3],
                        $"Invalid premultiplication at {offset}");
        }
        Assert.InRange(renderer.RetainedOpacityBandBytes, 1, full.Pixels.Length - 1);
        Assert.Equal(1, renderer.OpacityCanvasSaveCount);
    }

    [Fact]
    public async Task OpacityBandRecoversAfterCancellationAndGrowth()
    {
        using var fixture = FixtureLoader.ReadJson("fixtures/captions/layout/neon-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(fixture.RootElement.GetProperty("input"));
        var narrow = new CaptionRenderRequest(track, track.Pages[4].Start + 0.075);
        var wide = new CaptionRenderRequest(track, track.Pages[1].Start + 0.075);
        Assert.True(track.Pages[1].Visual.Width > track.Pages[4].Visual.Width);
        Assert.InRange(CaptionEvaluator.Evaluate(track, narrow.Time)!.PageAlpha, 0.001, 0.999);
        Assert.InRange(CaptionEvaluator.Evaluate(track, wide.Time)!.PageAlpha, 0.001, 0.999);
        var rasterizer = new SkiaCaptionRasterizer { QueueShadowBlurs = false };
        var small = new PixelBuffer(new byte[1080 * 1920 * 4], 1080, 1920, 1080 * 4);
        rasterizer.Draw(narrow, small, CancellationToken.None);
        var first = small.Pixels.ToArray();
        var smallBytes = rasterizer.RetainedOpacityBandBytes;
        using var cancellation = new CancellationTokenSource();
        rasterizer.TestCheckpoint = checkpoint =>
        {
            if (checkpoint == SkiaCaptionRasterizer.RenderCheckpoint.ShadowBlur) cancellation.Cancel();
        };
        var target = new PixelBuffer(new byte[first.Length], 1080, 1920, 1080 * 4);
        Assert.ThrowsAny<OperationCanceledException>(() => rasterizer.Draw(wide, target, cancellation.Token));
        Assert.Equal(1, rasterizer.OpacityCanvasSaveCount);
        rasterizer.TestCheckpoint = null;
        target.Pixels.Span.Clear();
        rasterizer.Draw(wide, target, CancellationToken.None);
        var expected = await new SkiaCaptionRasterizer().RenderAsync(wide, CancellationToken.None);
        Assert.True(expected.Pixels.Span.SequenceEqual(target.Pixels.Span));
        Assert.InRange(rasterizer.RetainedOpacityBandBytes, smallBytes + 1, first.Length - 1);
        small.Pixels.Span.Clear();
        rasterizer.Draw(narrow, small, CancellationToken.None);
        Assert.True(first.AsSpan().SequenceEqual(small.Pixels.Span));
    }

    private static int FirstDifference(ReadOnlySpan<byte> expected, ReadOnlySpan<byte> actual)
    {
        for (var index = 0; index < expected.Length; index++) if (expected[index] != actual[index]) return index;
        return -1;
    }

    private static void ReferenceComposite(ReadOnlySpan<byte> source, int sourceStride, Span<byte> target, int targetStride,
        int left, int top, int width, int height, double opacity)
    {
        for (var row = 0; row < height; row++)
            for (var column = 0; column < width; column++)
            {
                var sourceIndex = row * sourceStride + column * 4;
                var targetIndex = (top + row) * targetStride + (left + column) * 4;
                var alpha = (int)Math.Floor(source[sourceIndex + 3] * opacity + 0.5);
                var remaining = 255 - alpha;
                for (var channel = 0; channel < 3; channel++)
                {
                    var scaled = (int)Math.Floor(source[sourceIndex + channel] * opacity + 0.5);
                    target[targetIndex + channel] = (byte)Math.Min(255,
                        scaled + (target[targetIndex + channel] * remaining + 127) / 255);
                }
                target[targetIndex + 3] = (byte)Math.Min(255,
                    alpha + (target[targetIndex + 3] * remaining + 127) / 255);
            }
    }
}
