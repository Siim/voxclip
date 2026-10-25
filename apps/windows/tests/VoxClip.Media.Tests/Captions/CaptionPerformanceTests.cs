using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Media.Captions;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.Captions;

[CollectionDefinition("Caption budgets", DisableParallelization = true)]
public sealed class CaptionBudgetCollection;

[Trait("Category", "Captions")]
[Collection("Caption budgets")]
public sealed class CaptionPerformanceTests(ITestOutputHelper output)
{
    [Fact]
    public async Task OptInFrameAllocationsIncludeUncachedAnimatedAndRotatingTargets()
    {
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_ALLOCATION_TESTS") == "1", "Set VOXCLIP_ALLOCATION_TESTS=1 for caption allocation budgets.");
        var failures = new List<string>();
        foreach (var style in Styles())
        {
            var track = await Track(style);
            var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
            var targets = Enumerable.Range(0, 8).Select(_ => Target()).ToArray();
            var requests = Requests(track);
            foreach (var animated in new[] { false, true })
            {
                var frames = requests.Where(request => rasterizer.IsAnimating(request) == animated).ToArray();
                if (frames.Length == 0) continue;
                for (var warmup = 0; warmup < 3; warmup++)
                    for (var index = 0; index < frames.Length; index++) rasterizer.Draw(frames[index], targets[index % 8], CancellationToken.None);
                var beforeAll = GC.GetTotalAllocatedBytes(true);
                var before = GC.GetAllocatedBytesForCurrentThread();
                for (var repeat = 0; repeat < 3; repeat++)
                    for (var index = 0; index < frames.Length; index++) rasterizer.Draw(frames[index], targets[index % 8], CancellationToken.None);
                var mainBytes = (GC.GetAllocatedBytesForCurrentThread() - before) / (3.0 * frames.Length);
                var allBytes = (GC.GetTotalAllocatedBytes(true) - beforeAll) / (3.0 * frames.Length);
                output.WriteLine($"ALLOC {style} {(animated ? "animated" : "stable")}: main {mainBytes:F1} B/frame; all threads {allBytes:F1} B/frame; targets 8; frames {frames.Length}");
                if (mainBytes > 128 || allBytes > 128) failures.Add($"{style} {(animated ? "animated" : "stable")}: {mainBytes:F1}/{allBytes:F1} B/frame");
            }
        }
        Assert.Empty(failures);
    }

    [Fact]
    public async Task OptInReleaseFrameBudgets()
    {
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_PERF_TESTS") == "1", "Set VOXCLIP_PERF_TESTS=1 for caption frame budgets.");
        var load = OneMinuteLoad();
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_PERF_FORCE") == "1" || load is { } measured && measured < 2,
            $"Caption performance requires one-minute load below 2 (measured {load?.ToString("F2") ?? "unavailable"}).");
        output.WriteLine($"PERF one-minute load {load?.ToString("F2") ?? "unavailable"}");
        var failures = new List<string>();
        foreach (var style in Styles())
        {
            var track = await Track(style);
            var target = Target();
            var rasterizer = new SkiaCaptionRasterizer { CacheEnabled = false };
            var requests = Requests(track);
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            var animated = requests.Select(rasterizer.IsAnimating).ToArray();
            for (var warmup = 0; warmup < 3; warmup++)
                foreach (var request in requests) { target.Pixels.Span.Clear(); rasterizer.Draw(request, target, CancellationToken.None); }
            var bandRequests = requests.Where((_, index) => !animated[index]).ToArray();
            var cold = new SkiaCaptionRasterizer();
            foreach (var request in bandRequests)
            {
                cold.ClearPageCache();
                target.Pixels.Span.Clear();
                cold.Draw(request, target, CancellationToken.None);
            }
            var best = new Dictionary<string, double>(StringComparer.Ordinal);
            for (var repeat = 0; repeat < 3; repeat++)
            {
                var stableTimes = new List<double>();
                var animatedTimes = new List<double>();
                var allTimes = new List<double>();
                var missTimes = new List<double>();
                var pageFirstTimes = new List<double>();
                var fresh = track with { };
                foreach (var page in fresh.Pages)
                {
                    target.Pixels.Span.Clear();
                    var started = Stopwatch.GetTimestamp();
                    rasterizer.Draw(new(fresh, Math.Ceiling(page.Start * 30) / 30), target, CancellationToken.None);
                    pageFirstTimes.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
                }
                for (var index = 0; index < requests.Length; index++)
                {
                    target.Pixels.Span.Clear();
                    var started = Stopwatch.GetTimestamp();
                    rasterizer.Draw(requests[index], target, CancellationToken.None);
                    var elapsed = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
                    (animated[index] ? animatedTimes : stableTimes).Add(elapsed);
                    allTimes.Add(elapsed);
                }
                foreach (var request in bandRequests)
                {
                    cold.ClearPageCache();
                    target.Pixels.Span.Clear();
                    var started = Stopwatch.GetTimestamp();
                    cold.Draw(request, target, CancellationToken.None);
                    missTimes.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
                }
                foreach (var (kind, times) in new[] { ("all", allTimes), ("stable", stableTimes), ("animated", animatedTimes), ("band-miss", missTimes), ("page-first", pageFirstTimes) })
                {
                    if (times.Count == 0) continue;
                    times.Sort();
                    var p95 = times[(int)Math.Ceiling(times.Count * 0.95) - 1];
                    best[kind] = best.TryGetValue(kind, out var previous) ? Math.Min(previous, p95) : p95;
                }
            }
            foreach (var (kind, p95) in best)
            {
                output.WriteLine(FormattableString.Invariant($"PERF {style} {kind}: best-of-3 p95 {p95:F3} ms; frames {requests.Length}; pages {track.Pages.Count}"));
                var budget = kind == "page-first" ? 7.5 : 3.0;
                if (p95 > budget) failures.Add($"{style} {kind}: p95 {p95:F3} ms > {budget:F1} ms");
            }
        }
        Assert.Empty(failures);
    }

    private static IEnumerable<string> Styles() => Directory.EnumerateFiles(Path.Combine(FixtureLoader.SharedRoot, "caption-styles", "styles"), "*.json")
        .Select(path => Path.GetFileNameWithoutExtension(path)).Order(StringComparer.Ordinal);

    [DllImport("libc", EntryPoint = "getloadavg")]
    private static extern int GetLoadAverage([Out] double[] values, int count);

    private static double? OneMinuteLoad()
    {
        if (OperatingSystem.IsWindows()) return null;
        var values = new double[1];
        return GetLoadAverage(values, values.Length) == 1 ? values[0] : null;
    }

    private static PixelBuffer Target() => new(new byte[1080 * 1920 * 4], 1080, 1920, 1080 * 4);

    private static CaptionRenderRequest[] Requests(CaptionTrack track) => track.Pages.SelectMany(page =>
        Enumerable.Range((int)Math.Ceiling(page.Start * 30), (int)Math.Ceiling(page.End * 30) - (int)Math.Ceiling(page.Start * 30))
            .Select(frame => new CaptionRenderRequest(track, frame / 30.0))).ToArray();

    private static async Task<CaptionTrack> Track(string style)
    {
        using var document = FixtureLoader.ReadJson($"fixtures/captions/layout/{style}-portrait-en.json");
        return await CaptionFixtureSupport.Build(document.RootElement.GetProperty("input"));
    }
}
