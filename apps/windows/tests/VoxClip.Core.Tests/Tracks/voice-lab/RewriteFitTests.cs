using VoxClip.Core.Domain.Editing;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class RewriteFitTests
{
    [Fact]
    public void PhraseTimingUsesTheSingleProductionPaceMatcher() =>
        Assert.Null(typeof(VoiceLabRewriteFit).GetMethod("Measure"));

    /// <summary>The calibrated prior (ADR-R43): a final mark adds nothing; one group counts once at its largest pause.</summary>
    [Theory]
    [InlineData("then, well, let's get going.", 1.8804761904761904)]
    [InlineData("players can actually work together, choose their team,", 3.2685714285714282)]
    [InlineData("word...?!", 0.7280952380952381)]
    [InlineData("word,—next!", 1.0661904761904761)]
    [InlineData("word，；next！？", 1.0661904761904761)]
    public void CalibratedEstimateCountsPunctuationRunsWithoutAProviderRateFloor(string text, double expected)
    {
        Assert.Equal(expected, VoiceLabRewriteFit.Estimate(text, 14), 12);
    }

    /// <summary>The 3 November phrases (another speaker, an older model) replay at the calibrated prior, which overshoots them; two
    /// measured takes of that voice bring the third within 15% (Mac <c>anotherVoiceIsCorrectedByItsOwnTakes</c>).</summary>
    [Fact]
    public void SharedRealPhraseCalibrationReplaysWithoutAProviderCall()
    {
        var shared = Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR")!;
        var fixture = JsonNode.Parse(File.ReadAllText(Path.Combine(shared, "fixtures", "voice-lab", "phrase-timing-cases.json")))!;
        Assert.Equal("voxclip-phrase-timing/1", fixture["schema"]!.GetValue<string>());
        Assert.Equal(3, fixture["caseCount"]!.GetValue<int>());
        var cases = fixture["cases"]!.AsArray();
        Assert.Equal(3, cases.Count);
        var calibration = fixture["calibration"]!;
        Assert.Equal(VoiceLabRewriteFit.PriorVersion, calibration["prior"]!.GetValue<int>());
        Assert.Equal(VoiceLabRewriteFit.ProviderSpeechRateMultiplier, calibration["providerSpeechRateMultiplier"]!.GetValue<double>());
        Assert.Equal(VoiceLabRewriteFit.OnsetSeconds, calibration["onsetSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabRewriteFit.ClausePauseSeconds, calibration["clausePauseSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabRewriteFit.SentencePauseSeconds, calibration["sentencePauseSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabPatchConstants.TTS_TRIM_LEAD, calibration["trimLeadSeconds"]!.GetValue<double>());
        Assert.Equal(VoiceLabPatchConstants.TTS_TRIM_TAIL, calibration["trimTailSeconds"]!.GetValue<double>());
        var voice = new VoiceLabVoiceCalibration("other-voice");
        foreach (var phrase in cases)
        {
            var text = phrase!["text"]!.GetValue<string>();
            var rate = phrase["rate"]!.GetValue<double>();
            var measured = phrase["measuredVoicedSeconds"]!.AsArray().Select(value => value!.GetValue<double>()).ToArray();
            var estimate = VoiceLabRewriteFit.Estimate(text, rate);
            Assert.Equal(phrase["expectedSeconds"]!.GetValue<double>(), estimate, 12);
            if (phrase["id"]!.GetValue<string>() != "phrase-3")
            {
                Assert.True(estimate > measured.Max());
                voice = voice.Recording("eleven_multilingual_v2", phrase["id"]!.GetValue<string>(), measured.Average(), estimate);
                continue;
            }
            var samples = VoiceLabRateCalibration.Samples([], voice.Samples("eleven_multilingual_v2"));
            Assert.InRange(estimate * VoiceLabWordingFit.Multiplier(samples) / measured[0], 0.85, 1.15);
            var window = new VoiceLabWindow("first", "last", [], [], 2, 3.1, 96_000, 148_800,
                new(VoiceLabSeamKind.Hard, 2, 96_000, 0), new(VoiceLabSeamKind.Hard, 3.1, 148_800, 0));
            Assert.False(VoiceLabPaceMatching.Measure(text, rate, window, null, null, 48_000, supportsPace: false, hardJoinSmoothing: true).Fits);
        }
    }

    [Fact]
    public void SpeakingRateUsesUnicodeLettersAndUnionOfWordSpansWithoutPausesOrEvents()
    {
        TimedWord Word(string id, string text, double start, double end) => new(id, text, WordKind.Word, start, end, null, null, 1, null, TimingSource.Native);
        var words = new[] { Word("1", "é1!", 0, 1), Word("2", "二2", 0.5, 1.5), Word("3", "end", 9, 9.5),
            Word("4", "ignored", 10, 11) with { Kind = WordKind.Event } };
        Assert.Equal(3.5, VoiceLabRewriteFit.SpeakingRate(words), 9);
        Assert.Throws<VoiceLabLengthBudgetException>(() => VoiceLabRewriteFit.SpeakingRate([]));
    }

    [Fact]
    public void EverySlotBoundaryUsesThePaidFitPlannerAfterBorrowingSilence()
    {
        foreach (var sourceRate in new[] { 44_100, 48_000 })
        foreach (var seconds in new[] { 0.4, 1.1, 3.0 })
        foreach (var kind in new[] { VoiceLabSeamKind.Hard, VoiceLabSeamKind.Gap, VoiceLabSeamKind.None })
        foreach (var silence in new[] { 0.0, 0.25, 0.8 })
        {
            var start = kind == VoiceLabSeamKind.None ? 0.0 : 2.0;
            var end = start + seconds;
            var window = new VoiceLabWindow("first", "last", [], [], start, end, (long)EditingMath.Round(start * sourceRate),
                (long)EditingMath.Round(end * sourceRate), new(kind, start, (long)EditingMath.Round(start * sourceRate), 0),
                new(kind, end, (long)EditingMath.Round(end * sourceRate), 0));
            double? lend = kind == VoiceLabSeamKind.Hard ? null : kind == VoiceLabSeamKind.None ? Math.Min(silence, seconds / 4) : silence;
            var review = VoiceLabPaceMatching.Measure("word", 14, window, lend, lend, sourceRate, supportsPace: false, hardJoinSmoothing: true);
            var maximum = Assert.IsType<double>(review.MaximumSeconds);
            Assert.True(VoiceLabRewriteFit.AllowsVideo(VoiceLabRewriteFit.Hypothetical(window, lend, lend, maximum - 0.001, sourceRate, hardJoinSmoothing: true), sourceRate, sourceRate),
                $"rate={sourceRate}, seconds={seconds}, kind={kind}, silence={lend}, slot={review.SlotSeconds}");
            Assert.False(VoiceLabRewriteFit.AllowsVideo(VoiceLabRewriteFit.Hypothetical(window, lend, lend, maximum + 0.001, sourceRate, hardJoinSmoothing: true), sourceRate, sourceRate));
            foreach (var estimate in new[] { review.SlotSeconds * 0.5, review.SlotSeconds, review.SlotSeconds + 0.1 })
            {
                var measured = VoiceLabPaceMatching.Measure("word", 4 / ((estimate - 0.09) * VoiceLabRewriteFit.ProviderSpeechRateMultiplier), window, lend, lend, sourceRate, supportsPace: false, hardJoinSmoothing: true);
                var fit = VoiceLabRewriteFit.Hypothetical(window, lend, lend, measured.EstimateSeconds, sourceRate, hardJoinSmoothing: true);
                Assert.Equal(VoiceLabRewriteFit.AllowsVideo(fit, sourceRate, sourceRate), measured.Fits);
            }
        }
    }
}
