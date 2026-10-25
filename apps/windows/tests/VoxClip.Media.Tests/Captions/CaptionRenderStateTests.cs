using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

[Trait("Category", "Captions")]
[Collection("Caption budgets")]
public sealed class CaptionRenderStateTests(ITestOutputHelper output)
{
    [Fact]
    public void GoldenOutputCannotOverwriteSharedAssets()
    {
        var shared = FixtureLoader.SharedRoot;
        Assert.Throws<InvalidOperationException>(() => CaptionFixtureSupport.ValidateGoldenOutput(shared, shared));
        Assert.Throws<InvalidOperationException>(() => CaptionFixtureSupport.ValidateGoldenOutput(Path.Combine(shared, "fixtures", "captions", "golden"), shared));
        Assert.EndsWith(Path.DirectorySeparatorChar + "voxclip-goldens",
            CaptionFixtureSupport.ValidateGoldenOutput(Path.Combine(Path.GetTempPath(), "voxclip-goldens"), shared));
        if (!OperatingSystem.IsWindows())
        {
            var directory = Directory.CreateTempSubdirectory("voxclip-golden-link-");
            var link = Path.Combine(directory.FullName, "shared");
            try
            {
                Directory.CreateSymbolicLink(link, shared);
                Assert.Throws<InvalidOperationException>(() => CaptionFixtureSupport.ValidateGoldenOutput(Path.Combine(link, "fixtures", "captions", "golden"), shared));
            }
            finally
            {
                Directory.Delete(link);
                directory.Delete();
            }
        }
    }

    [Fact]
    public async Task ShadowScratchStaysFlatAcrossFiftyAndThreeHundredPages()
    {
        var style = CaptionFixtureSupport.Style("neon");
        var words = Enumerable.Range(0, 1200).Select(index => new CaptionWord($"word-{index}", index / 4 % 2 == 0 ? "glow" : "wave", index * 0.4, index * 0.4 + 0.35)).ToArray();
        var track = await CaptionEngine.BuildAsync(new(style, new(style.Id, default, null, new Dictionary<string, CaptionPosition>()), new(1080, 1920), words, "en", 481), new HarfBuzzGlyphShaper(), null, CancellationToken.None);
        Assert.Equal(300, track.Pages.Count);
        var rasterizer = new SkiaCaptionRasterizer();
        var target = Target();
        long fiftyBytes = 0;
        long fiftyGeometryBytes = 0;
        foreach (var page in track.Pages)
        {
            target.Pixels.Span.Clear();
            rasterizer.Draw(new(track, page.Start + 0.95), target, CancellationToken.None);
            if (page.Index == 49) fiftyBytes = rasterizer.RetainedShadowBytes;
            if (page.Index == 49) fiftyGeometryBytes = rasterizer.RetainedGeometryBytes(track);
        }
        output.WriteLine($"SHADOW retained: 50 pages {fiftyBytes} B; 300 pages {rasterizer.RetainedShadowBytes} B; mask BGRA {rasterizer.RetainedMaskColorBytes} B");
        output.WriteLine($"GEOMETRY retained: 50 pages {fiftyGeometryBytes} B; 300 pages {rasterizer.RetainedGeometryBytes(track)} B");
        Assert.True(fiftyBytes > 0);
        Assert.Equal(fiftyBytes, rasterizer.RetainedShadowBytes);
        Assert.True(fiftyGeometryBytes > 0);
        Assert.Equal(fiftyGeometryBytes, rasterizer.RetainedGeometryBytes(track));
        Assert.Equal(8, rasterizer.RetainedGeometryPageCount(track));
        Assert.False(rasterizer.RetainsGeometryPage(track, 0));
        Assert.True(rasterizer.RetainsGeometryPage(track, 299));
        Assert.Equal(0, rasterizer.RetainedMaskColorBytes);
        Assert.InRange(rasterizer.CachedBytes, 1, 64L * 1024 * 1024);
        var small = new CaptionRenderRequest(track, track.Pages[0].Start + 0.075, Scale: 0.25);
        var expected = await new SkiaCaptionRasterizer().RenderAsync(small, CancellationToken.None);
        var actual = await rasterizer.RenderAsync(small, CancellationToken.None);
        Assert.True(expected.Pixels.Span.SequenceEqual(actual.Pixels.Span));
        Assert.Equal(8, rasterizer.RetainedGeometryPageCount(track));
        Assert.True(rasterizer.RetainsGeometryPage(track, 0));
        Assert.False(rasterizer.RetainsGeometryPage(track, 292));
    }

