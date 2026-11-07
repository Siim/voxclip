using System.Text.Json;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>The social-loudness true-peak limiter (ADR-R47, amended 2026-11-08) replayed from
/// shared/fixtures/loudness/social-limiter-cases.json, which tools/fixtures/loudness/generate_social_loudness.py writes and Mac
/// Core SocialLimiterReplayTests replays.</summary>
public sealed class SocialLimiterReplayTests
{
    private static JsonElement Document() => FixtureLoader.ReadJson("fixtures/loudness/social-limiter-cases.json").RootElement.Clone();
    private static JsonElement[] Cases(string kind) =>
        Document().GetProperty("cases").EnumerateArray().Where(item => item.GetProperty("kind").GetString() == kind).ToArray();
    private static double? Optional(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetDouble();

    private static void Near(JsonElement expected, double? actual, string where, double tolerance = 1e-6)
    {
        if (Optional(expected) is not { } wanted) { Assert.True(actual is null, $"{where}: expected null, got {actual}"); return; }
        Assert.True(actual is { } value && Math.Abs(wanted - value) < tolerance, $"{where}: {wanted} vs {actual}");
    }

    // Every probe: [frame, reductionDb, left, right]; the reduction is read back from the output over the gained input.
    private static void CheckProbes(JsonElement item, float[] input, float[] output, double gainDb)
    {
        var id = item.GetProperty("id").GetString();
        var gain = Math.Pow(10, gainDb / 20);
        foreach (var probe in item.GetProperty("probes").EnumerateArray())
        {
            var values = probe.EnumerateArray().ToArray();
            var frame = values[0].GetInt32();
            Assert.True(Math.Abs(output[2 * frame] - values[2].GetDouble()) < 2e-6, $"{id} left @{frame}");
            Assert.True(Math.Abs(output[2 * frame + 1] - values[3].GetDouble()) < 2e-6, $"{id} right @{frame}");
            var source = input[2 * frame] * gain;
            if (Math.Abs(source) > 1e-3)
            {
                var reduction = -20 * Math.Log10(output[2 * frame] / source);
                Assert.True(Math.Abs(reduction - values[1].GetDouble()) < 1e-4, $"{id} reduction @{frame}: {reduction}");
            }
        }
    }

    [Fact]
    public void TheFileHasItsKeysCountsAndTheMacsConstants()
    {
        var document = Document();
        Assert.Equal(["format", "description", "constants", "caseCount", "counts", "cases"], document.EnumerateObject().Select(property => property.Name));
        Assert.Equal("voxclip-social-limiter-cases/1", document.GetProperty("format").GetString());
        Assert.Equal(7, document.GetProperty("caseCount").GetInt32());
        Assert.Equal(7, document.GetProperty("cases").GetArrayLength());
        Assert.Equal((6, 1), (document.GetProperty("counts").GetProperty("export").GetInt32(), document.GetProperty("counts").GetProperty("envelope").GetInt32()));
        var constants = document.GetProperty("constants");
        Assert.Equal(["targetLufs", "ceilingDbtp", "maximumReductionDb", "lookaheadSeconds", "lookaheadFrames", "releaseSeconds", "releaseFloorDb",
            "detectionTaps", "landingToleranceLu"], constants.EnumerateObject().Select(property => property.Name));
        Assert.Equal((SocialLoudness.TargetLufs, SocialLoudness.CeilingDbtp, SocialLoudness.MaximumReductionDb, SocialLimiter.LookaheadSeconds, 240.0),
            (constants.GetProperty("targetLufs").GetDouble(), constants.GetProperty("ceilingDbtp").GetDouble(),
             constants.GetProperty("maximumReductionDb").GetDouble(), constants.GetProperty("lookaheadSeconds").GetDouble(),
             constants.GetProperty("lookaheadFrames").GetDouble()));
        Assert.Equal((SocialLimiter.ReleaseSeconds, SocialLimiter.ReleaseFloorDb, (double)SocialLimiter.DetectionTaps, SocialLoudness.LandingToleranceLu),
            (constants.GetProperty("releaseSeconds").GetDouble(), constants.GetProperty("releaseFloorDb").GetDouble(),
             constants.GetProperty("detectionTaps").GetDouble(), constants.GetProperty("landingToleranceLu").GetDouble()));
        Assert.Equal(240 + 11, new SocialLimiter(0, true, 48_000, 2).Latency);
    }

    [Fact]
    public void ExportCasesPlanLandAndOutputTheirSamples()
    {
        var cases = Cases("export");
        Assert.Equal(6, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var samples = SocialLoudnessVectors.Interleaved(item);
            Assert.Equal(2 * item.GetProperty("frames").GetInt32(), samples.Length);
            var run = SocialLoudnessVectors.Export(samples);
            var expected = item.GetProperty("expected");
            Assert.Equal(samples.Length, run.Output.Length);
            Near(expected.GetProperty("measuredLufs"), run.Report.MeasuredLufs, id + " measured");
            var plan = expected.GetProperty("plan");
            Near(plan.GetProperty("gainDb"), run.Plan.GainDb, id + " plan gain");
            Assert.Equal(plan.GetProperty("limit").GetString(), SocialLoudnessReplayTests.Wire(run.Plan.Limit));
            Assert.Equal(plan.GetProperty("limiting").GetBoolean(), run.Plan.Limiting);
            var trials = expected.GetProperty("trials").EnumerateArray().ToArray();
            Assert.Equal(trials.Length, run.Trials.Count);
            for (var index = 0; index < trials.Length; index++)
            {
                Near(trials[index][0], run.Trials[index].GainDb, $"{id} trial {index} gain");
                Near(trials[index][1], run.Trials[index].Lufs, $"{id} trial {index} lufs");
            }
            Near(expected.GetProperty("gainDb"), run.Report.GainDb, id + " gain");
            Assert.Equal(expected.GetProperty("limit").GetString(), SocialLoudnessReplayTests.Wire(run.Decision.Limit));
            Assert.Equal(expected.GetProperty("capped").GetBoolean(), run.Report.Capped);
            Assert.Equal(expected.GetProperty("limiting").GetBoolean(), run.Decision.Limiting);
            Near(expected.GetProperty("outputLufs"), run.Report.OutputLufs, id + " output");
            Near(expected.GetProperty("outputTruePeakDbtp"), run.Report.TruePeakDbtp, id + " output peak");
            Near(expected.GetProperty("limiterMaxReductionDb"), run.Report.LimiterMaxReductionDb, id + " reduction");
            Assert.InRange(run.Limiter.LimitedFrames, expected.GetProperty("limitedFrames").GetInt64() - 2, expected.GetProperty("limitedFrames").GetInt64() + 2);
            Near(expected.GetProperty("limitedPercent"), run.Report.LimitedPercent, id + " limited share", 0.01);
            if (run.Report.TruePeakDbtp is { } peak) Assert.True(peak <= SocialLoudness.CeilingDbtp + 1e-6, $"{id} ceiling {peak}");
            if (run.Decision.Limit == SocialLoudnessLimit.None && run.Report.OutputLufs is { } lufs)
                Assert.InRange(lufs, SocialLoudness.TargetLufs - 0.5, SocialLoudness.TargetLufs + 0.5);
            CheckProbes(item, samples, run.Output, run.Decision.GainDb);
        }
    }

    [Fact]
    public void GainAloneLeavesEverySampleAtSampleTimesGainWithNoLatency()
    {
        var item = Cases("export").Single(value => value.GetProperty("id").GetString() == "talk-pure-gain");
        var samples = SocialLoudnessVectors.Interleaved(item);
        var run = SocialLoudnessVectors.Export(samples);
        Assert.False(run.Decision.Limiting);
        Assert.Equal((0, 0L), (run.Limiter.Latency, run.Limiter.LimitedFrames));
        var gain = Math.Pow(10, run.Decision.GainDb / 20);
        for (var index = 0; index < samples.Length; index++) Assert.Equal((float)(samples[index] * gain), run.Output[index]);
    }

    [Fact]
    public void TheEnvelopeAttacksBeforeTheClickHoldsOverItsDetectionAndReleases()
    {
        var item = Assert.Single(Cases("envelope"));
        var id = item.GetProperty("id").GetString();
        var samples = SocialLoudnessVectors.Interleaved(item);
        var gainDb = item.GetProperty("gainDb").GetDouble();
        var limiter = new SocialLimiter(gainDb, true, 48_000, 2);
        var output = SocialLoudnessVectors.Stream(samples, limiter);
        var expected = item.GetProperty("expected");
        Assert.Equal(samples.Length, output.Length);
        Near(expected.GetProperty("outputTruePeakDbtp"), SocialLoudnessVectors.Measure(output).TruePeakDbtp, id + " peak");
        Near(expected.GetProperty("limiterMaxReductionDb"), limiter.MaximumReductionDb, id + " reduction");
        Assert.InRange(limiter.LimitedFrames, expected.GetProperty("limitedFrames").GetInt64() - 2, expected.GetProperty("limitedFrames").GetInt64() + 2);
        CheckProbes(item, samples, output, gainDb);
    }

    [Fact]
    public void InvalidParametersThrowAndFramesFarFromAPeakPassWithTheGainAlone()
    {
        Assert.Throws<VoiceLabAudioMathException>(() => new SocialLimiter(double.NaN, true, 48_000, 2));
        Assert.Throws<VoiceLabAudioMathException>(() => new SocialLimiter(0, true, 96_000, 2));
        // A quiet tone with one loud frame in the middle: only the frames within the lookahead before it and the release after
        // it change.
        var samples = Enumerable.Range(0, 9600).SelectMany(index => { var value = (float)(0.1 * Math.Sin(index * 0.05)); return new[] { value, value }; }).ToArray();
        samples[2 * 4800] = 1.5f;
        var limiter = new SocialLimiter(0, true, 48_000, 2);
        var output = SocialLoudnessVectors.Stream(samples, limiter);
        var first = Enumerable.Range(0, output.Length).First(index => output[index] != samples[index]) / 2;
        Assert.InRange(first, 4800 - 251, 4799);
        Assert.True(output.AsSpan(0, 2 * (4800 - 251)).SequenceEqual(samples.AsSpan(0, 2 * (4800 - 251))));
        Assert.True(Math.Abs(limiter.MaximumReductionDb - (20 * Math.Log10(1.5) + 1)) < 0.5);
    }
}
