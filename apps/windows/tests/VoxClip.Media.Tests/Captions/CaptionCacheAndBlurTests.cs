using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

[Trait("Category", "Captions")]
public sealed class CaptionCacheAndBlurTests
{
    [Theory]
    [InlineData("neon")]
    [InlineData("karaoke")]
    [InlineData("outline")]
    [InlineData("clean-subtitle")]
    [InlineData("lower-third")]
    [InlineData("gradient")]
    public async Task StableCacheHitsAndMissesMatchOnGreyAndPhotoTargets(string style)
    {
        using var document = FixtureLoader.ReadJson($"fixtures/captions/layout/{style}-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        var cached = new SkiaCaptionRasterizer();
        var uncached = new SkiaCaptionRasterizer { CacheEnabled = false };
        var page = track.Pages[0];
        var request = Enumerable.Range(1, (int)((page.End - page.Start) * 100))
            .Select(index => new CaptionRenderRequest(track, page.Start + index / 100.0))
            .First(candidate => !cached.IsAnimating(candidate));
        foreach (var photo in new[] { false, true })
        {
            cached.ClearPageCache();
            var background = new byte[1080 * 1920 * 4];
            for (var offset = 0; offset < background.Length; offset += 4)
            {
                var column = offset / 4 % 1080;
                var row = offset / 4 / 1080;
                background[offset] = photo ? (byte)((column / 9 + row / 4) % 256) : (byte)90;
                background[offset + 1] = photo ? (byte)((column / 5 + row / 7) % 256) : (byte)90;
                background[offset + 2] = photo ? (byte)((column / 3 + row / 11) % 256) : (byte)90;
                background[offset + 3] = 255;
            }
            var expected = new PixelBuffer(background.ToArray(), 1080, 1920, 1080 * 4);
            uncached.Draw(request, expected, CancellationToken.None);
            Assert.InRange(uncached.LastOverlayClearPixels, 1, 1080 * 1920 - 1);
            Assert.Equal(0, uncached.LastOverlayCopyPixels);
            var actual = new PixelBuffer(background.ToArray(), 1080, 1920, 1080 * 4);
            cached.Draw(request, actual, CancellationToken.None);
            Assert.True(expected.Pixels.Span.SequenceEqual(actual.Pixels.Span), $"{style}, photo {photo}: cache miss differs");
            Assert.Equal(uncached.LastOverlayClearPixels, cached.LastOverlayCopyPixels);
            background.CopyTo(actual.Pixels);
            cached.Draw(request, actual, CancellationToken.None);
            Assert.True(expected.Pixels.Span.SequenceEqual(actual.Pixels.Span), $"{style}, photo {photo}: cache hit differs");
            Assert.Equal(0, cached.LastOverlayClearPixels);
            Assert.Equal(0, cached.LastOverlayCopyPixels);
        }
    }

    [Theory]
    [InlineData("neon")]
    [InlineData("karaoke")]
    [InlineData("typewriter")]
    [InlineData("vhs")]
    [InlineData("gradient")]
    [InlineData("emoji-accent")]
    public async Task CacheMatchesUncachedPixelsAcrossSeeksAndScales(string style)
    {
        using var document = FixtureLoader.ReadJson($"fixtures/captions/layout/{style}-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        var cached = new SkiaCaptionRasterizer();
        var direct = new SkiaCaptionRasterizer { CacheEnabled = false };
        foreach (var scale in new[] { 1.0, 0.25 })
            foreach (var time in track.Pages.SelectMany(page => new[] { page.Start + 0.075, page.End - 0.001, page.Start + 0.2 }).Reverse())
            {
                var request = new CaptionRenderRequest(track, time, Scale: scale);
                var expected = await direct.RenderAsync(request, CancellationToken.None);
                var first = await cached.RenderAsync(request, CancellationToken.None);
                var second = await cached.RenderAsync(request, CancellationToken.None);
                Assert.Equal(expected.Pixels.ToArray(), first.Pixels.ToArray());
                Assert.Equal(expected.Pixels.ToArray(), second.Pixels.ToArray());
                Assert.InRange(cached.CachedBytes, 0, 64L * 1024 * 1024);
            }
    }

    [Fact]
    public async Task EaseOutBackExitKeepsStableInkAndMotionCachesIndependent()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/layout/neon-portrait-en.json");
        using var patch = JsonDocument.Parse("""{"animation":{"pageOut":{"type":"fade","durationSec":0.2,"easing":"easeOutBack"}}}""");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"), patch.RootElement);
        Assert.False(track.OverridesRejected);
        var direct = new SkiaCaptionRasterizer { CacheEnabled = false };
        var cached = new SkiaCaptionRasterizer();
        foreach (var time in new[] { track.Pages[0].Start + 0.65, track.Pages[0].Start + 0.075 })
        {
            var request = new CaptionRenderRequest(track, time);
            var expected = await direct.RenderAsync(request, CancellationToken.None);
            Assert.True(CaptionFixtureSupport.Crop(expected).W > 1);
            await cached.RenderAsync(request with { ReduceMotion = true }, CancellationToken.None);
            var actual = await cached.RenderAsync(request, CancellationToken.None);
            Assert.Equal(expected.Pixels.ToArray(), actual.Pixels.ToArray());
        }
    }

    [Fact]
    public async Task FailedPageDrawRestoresReusedCanvas()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/layout/neon-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        var page = track.Pages[0];
        var broken = track with { Pages = track.Pages.Select(item => item == page ? item with { Emoji = new(page.Words[0], "fffff", page.Block.X, page.Block.Y, 128) } : item).ToArray() };
        var request = new CaptionRenderRequest(track, page.Start + 0.075);
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
        var expected = await new SkiaCaptionRasterizer { CacheEnabled = false }.RenderAsync(request, CancellationToken.None);
        var target = new PixelBuffer(new byte[expected.Pixels.Length], expected.Width, expected.Height, expected.Stride);
        rasterizer.Draw(request, target, CancellationToken.None);
        Assert.Throws<InvalidDataException>(() => rasterizer.Draw(request with { Track = broken }, target, CancellationToken.None));
        target.Pixels.Span.Clear();
        rasterizer.Draw(request, target, CancellationToken.None);
        Assert.Equal(expected.Pixels.ToArray(), target.Pixels.ToArray());
    }