    [Fact]
    public async Task CachedBandsDoNotKeepDroppedTracksAlive()
    {
        using var document = FixtureLoader.ReadJson("fixtures/captions/layout/neon-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
        var rasterizer = new SkiaCaptionRasterizer();
        var dropped = DrawDroppedTrack(rasterizer, track);
        Assert.True(rasterizer.CachedBytes > 0);
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        Assert.False(dropped.IsAlive);
        GC.KeepAlive(rasterizer);
        GC.KeepAlive(track);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static WeakReference DrawDroppedTrack(SkiaCaptionRasterizer rasterizer, CaptionTrack source)
    {
        var dropped = source with { };
        rasterizer.Draw(new(dropped, dropped.Pages[0].Start + 0.65), Target(), CancellationToken.None);
        return new(dropped);
    }

    [Fact]
    public async Task RenderAsyncDoesNotRetainDiscardedFrameArraysOrPins()
    {
        var track = await Track("neon");
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.65);
        var rasterizer = new SkiaCaptionRasterizer();
        var discarded = Enumerable.Range(0, 20).Select(_ => DrawDiscardedFrame(rasterizer, request)).ToArray();
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        Assert.All(discarded, frame => Assert.False(frame.IsAlive));
        Assert.Equal(0, rasterizer.RetainedTargetCount);
        output.WriteLine($"RENDER_ASYNC retained targets {rasterizer.RetainedTargetCount}; live discarded arrays {discarded.Count(frame => frame.IsAlive)}");
        rasterizer.Draw(request, Target(), CancellationToken.None);
        Assert.Equal(1, rasterizer.RetainedTargetCount);
        GC.KeepAlive(rasterizer);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static WeakReference DrawDiscardedFrame(SkiaCaptionRasterizer rasterizer, CaptionRenderRequest request)
    {
        var rendered = rasterizer.RenderAsync(request, CancellationToken.None).GetAwaiter().GetResult();
        Assert.True(MemoryMarshal.TryGetArray((ReadOnlyMemory<byte>)rendered.Pixels, out var storage));
        return new(storage.Array!);
    }

    [Fact]
    public async Task BoundsFailureRestoresCachedHalfScaleTargets()
    {
        var track = await Track("neon");
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.65, Scale: 0.5);
        var rasterizer = new SkiaCaptionRasterizer();
        var target = Target();
        Assert.False(rasterizer.IsAnimating(request));
        rasterizer.TestCheckpoint = point => { if (point == SkiaCaptionRasterizer.RenderCheckpoint.OverlayBounds) throw new InvalidOperationException("Injected bounds failure"); };
        Assert.Throws<InvalidOperationException>(() => rasterizer.Draw(request, target, CancellationToken.None));
        Assert.Equal(1, rasterizer.RetainedTargetCanvasSaveCount);
        rasterizer.TestCheckpoint = null;
        await AssertRecovered(rasterizer, request, target);
        await AssertRecovered(rasterizer, request, Target());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StableBandCancellationRestoresOverlayClip(bool cacheEnabled)
    {
        var track = await Track("neon");
        var narrow = new CaptionRenderRequest(track, track.Pages[4].Start + 0.65);
        var wide = new CaptionRenderRequest(track, track.Pages[1].Start + 0.65);
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = cacheEnabled };
        var target = Target();
        Assert.False(rasterizer.IsAnimating(narrow));
        Assert.False(rasterizer.IsAnimating(wide));
        Assert.True(track.Pages[1].Visual.Width > track.Pages[4].Visual.Width);
        using var cancellation = new CancellationTokenSource();
        rasterizer.TestCheckpoint = point => { if (point == SkiaCaptionRasterizer.RenderCheckpoint.ShadowBlur) cancellation.Cancel(); };
        Assert.ThrowsAny<OperationCanceledException>(() => rasterizer.Draw(narrow, target, cancellation.Token));
        Assert.Equal(1, rasterizer.OverlayCanvasSaveCount);
        rasterizer.TestCheckpoint = null;
        await AssertRecovered(rasterizer, wide, target);
    }

    [Fact]
    public async Task UncachedCompositeFailureRestoresTargetClipAndNextFrame()
    {
        var track = await Track("neon");
        var narrow = new CaptionRenderRequest(track, track.Pages[4].Start + 0.65);
        var wide = new CaptionRenderRequest(track, track.Pages[1].Start + 0.65);
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
        var target = Target();
        Assert.False(rasterizer.IsAnimating(narrow));
        Assert.False(rasterizer.IsAnimating(wide));
        Assert.True(track.Pages[1].Visual.Width > track.Pages[4].Visual.Width);
        rasterizer.TestCheckpoint = point =>
        {
            if (point == SkiaCaptionRasterizer.RenderCheckpoint.OverlayComposite)
                throw new InvalidOperationException("Injected composite failure");
        };
        Assert.Throws<InvalidOperationException>(() => rasterizer.Draw(narrow, target, CancellationToken.None));
        Assert.Equal(1, rasterizer.RetainedTargetCanvasSaveCount);
        Assert.Equal(1, rasterizer.OverlayCanvasSaveCount);
        rasterizer.TestCheckpoint = null;
        await AssertRecovered(rasterizer, wide, target);
        Assert.Equal(1, rasterizer.RetainedTargetCanvasSaveCount);
    }

    [Fact]
    public async Task FailedOverlayImageWrapKeepsPreviousViewsAndRebuildsForNewSize()
    {
        var track = await Track("neon");
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.65);
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
        var portrait = Target();
        rasterizer.Draw(request, portrait, CancellationToken.None);
        var smaller = new PixelBuffer(new byte[720 * 1280 * 4], 720, 1280, 720 * 4);
        var scaled = request with { Scale = 2.0 / 3 };
        var wraps = 0;
        rasterizer.TestCheckpoint = point =>
        {
            if (point == SkiaCaptionRasterizer.RenderCheckpoint.OverlayImageWrap && ++wraps == 1)
                throw new InvalidOperationException("Injected image wrap failure");
        };
        Assert.Throws<InvalidOperationException>(() => rasterizer.Draw(scaled, smaller, CancellationToken.None));
        Assert.Equal(1, wraps);
        Assert.Equal(1, rasterizer.OverlayCanvasSaveCount);
        rasterizer.TestCheckpoint = null;
        await AssertRecovered(rasterizer, request, portrait);
        var expected = new PixelBuffer(new byte[smaller.Pixels.Length], smaller.Width, smaller.Height, smaller.Stride);
        new SkiaCaptionRasterizer { CacheEnabled = false }.Draw(scaled, expected, CancellationToken.None);
        smaller.Pixels.Span.Clear();
        rasterizer.Draw(scaled, smaller, CancellationToken.None);
        Assert.True(expected.Pixels.Span.SequenceEqual(smaller.Pixels.Span));
        Assert.Equal(1, rasterizer.OverlayCanvasSaveCount);
    }

