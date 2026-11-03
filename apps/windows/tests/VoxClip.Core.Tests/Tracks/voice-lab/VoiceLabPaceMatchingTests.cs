using System.Text.Json.Nodes;
using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabPaceMatchingTests
{
    [Theory]
    [InlineData(double.NaN, 1)]
    [InlineData(double.PositiveInfinity, 1)]
    [InlineData(0, 1)]
    [InlineData(-1, 1)]
    [InlineData(1, double.NaN)]
    [InlineData(1, 0.69)]
    [InlineData(1, 1.21)]
    public void InvalidMeasuredInputsAreRefusedBeforeAnyQuote(double seconds, double oldPace) =>
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabPaceMatching.Match(seconds, Window(5.12), .05, .05, 48_000, oldPace));

    private static VoiceLabWindow Window(double seconds, VoiceLabSeamKind kind = VoiceLabSeamKind.Gap)
    {
        var start = kind == VoiceLabSeamKind.None ? 0L : 480_000L;
        var end = start + (long)EditingMath.Round(seconds * 48_000);
        return new("w", "w", [], [], start / 48_000.0, end / 48_000.0, start, end,
            new(kind, start / 48_000.0, start, 240), new(kind, end / 48_000.0, end, 240));
    }

    [Fact]
    public void SharedSampleExactPaidPhrasesPreferKeepingSource()
    {
        var fixture = JsonNode.Parse(File.ReadAllBytes(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "voice-lab", "pace-matching-cases.json")))!;
        Assert.Equal("voxclip-pace-matching/1", fixture["schema"]!.GetValue<string>());
        Assert.Equal(3, fixture["caseCount"]!.GetValue<int>());
        Assert.Equal(3, fixture["cases"]!.AsArray().Count);
        var sampleRate = fixture["sourceSampleRate"]!.GetValue<int>();
        Assert.Equal("gap", fixture["seamKind"]!.GetValue<string>());
        var incoming = fixture["incomingSilence"]!.GetValue<double>();
        var outgoing = fixture["outgoingSilence"]!.GetValue<double>();
        foreach (var row in fixture["cases"]!.AsArray())
        {
            var window = Window(row!["windowSeconds"]!.GetValue<double>());
            var timing = VoiceLabPaceMatching.Match(row["measuredSeconds"]!.GetValue<double>(), window, incoming, outgoing, sampleRate);
            Assert.Equal(row["pace"]!.GetValue<double>(), timing.Pace);
            Assert.Equal(row["fits"]!.GetValue<bool>(), timing.Fits);
            var fit = VoiceLabRewriteFit.Hypothetical(window, incoming, outgoing, timing.EstimateSeconds, sampleRate);
            Assert.Equal(row["keepsSource"]!.GetValue<bool>(), fit is VoiceLabFitResult.Exact);
            Assert.True(fit.Plan.Incoming.PadFrames + fit.Plan.Outgoing.PadFrames <= 28_800);
            Assert.Contains("at ≈ " + timing.Pace.ToString("F2", CultureInfo.InvariantCulture) + "× pace", timing.Copy);
            if (!timing.Fits) Assert.True(timing.TooLong);
        }
    }

    [Fact]
    public void PreferenceMatchesExhaustiveProviderGrid()
    {
        foreach (var kind in new[] { VoiceLabSeamKind.Hard, VoiceLabSeamKind.Gap, VoiceLabSeamKind.None })
        foreach (var duration in new[] { 0.3, 1.145, 5.12, 19.4 })
        foreach (var fraction in new[] { 0.3, 0.7, 1.0, 1.4, 2.0 })
        {
            var window = Window(duration, kind);
            double? silence = kind == VoiceLabSeamKind.Hard ? null : 0.05;
            var natural = duration * fraction;
            VoiceLabFitResult Fit(double pace) => VoiceLabRewriteFit.Hypothetical(window, silence, silence, natural / pace, 48_000);
            var timing = VoiceLabPaceMatching.Match(natural, window, silence, silence, 48_000);
            var grid = Enumerable.Range(70, 51).Select(value => Fit(value / 100.0)).ToArray();
            Assert.Equal(grid.Any(fit => VoiceLabRewriteFit.AllowsVideo(fit, 48_000, 48_000)), timing.Fits);
            if (grid.Any(fit => fit is VoiceLabFitResult.Exact))
                Assert.IsType<VoiceLabFitResult.Exact>(Fit(timing.Pace));
        }
    }

    [Fact]
    public void HardSeamsFallBackToMatchVideoAndRetriesUseMeasuredPace()
    {
        var window = Window(5.12, VoiceLabSeamKind.Hard);
        var timing = VoiceLabPaceMatching.Match(3.39, window, null, null, 48_000);
        Assert.Equal(0.7, timing.Pace);
        Assert.True(timing.Fits);
        var fit = VoiceLabRewriteFit.Hypothetical(window, null, null, timing.EstimateSeconds, 48_000);
        Assert.IsType<VoiceLabFitResult.ChangedDuration>(fit);
        Assert.True(VoiceLabRewriteFit.AllowsVideo(fit, 48_000, 48_000));
        var retry = VoiceLabPaceMatching.Match(5.8, window, null, null, 48_000, oldPace: 0.7);
        Assert.Equal(0.8, retry.Pace);
        Assert.True(retry.Fits);
        Assert.Equal(5.075, retry.EstimateSeconds, 9);
    }

    [Fact]
    public void UnreachableShortPhrasesAndDialogueDoNotInventProviderSettings()
    {
        var window = Window(5.12, VoiceLabSeamKind.Hard);
        var shortTiming = VoiceLabPaceMatching.Match(1, window, null, null, 48_000);
        Assert.Equal(0.7, shortTiming.Pace);
        Assert.False(shortTiming.Fits);
        Assert.False(shortTiming.TooLong);
        var dialogue = VoiceLabPaceMatching.Match(3.39, window, null, null, 48_000, supportsPace: false);
        Assert.Equal(1, dialogue.Pace);
        Assert.False(dialogue.Fits);
        Assert.DoesNotContain("pace", dialogue.Copy);
    }
}
