using System.Text.Json;
using VoxClip.Core.Domain.Loudness;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinRender;

/// <summary>Social loudness (ADR-R47) replayed from shared/fixtures/loudness/social-loudness-cases.json, which
/// tools/fixtures/loudness/generate_social_loudness.py writes and Mac Core SocialLoudnessReplayTests replays.</summary>
public sealed class SocialLoudnessReplayTests
{
    private static JsonElement Document() => FixtureLoader.ReadJson("fixtures/loudness/social-loudness-cases.json").RootElement.Clone();
    private static JsonElement[] Cases(string kind) =>
        Document().GetProperty("cases").EnumerateArray().Where(item => item.GetProperty("kind").GetString() == kind).ToArray();
    private static double? Optional(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetDouble();

    private static void Near(JsonElement expected, double? actual, string where)
    {
        if (Optional(expected) is not { } wanted) { Assert.True(actual is null, $"{where}: expected null, got {actual}"); return; }
        Assert.True(actual is { } value && Math.Abs(wanted - value) < 1e-6, $"{where}: {wanted} vs {actual}");
    }

    [Fact]
    public void TheFileHasItsKeysCountsAndTheMacsConstants()
    {
        var document = Document();
        Assert.Equal(["format", "description", "constants", "caseCount", "counts", "cases"], document.EnumerateObject().Select(property => property.Name));
        Assert.Equal("voxclip-social-loudness-cases/1", document.GetProperty("format").GetString());
        Assert.Equal(24, document.GetProperty("caseCount").GetInt32());
        Assert.Equal(24, document.GetProperty("cases").GetArrayLength());
        Assert.Equal((12, 12), (document.GetProperty("counts").GetProperty("rule").GetInt32(), document.GetProperty("counts").GetProperty("signal").GetInt32()));
        var constants = document.GetProperty("constants");
        Assert.Equal(["targetLufs", "ceilingDbtp", "maximumBoostDb", "maximumCutDb", "absoluteGateLufs", "relativeGateLu", "blockSeconds", "stepSeconds"],
            constants.EnumerateObject().Select(property => property.Name));
        Assert.Equal((SocialLoudness.TargetLufs, SocialLoudness.CeilingDbtp, SocialLoudness.MaximumBoostDb, SocialLoudness.MaximumCutDb),
            (constants.GetProperty("targetLufs").GetDouble(), constants.GetProperty("ceilingDbtp").GetDouble(),
             constants.GetProperty("maximumBoostDb").GetDouble(), constants.GetProperty("maximumCutDb").GetDouble()));
        Assert.Equal((SocialLoudness.AbsoluteGateLufs, SocialLoudness.RelativeGateLu, SocialLoudness.StepSeconds * SocialLoudness.BlockSteps, SocialLoudness.StepSeconds),
            (constants.GetProperty("absoluteGateLufs").GetDouble(), constants.GetProperty("relativeGateLu").GetDouble(),
             constants.GetProperty("blockSeconds").GetDouble(), constants.GetProperty("stepSeconds").GetDouble()));
    }

    [Fact]
    public void TheRuleTargetLimitsCapAndSilence()
    {
        var cases = Cases("rule");
        Assert.Equal(12, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var decision = SocialLoudness.Decide(Optional(item.GetProperty("measuredLufs")), Optional(item.GetProperty("truePeakDbtp")));
            var expected = item.GetProperty("expected");
            Near(expected.GetProperty("gainDb"), decision.GainDb, id + " gain");
            Assert.Equal(expected.GetProperty("limit").GetString(), Wire(decision.Limit));
            Assert.Equal(expected.GetProperty("capped").GetBoolean(), decision.Capped);
        }
    }

    [Fact]
    public void SignalsMeasureGainAndResultStreamedInUnevenChunks()
    {
        var cases = Cases("signal");
        Assert.Equal(12, cases.Length);
        foreach (var item in cases)
        {
            var id = item.GetProperty("id").GetString()!;
            var samples = SocialLoudnessVectors.Interleaved(item);
            Assert.Equal(2 * item.GetProperty("frames").GetInt32(), samples.Length);
            var meter = new SocialLoudnessMeter(48_000, 2);
            // Uneven chunks, so steps and the true-peak history cross every kind of boundary.
            for (int start = 0, chunk = 1; start < samples.Length; chunk = chunk * 7 % 5003 + 1)
            {
                var end = Math.Min(samples.Length, start + 2 * chunk);
                meter.Append(samples.AsSpan(start, end - start));
                start = end;
            }
            var measurement = meter.Finish();
            var (decision, report) = SocialLoudness.Report(measurement);
            var expected = item.GetProperty("expected");
            Near(expected.GetProperty("measuredLufs"), report.MeasuredLufs, id + " measured");
            Near(expected.GetProperty("truePeakDbtp"), measurement.TruePeakDbtp, id + " true peak");
            Near(expected.GetProperty("gainDb"), report.GainDb, id + " gain");
            Assert.Equal(expected.GetProperty("limit").GetString(), Wire(decision.Limit));
            Assert.Equal(expected.GetProperty("capped").GetBoolean(), report.Capped);
            Near(expected.GetProperty("outputLufs"), report.OutputLufs, id + " output");
            Near(expected.GetProperty("outputTruePeakDbtp"), report.TruePeakDbtp, id + " output peak");
        }
    }

    [Fact]
    public void OneAppendAndTheWholeBufferVoiceLabPeakAgreeWithTheStream()
    {
        var item = Cases("signal").Single(value => value.GetProperty("id").GetString() == "speech-clicks-peak-cap");
        var samples = SocialLoudnessVectors.Interleaved(item);
        var meter = new SocialLoudnessMeter(48_000, 2);
        meter.Append(samples);
        var measurement = meter.Finish();
        var left = samples.Where((_, index) => index % 2 == 0).ToArray();
        var right = samples.Where((_, index) => index % 2 == 1).ToArray();
        var peak = Math.Max(VoiceLabLoudness.TruePeakDbtp(left, 48_000), VoiceLabLoudness.TruePeakDbtp(right, 48_000));
        Assert.True(Math.Abs(measurement.TruePeakDbtp!.Value - peak) < 1e-12);
        Near(item.GetProperty("expected").GetProperty("measuredLufs"), measurement.IntegratedLufs(), "whole");
    }

    [Fact]
    public void InvalidInputAndTheLogLine()
    {
        var meter = new SocialLoudnessMeter(48_000, 2);
        Assert.Equal(VoiceLabAudioMathErrorCode.InvalidInput, Assert.Throws<VoiceLabAudioMathException>(() => meter.Append([0f, float.NaN])).Code);
        Assert.Throws<VoiceLabAudioMathException>(() => new SocialLoudnessMeter(96_000, 2));
        Assert.Equal("loudness measured=-20.71 gain=6.71 output=-14.00 truePeak=-3.46 capped=false",
            new SocialLoudnessReport(-20.71, 6.71, -14, -3.456, false).LogLine());
        Assert.Equal("loudness measured=none gain=0.00 output=none truePeak=none capped=false",
            new SocialLoudnessReport(null, 0, null, null, false).LogLine());
        Assert.Equal(0.1f, SocialLoudness.LinearGain(-20));
    }

    private static string Wire(SocialLoudnessLimit limit) => limit switch
    {
        SocialLoudnessLimit.None => "none",
        SocialLoudnessLimit.GainLimit => "gainLimit",
        SocialLoudnessLimit.TruePeak => "truePeak",
        _ => "silent"
    };
}
