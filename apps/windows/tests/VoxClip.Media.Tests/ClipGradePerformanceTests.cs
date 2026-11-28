using System.Diagnostics;
using System.Runtime.InteropServices;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests;

[CollectionDefinition("Grade budgets", DisableParallelization = true)]
public sealed class GradeBudgetCollection;

/// <summary>The Windows grade budget (looks spec 2026-11-28, section 5.10): the grade and the finish with every control on at
/// 1080 × 1920 take at most 6 ms at the 95th percentile, best of three runs, on the reference x64 machine. Opt-in with
/// VOXCLIP_PERF_TESTS=1 on an optimized build and a quiet host, like the caption budgets (captions.md §16.8).</summary>
[Collection("Grade budgets")]
public sealed class ClipGradePerformanceTests(ITestOutputHelper output)
{
    private const double Budget = 6;

    [Fact]
    public void OptInGradeAndFinishBudget()
    {
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_PERF_TESTS") == "1", "Set VOXCLIP_PERF_TESTS=1 for the grade budget.");
        // Windows has no load average; elsewhere the host must be quiet unless the run is a forced diagnostic.
        var load = OneMinuteLoad();
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_PERF_FORCE") == "1" || load is null || load < 2,
            $"The grade budget requires a one-minute load below 2 (measured {load:F2}).");
        output.WriteLine($"PERF one-minute load {load?.ToString("F2") ?? "unavailable"}; {Environment.ProcessorCount} logical processors; {RuntimeInformation.ProcessArchitecture}");
        var library = ClipLookLibrary.Load(FixtureLoader.SharedRoot);
        var look = ClipGradeMediaTests.Basis.WithLook(library.Look("matteFilm")!, 70, new(20, 25, -10));
        var controls = look with { ColorGrade = look.ColorGrade! with { Vibrance = 30, Shadows = 20, Vignette = 40, Grain = 30 } };
        var recipe = ClipGradeRecipe.For(controls);
        Assert.True(recipe is { Primary: not null, Adjustments: not null, Tone: { ShadowsHighlights: not null, Vibrance: not null, Master: not null,
            SplitTone: not null, Fade: not null }, Amount: < 1, Vignette: > 0, Grain: > 0 });
        var source = ClipGradeMediaTests.Gradient(1080, 1920);
        var frame = new PixelBuffer(new byte[source.Pixels.Length], 1080, 1920, 1080 * 4);
        void Render(uint index)
        {
            ClipPicture.Grade(frame, recipe, CancellationToken.None);
            ClipPicture.Finish(frame, recipe, ClipGrain.FrameHash(index), null, CancellationToken.None);
        }
        for (var warmup = 0; warmup < 10; warmup++) { source.Pixels.CopyTo(frame.Pixels); Render((uint)warmup); }
        // Each stage alone, for the report.
        foreach (var (stage, run) in new (string, Action<uint>)[]
        {
            ("grade", _ => ClipPicture.Grade(frame, recipe, CancellationToken.None)),
            ("finish", index => ClipPicture.Finish(frame, recipe, ClipGrain.FrameHash(index), null, CancellationToken.None))
        })
        {
            var stageTimes = new List<double>();
            for (var index = 0; index < 60; index++)
            {
                source.Pixels.CopyTo(frame.Pixels);
                var started = Stopwatch.GetTimestamp();
                run((uint)index);
                stageTimes.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
            }
            stageTimes.Sort();
            output.WriteLine(FormattableString.Invariant($"PERF {stage} alone: median {stageTimes[30]:F3} ms; p95 {stageTimes[56]:F3} ms"));
        }
        var best = double.PositiveInfinity;
        for (var repeat = 0; repeat < 3; repeat++)
        {
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            var times = new List<double>();
            for (var index = 0; index < 60; index++)
            {
                source.Pixels.CopyTo(frame.Pixels);
                var started = Stopwatch.GetTimestamp();
                Render((uint)index);
                times.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
            }
            times.Sort();
            var p95 = times[(int)Math.Ceiling(times.Count * 0.95) - 1];
            output.WriteLine(FormattableString.Invariant($"PERF grade+finish run {repeat + 1}: median {times[times.Count / 2]:F3} ms; p95 {p95:F3} ms"));
            best = Math.Min(best, p95);
        }
        output.WriteLine(FormattableString.Invariant($"PERF grade+finish 1080x1920 every control: best-of-3 p95 {best:F3} ms (budget {Budget:F1} ms)"));
        Assert.True(best <= Budget, FormattableString.Invariant($"grade+finish p95 {best:F3} ms > {Budget:F1} ms"));
    }

    [DllImport("libc", EntryPoint = "getloadavg")]
    private static extern int GetLoadAverage([Out] double[] values, int count);

    private static double? OneMinuteLoad()
    {
        if (OperatingSystem.IsWindows()) return null;
        var values = new double[1];
        return GetLoadAverage(values, values.Length) == 1 ? values[0] : null;
    }
}