    [Fact]
    public async Task ShadowViewsRecoverAcrossAspectStyleAndTrackSwitches()
    {
        var portrait = await Track("neon");
        using var landscapeFixture = FixtureLoader.ReadJson("fixtures/captions/layout/neon-landscape-en.json");
        var landscape = await CaptionFixtureSupport.Build(landscapeFixture.RootElement.GetProperty("input"));
        var otherStyle = await Track("outline");
        var cases = new[]
        {
            (Track: portrait, Width: 1080, Height: 1920),
            (Track: landscape, Width: 1920, Height: 1080),
            (Track: otherStyle, Width: 1080, Height: 1920)
        };
        var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
        for (var pass = 0; pass < 4; pass++)
        {
            foreach (var item in cases)
            {
                var request = new CaptionRenderRequest(item.Track, item.Track.Pages[0].Start + 0.075);
                var target = new PixelBuffer(new byte[item.Width * item.Height * 4], item.Width, item.Height, item.Width * 4);
                rasterizer.Draw(request, target, CancellationToken.None);
                var expected = new PixelBuffer(new byte[target.Pixels.Length], item.Width, item.Height, item.Width * 4);
                new SkiaCaptionRasterizer { CacheEnabled = false }.Draw(request, expected, CancellationToken.None);
                Assert.True(expected.Pixels.Span.SequenceEqual(target.Pixels.Span), $"Shadow output differed after pass {pass}, {item.Width}x{item.Height}, {item.Track.Style.Id}.");
                Assert.InRange(rasterizer.RetainedShadowBytes, 1, 1920L * 1080 * 4);
            }
        }
    }