    [Fact]
    public async Task CancelledPageDrawRestoresReusedCanvas()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/layout/neon-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        using var cancellation = new CancellationTokenSource();
        var cancelled = track with { Style = track.Style with { Shadows = new CancellingShadows(track.Style.Shadows, cancellation) } };
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.075);
        var expected = await new SkiaCaptionRasterizer { CacheEnabled = false }.RenderAsync(request, CancellationToken.None);
        var target = new PixelBuffer(new byte[expected.Pixels.Length], expected.Width, expected.Height, expected.Stride);
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
        rasterizer.Draw(request, target, CancellationToken.None);
        Assert.False(cancellation.IsCancellationRequested);
        Assert.ThrowsAny<OperationCanceledException>(() => rasterizer.Draw(request with { Track = cancelled }, target, cancellation.Token));
        target.Pixels.Span.Clear();
        rasterizer.Draw(request, target, CancellationToken.None);
        Assert.Equal(expected.Pixels.ToArray(), target.Pixels.ToArray());
    }

    private sealed class CancellingShadows(IReadOnlyList<CaptionShadow> shadows, CancellationTokenSource cancellation) : IReadOnlyList<CaptionShadow>
    {
        public int Count => shadows.Count;
        public CaptionShadow this[int index] { get { cancellation.Cancel(); return shadows[index]; } }
        public IEnumerator<CaptionShadow> GetEnumerator() => shadows.GetEnumerator();
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    }

    [Fact]
    public async Task GradientShadersAreBoundedReusedAndDisposedOnEviction()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/layout/gradient-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
        var target = new PixelBuffer(new byte[1080 * 1920 * 4], 1080, 1920, 1080 * 4);
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.65);
        rasterizer.Draw(request, target, CancellationToken.None);
        var firstCount = rasterizer.GradientShaderCount;
        var oldest = Assert.IsType<SkiaSharp.SKShader>(rasterizer.OldestGradientShader);
        rasterizer.Draw(request with { Track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input")) }, target, CancellationToken.None);
        Assert.Equal(firstCount, rasterizer.GradientShaderCount);
        var fill = Assert.IsType<LinearPaint>(track.Style.Fill);
        for (var angle = 1; angle <= 80; angle++)
        {
            var changed = track with { Style = track.Style with { Fill = fill with { AngleDeg = fill.AngleDeg + angle } } };
            rasterizer.Draw(request with { Track = changed }, target, CancellationToken.None);
            Assert.InRange(rasterizer.GradientShaderCount, 1, 32);
        }
        Assert.Equal(IntPtr.Zero, oldest.Handle);
        Assert.Equal(32, rasterizer.GradientShaderCount);
    }

    [Fact]
    public async Task SharedShadowMasksMatchIndependentRasterization()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/layout/neon-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        var shared = new SkiaCaptionRasterizer { CacheEnabled = false };
        var independent = new SkiaCaptionRasterizer { CacheEnabled = false, ShareShadowMasks = false, PrecolorShadows = false };
        foreach (var scale in new[] { 1.0, 0.37 })
            foreach (var page in track.Pages)
                foreach (var time in new[] { page.Start + 0.075, page.Start + 0.65, page.End - 0.001 })
                {
                    var request = new CaptionRenderRequest(track, time, Scale: scale);
                    var expected = await independent.RenderAsync(request, CancellationToken.None);
                    var actual = await shared.RenderAsync(request, CancellationToken.None);
                    Assert.True(expected.Pixels.Span.SequenceEqual(actual.Pixels.Span), $"Page {page.Index}, time {time}, scale {scale}: shared mask differs");
                    Assert.Equal(1, shared.LastShadowMaskCount);
                    Assert.Equal(3, independent.LastShadowMaskCount);
                    for (var offset = 0; offset < expected.Pixels.Length; offset += 4)
                    {
                        expected.Pixels.Span[offset] = 13;
                        expected.Pixels.Span[offset + 1] = 37;
                        expected.Pixels.Span[offset + 2] = 91;
                        expected.Pixels.Span[offset + 3] = (offset & 4) == 0 ? (byte)128 : (byte)255;
                    }
                    expected.Pixels.CopyTo(actual.Pixels);
                    independent.Draw(request, expected, CancellationToken.None);
                    shared.Draw(request, actual, CancellationToken.None);
                    Assert.True(expected.Pixels.Span.SequenceEqual(actual.Pixels.Span), $"Page {page.Index}, time {time}, scale {scale}: precolored shadows differ over existing pixels");
                }
    }

    [Fact]
    public void VectorQuantizationMatchesIntegerDivisionAtEveryBoundary()
    {
        foreach (var size in new[] { 2, 3, 7, 31, 128, 129, 255, 256, 257, 511, 1024, 32767, 65535, 65536 })
        {
            var sums = Enumerable.Range(0, 256).SelectMany(value => new[] { -1, 0, 1 }
                .Select(delta => Math.Clamp(value * size - size / 2 + delta, 0, 255 * size))).ToArray();
            var output = new byte[sums.Length];
            CaptionBlurBuffers.Quantize(sums, output, size);
            for (var index = 0; index < sums.Length; index++) Assert.Equal((byte)((sums[index] + size / 2) / size), output[index]);
        }
    }

    [Fact]
    public void SeparableBlurMatchesScalarReferenceIncludingEdges()
    {
        var random = new Random(173);
        var blur = new CaptionBlurBuffers();
        foreach (var width in new[] { 1, 2, 13, 37, 73, 257 })
            foreach (var height in new[] { 1, 3, 19 })
                foreach (var sigma in new[] { 0.0, 0.5, 1.9, 2, 4, 35, 70 })
                {
                    var source = new byte[width * height];
                    random.NextBytes(source);
                    var actual = source.ToArray();
                    blur.Apply(actual, width, height, sigma, CancellationToken.None);
                    Assert.Equal(Reference(source, width, height, sigma), actual);
                }
    }

    private static byte[] Reference(byte[] source, int width, int height, double sigma)
    {
        if (sigma == 0) return source;
        var kernel = sigma < 2 ? CaptionBlur.Kernel(sigma) : null;
        var windows = sigma < 2 ? new[] { (Low: 0, High: 0) } : CaptionBlur.Boxes(sigma);
        for (var axis = 0; axis < 2; axis++)
            foreach (var window in windows)
            {
                var target = new byte[source.Length];
                for (var row = 0; row < height; row++)
                    for (var column = 0; column < width; column++)
                    {
                        var total = 0.0;
                        var low = kernel is null ? window.Low : -kernel.Length / 2;
                        var high = kernel is null ? window.High : kernel.Length / 2;
                        for (var offset = low; offset <= high; offset++)
                        {
                            var inputX = axis == 0 ? column + offset : column;
                            var inputY = axis == 0 ? row : row + offset;
                            if ((uint)inputX < (uint)width && (uint)inputY < (uint)height)
                                total += source[inputY * width + inputX] * (kernel is null ? 1 : kernel[offset - low]);
                        }
                        target[row * width + column] = (byte)CaptionMath.RoundHalfUp(kernel is null ? total / (high - low + 1) : total);
                    }
                source = target;
            }
        return source;
    }
}