    [Fact]
    public async Task StartedBlurFinishesBeforeStartLoopFailureReturns()
    {
        var track = await Track("neon");
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.075);
        var rasterizer = new SkiaCaptionRasterizer();
        var target = Target();
        using var entered = new ManualResetEventSlim();
        var finished = false;
        rasterizer.TestCheckpoint = point =>
        {
            if (point == SkiaCaptionRasterizer.RenderCheckpoint.ShadowBlur)
            {
                entered.Set();
                Thread.Sleep(100);
                Volatile.Write(ref finished, true);
            }
            if (point == SkiaCaptionRasterizer.RenderCheckpoint.ShadowStart)
            {
                Assert.True(entered.Wait(TimeSpan.FromSeconds(5)));
                throw new InvalidOperationException("Injected start failure");
            }
        };
        Assert.Throws<InvalidOperationException>(() => rasterizer.Draw(request, target, CancellationToken.None));
        Assert.True(Volatile.Read(ref finished));
        rasterizer.TestCheckpoint = null;
        await AssertRecovered(rasterizer, request, target);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public async Task PrepareGrowthFailureInvalidatesMaskAndShadowViews(int failAt)
    {
        var track = await Track("neon");
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.075, Scale: 0.25);
        var rasterizer = new SkiaCaptionRasterizer();
        var target = Target();
        rasterizer.Draw(request, target, CancellationToken.None);
        var invalidatedBefore = rasterizer.InvalidatedShadowViewCount;
        var growths = 0;
        rasterizer.TestCheckpoint = point =>
        {
            if (point == SkiaCaptionRasterizer.RenderCheckpoint.ShadowPrepareGrowth && ++growths == failAt) throw new InvalidOperationException("Injected prepare failure");
        };
        Assert.Throws<InvalidOperationException>(() => rasterizer.Draw(request with { Scale = 1 }, target, CancellationToken.None));
        Assert.Equal(failAt, growths);
        Assert.True(rasterizer.InvalidatedShadowViewCount > invalidatedBefore);
        rasterizer.TestCheckpoint = null;
        await AssertRecovered(rasterizer, request, target);
        await AssertRecovered(rasterizer, request with { Scale = 1 }, target);
    }

    [Fact]
    public async Task MidShadowCancellationDoesNotPoisonTheNextFrame()
    {
        var track = await Track("neon");
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.075, Scale: 0.5);
        var rasterizer = new SkiaCaptionRasterizer();
        var target = Target();
        rasterizer.Draw(request, target, CancellationToken.None);
        using var cancellation = new CancellationTokenSource();
        rasterizer.TestCheckpoint = point => { if (point == SkiaCaptionRasterizer.RenderCheckpoint.ShadowBlur) cancellation.Cancel(); };
        Assert.ThrowsAny<OperationCanceledException>(() => rasterizer.Draw(request, target, cancellation.Token));
        Assert.True(cancellation.IsCancellationRequested);
        rasterizer.TestCheckpoint = null;
        await AssertRecovered(rasterizer, request, target);
    }

    [Theory]
    [InlineData("outline", "fade")]
    [InlineData("neon", "fade")]
    [InlineData("karaoke", "fade")]
    [InlineData("bounce", "pop")]
    public async Task EmptyBlurNeverCompositesThePreviousFramesColor(string style, string kind)
    {
        using var patch = JsonDocument.Parse("""{"animation":{"wordIn":{"type":"KIND","fromScale":0,"durationSec":0.2,"easing":"linear"}},"reveal":{"unit":"word"}}""".Replace("KIND", kind, StringComparison.Ordinal));
        using var document = FixtureLoader.ReadJson($"fixtures/captions/layout/{style}-portrait-en.json");
        var track = await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"), patch.RootElement);
        Assert.False(track.OverridesRejected);
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.3);
        var rasterizer = new SkiaCaptionRasterizer();
        var target = Target();
        rasterizer.Draw(request, target, CancellationToken.None);
        await AssertRecovered(rasterizer, request with { Time = track.Pages[0].Start + 0.0001 }, target);
    }

    private static async Task<CaptionTrack> Track(string style)
    {
        using var document = FixtureLoader.ReadJson($"fixtures/captions/layout/{style}-portrait-en.json");
        return await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
    }

    [Fact]
    public async Task SaturatedThreadPoolLetsTheRenderThreadClaimUnstartedBlurs()
    {
        var track = await Track("neon");
        var request = new CaptionRenderRequest(track, track.Pages[0].Start + 0.075, Scale: 0.5);
        var target = Target();
        var serial = new SkiaCaptionRasterizer { QueueShadowBlurs = false };
        var rasterizer = new SkiaCaptionRasterizer();
        for (var warmup = 0; warmup < 3; warmup++)
        {
            serial.Draw(request, target, CancellationToken.None);
            rasterizer.Draw(request, target, CancellationToken.None);
        }
        target.Pixels.Span.Clear();
        var timer = Stopwatch.StartNew();
        serial.Draw(request, target, CancellationToken.None);
        var serialMs = timer.Elapsed.TotalMilliseconds;
        var expected = target.Pixels.ToArray();
        ThreadPool.GetMinThreads(out var oldMinimum, out var minimumIo);
        ThreadPool.GetMaxThreads(out var oldMaximum, out var maximumIo);
        using var release = new ManualResetEventSlim();
        using var frameFinished = new ManualResetEventSlim();
        var maximum = Math.Max(ThreadPool.ThreadCount + 2, oldMinimum);
        Assert.True(ThreadPool.SetMinThreads(maximum, minimumIo));
        Assert.True(ThreadPool.SetMaxThreads(maximum, maximumIo));
        ThreadPool.GetAvailableThreads(out var available, out _);
        using var blocked = new CountdownEvent(available);
        using var drained = new CountdownEvent(available);
        var timedOut = false;
        var watchdog = new Thread(() =>
        {
            if (!frameFinished.Wait(TimeSpan.FromSeconds(5))) { timedOut = true; release.Set(); }
        });
        watchdog.Start();
        double saturatedMs = 0;
        try
        {
            for (var index = 0; index < available; index++)
                ThreadPool.UnsafeQueueUserWorkItem(_ =>
                {
                    blocked.Signal();
                    release.Wait();
                    drained.Signal();
                }, (object?)null, preferLocal: false);
            Assert.True(blocked.Wait(TimeSpan.FromSeconds(3), TestContext.Current.CancellationToken), "Blocking work items did not occupy the available workers.");
            target.Pixels.Span.Clear();
            timer.Restart();
            rasterizer.Draw(request, target, CancellationToken.None);
            saturatedMs = timer.Elapsed.TotalMilliseconds;
            frameFinished.Set();
            Assert.False(timedOut, "The frame waited for queued ThreadPool work.");
            Assert.InRange(saturatedMs, 0, Math.Max(100, serialMs * 10));
            Assert.True(expected.AsSpan().SequenceEqual(target.Pixels.Span));
        }
        finally
        {
            release.Set();
            frameFinished.Set();
            watchdog.Join();
            try { Assert.True(drained.Wait(TimeSpan.FromSeconds(5), CancellationToken.None), "Blocking work items were not drained."); }
            finally
            {
                Assert.True(ThreadPool.SetMaxThreads(oldMaximum, maximumIo));
                Assert.True(ThreadPool.SetMinThreads(oldMinimum, minimumIo));
            }
        }
        output.WriteLine($"SATURATION serial {serialMs:F3} ms; blocked pool {saturatedMs:F3} ms; blocking work items {available}");
    }

    private static async Task AssertRecovered(SkiaCaptionRasterizer rasterizer, CaptionRenderRequest request, PixelBuffer target)
    {
        var expected = Target();
        new SkiaCaptionRasterizer().Draw(request, expected, CancellationToken.None);
        target.Pixels.Span.Clear();
        rasterizer.Draw(request, target, CancellationToken.None);
        Assert.True(expected.Pixels.Span.SequenceEqual(target.Pixels.Span));
        await Task.CompletedTask;
    }

    private static PixelBuffer Target() => new(new byte[1080 * 1920 * 4], 1080, 1920, 1080 * 4);
}
