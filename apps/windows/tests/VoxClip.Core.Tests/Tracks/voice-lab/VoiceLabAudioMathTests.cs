using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

[Trait("Track", "voice-lab")]
public sealed class VoiceLabAudioMathTests
{
    private static float[] Sine(double frequency, double peakDbfs, int count, int rate, double phase = 0)
    {
        var amplitude = Math.Pow(10, peakDbfs / 20);
        var values = new float[count];
        for (var n = 0; n < count; n++) values[n] = (float)(amplitude * Math.Sin(2.0 * Math.PI * frequency * n / rate + phase));
        return values;
    }

    private static float[] Noise(uint seed, double peakDbfs, int count)
    {
        var amplitude = Math.Pow(10, peakDbfs / 20);
        var values = new float[count];
        var state = seed;
        for (var n = 0; n < count; n++)
        {
            state = unchecked(state * 1_664_525u + 1_013_904_223u);
            values[n] = (float)(amplitude * (state / 2_147_483_648.0 - 1.0));
        }
        return values;
    }

    // Noise bursts between pauses, so the envelope has a shape to correlate.
    internal static float[] Speech(int rate, uint seed)
    {
        (double Seconds, double? Level)[] parts = [(0.23, -18), (0.11, null), (0.37, -24), (0.07, null), (0.19, -15),
            (0.21, null), (0.41, -21), (0.13, null), (0.29, -27), (0.17, null)];
        var values = new List<float>();
        for (var index = 0; index < parts.Length; index++)
        {
            var count = VoiceLabLoudness.SampleCount(parts[index].Seconds, rate);
            values.AddRange(parts[index].Level is { } level ? Noise(seed + (uint)index, level, count) : new float[count]);
        }
        return [.. values];
    }

    // The 10 ms envelope Media supplies, from the existing Core builder.
    internal static AudioEnvelope Envelope(float[] samples, int rate)
    {
        var builder = new AudioEnvelopeBuilder(rate, 1);
        builder.Append(samples);
        return builder.Finish();
    }

    // Renders a vector signal in Float64, in the README's operation order, and rounds each sample once to Float32.
    private static float[] Render(JsonNode signal)
    {
        var rate = Rate(signal);
        var gain = Math.Pow(10, (signal["gainDb"]?.GetValue<double>() ?? 0) / 20);
        var samples = new List<float>();
        foreach (var part in signal["parts"]!.AsArray())
        {
            var count = part!["samples"]!.GetValue<int>();
            switch (part["type"]!.GetValue<string>())
            {
                case "sine":
                {
                    var amplitude = Math.Pow(10, part["peakDbfs"]!.GetValue<double>() / 20);
                    var frequency = part["frequency"]!.GetValue<double>();
                    var phase = part["phase"]!.GetValue<double>();
                    for (var n = 0; n < count; n++) samples.Add((float)(amplitude * Math.Sin(2.0 * Math.PI * frequency * n / rate + phase) * gain));
                    break;
                }
                case "noise":
                {
                    var amplitude = Math.Pow(10, part["peakDbfs"]!.GetValue<double>() / 20);
                    var state = part["seed"]!.GetValue<uint>();
                    for (var n = 0; n < count; n++)
                    {
                        state = unchecked(state * 1_664_525u + 1_013_904_223u);
                        samples.Add((float)(amplitude * (state / 2_147_483_648.0 - 1.0) * gain));
                    }
                    break;
                }
                case "silence":
                    samples.AddRange(new float[count]);
                    break;
                default:
                    throw new InvalidDataException("Unknown signal part " + part["type"]);
            }
        }
        return [.. samples];
    }

    private static int Rate(JsonNode signal) => signal["rate"]!.GetValue<int>();

    // 1 kHz fills each 10 ms frame with whole cycles at 24, 44.1 and 48 kHz, so every frame has the sine's RMS.
    private static float[] Tone(double rmsDbfs, int count, int rate) => Sine(1000, rmsDbfs + 20 * Math.Log10(Math.Sqrt(2.0)), count, rate);

    private static void Throws(VoiceLabAudioMathErrorCode code, Action action) =>
        Assert.Equal(code, Assert.Throws<VoiceLabAudioMathException>(action).Code);

    [Fact]
    public void VoicedFramesUseTheRoundedTenMillisecondGrid()
    {
        Assert.Equal(441, VoiceLabLoudness.SampleCount(0.01, 44_100));
        Assert.Equal(221, VoiceLabLoudness.SampleCount(0.01, 22_050));
        Assert.Equal(110, VoiceLabLoudness.SampleCount(0.01, 11_025));
        float[] edge = [.. Tone(-44.95, 24_000, 48_000), .. Tone(-45.05, 24_000, 48_000)];
        Assert.InRange(VoiceLabLoudness.VoicedRmsDb(edge, 48_000)!.Value, -44.9501, -44.9499);
        Assert.Null(VoiceLabLoudness.VoicedRmsDb(Tone(-45.05, 44_100, 44_100), 44_100));
        Assert.Null(VoiceLabLoudness.VoicedRmsDb(new float[4_800], 48_000));
        Assert.Null(VoiceLabLoudness.VoicedRmsDb([], 48_000));
        // A loud trailing partial frame is ignored, and a quiet frame does not dilute the voiced mean square.
        var voiced = Tone(-20, 2_400, 24_000);
        float[] padded = [.. voiced, .. new float[240], .. Enumerable.Repeat(1f, 239)];
        Assert.Equal(VoiceLabLoudness.VoicedRmsDb(voiced, 24_000), VoiceLabLoudness.VoicedRmsDb(padded, 24_000));
    }

    [Fact]
    public void VoicedLevelRejectsUnusableInput()
    {
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.VoicedRmsDb([0f], 0));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.VoicedRmsDb([0f], 49));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.VoicedRmsDb([0f, float.NaN], 48_000));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.VoicedRmsDb([float.PositiveInfinity], 48_000));
    }

    [Fact]
    public void LevelGainClampsThenCapsTheTruePeak()
    {
        Assert.Equal(6, VoiceLabLoudness.LevelGainDb(-20, -26, -18));
        Assert.Equal(12, VoiceLabLoudness.LevelGainDb(-10, -35, -30));
        Assert.Equal(-12, VoiceLabLoudness.LevelGainDb(-40, -10, -6));
        Assert.Equal(8.5, VoiceLabLoudness.LevelGainDb(-3, -13, -9.5));
        // The cap applies after the clamp, so it can take the gain below −12 dB.
        Assert.Equal(-13, VoiceLabLoudness.LevelGainDb(-40, -10, 12));
        Throws(VoiceLabAudioMathErrorCode.NoVoicedAudio, () => VoiceLabLoudness.LevelGainDb(null, -20, -10));
        Throws(VoiceLabAudioMathErrorCode.NoVoicedAudio, () => VoiceLabLoudness.LevelGainDb(-20, null, -10));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.LevelGainDb(-20, -20, double.NaN));
    }

    [Fact]
    public void TruePeakUsesTheAnnexTwoFilterAtTheRatesOversampling()
    {
        Assert.Equal(new[] { 4, 2, 2, 1 }, new[] { 95_999, 96_000, 191_999, 192_000 }.Select(VoiceLabLoudness.Oversampling));
        // A unit impulse passes the published taps straight through, so the filter alone peaks at the 0.97216796875
        // tap; the true peak is the larger sample peak, 0 dBFS, at every rate.
        var impulse = new float[64];
        impulse[20] = 1;
        Assert.Equal(0, VoiceLabLoudness.TruePeakDbtp(impulse, 48_000));
        Assert.Equal(0, VoiceLabLoudness.TruePeakDbtp(impulse, 96_000));
        Assert.Equal(0, VoiceLabLoudness.TruePeakDbtp(impulse, 192_000));
        // Two adjacent full-scale samples meet the 0.465 and 0.780 taps of phases 1 and 2, above the samples.
        impulse[21] = 1;
        Assert.Equal(20 * Math.Log10(0.4650878906250 + 0.7797851562500), VoiceLabLoudness.TruePeakDbtp(impulse, 48_000));
        Assert.Equal(20 * Math.Log10(0.4650878906250 + 0.7797851562500), VoiceLabLoudness.TruePeakDbtp(impulse, 96_000));
        // fs/4 at 45° puts every sample at −3.01 dBFS while the waveform peaks between them.
        foreach (var rate in new[] { 24_000, 44_100, 48_000, 96_000 })
        {
            var wave = Sine(rate / 4.0, 0, rate / 10, rate, Math.PI / 4);
            Assert.InRange(VoiceLabLoudness.SamplePeakDbfs(wave), -3.0104, -3.0102);
            Assert.InRange(VoiceLabLoudness.TruePeakDbtp(wave, rate), 0.0816, 0.0836);
        }
        var high = Sine(48_000, 0, 19_200, 192_000, Math.PI / 4);
        Assert.Equal(VoiceLabLoudness.SamplePeakDbfs(high), VoiceLabLoudness.TruePeakDbtp(high, 192_000));
        Assert.Equal(double.NegativeInfinity, VoiceLabLoudness.TruePeakDbtp(new float[100], 48_000));
        Assert.Equal(double.NegativeInfinity, VoiceLabLoudness.SamplePeakDbfs([]));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.SamplePeakDbfs([1f, float.NaN]));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.TruePeakDbtp([0f], -1));
    }

    [Fact]
    public void NeighbourhoodLevelExcludesTheWindowAndFramesEachSideFromItsStart()
    {
        var quiet = Tone(-30, 48_000, 48_000);
        var loud = Tone(-10, 24_000, 48_000);
        // Neither the window nor the audio more than 3 s from it counts.
        float[] take = [.. loud, .. quiet, .. quiet, .. quiet, .. loud, .. quiet, .. quiet, .. quiet, .. loud];
        Assert.InRange(VoiceLabLoudness.NeighbourhoodVoicedRmsDb(take, 48_000, 168_000, 192_000), -30.0001, -29.9999);
        // The before side's 100 loud samples are its trailing partial frame and are ignored; the after side's 43 loud
        // samples open its first frame, which starts at the window's end.
        float[] ragged = [.. new float[4_800], .. Enumerable.Repeat(0.5f, 100), .. loud[..4_830], .. Enumerable.Repeat(0.1f, 43), .. new float[4_757]];
        var level = VoiceLabLoudness.NeighbourhoodVoicedRmsDb(ragged, 48_000, 4_900, 9_730);
        Assert.InRange(level - 20 * Math.Log10(Math.Sqrt(43 * 0.01 / 480)), -1e-4, 1e-4);
        // A voiced window between silent or empty sides has no level.
        float[] voicedWindow = [.. new float[4_800], .. loud];
        Throws(VoiceLabAudioMathErrorCode.NoVoicedAudio, () => VoiceLabLoudness.NeighbourhoodVoicedRmsDb(voicedWindow, 48_000, 4_800, 28_800));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.NeighbourhoodVoicedRmsDb(quiet, 48_000, -1, 10));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.NeighbourhoodVoicedRmsDb(quiet, 48_000, 10, 9));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.NeighbourhoodVoicedRmsDb(quiet, 48_000, 0, 48_001));
        // An absurd rate clamps the 3 s reach to the take instead of overflowing.
        Throws(VoiceLabAudioMathErrorCode.NoVoicedAudio, () => VoiceLabLoudness.NeighbourhoodVoicedRmsDb(quiet, int.MaxValue, 0, 10));
    }

    [Fact]
    public void MeasuredLevelGainUsesTheCandidatesInterSamplePeak()
    {
        var source = Sine(997, 0, 48_000, 48_000);
        var candidate = Sine(6_000, -10, 24_000, 24_000, Math.PI / 4);
        // The voiced difference is 10 dB; the true peak (−9.917 dBTP), not the −13.01 dBFS sample peak, caps it.
        Assert.InRange(VoiceLabLoudness.LevelGainDb(source, 48_000, 19_200, 28_800, candidate, 24_000), 8.916, 8.918);
        Throws(VoiceLabAudioMathErrorCode.NoVoicedAudio, () => VoiceLabLoudness.LevelGainDb(source, 48_000, 19_200, 28_800, new float[2_400], 24_000));
        // A candidate that cannot be measured fails as invalid input, even beside a silent neighbourhood.
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.LevelGainDb(new float[48_000], 48_000, 0, 10, [float.NaN], 24_000));
    }

    [Fact]
    public void KWeightingMatchesThePublished48kHzCoefficients()
    {
        var (shelf, highPass) = VoiceLabLoudness.KWeighting(48_000);
        double[] publishedShelf = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585];
        double[] publishedHighPass = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621];
        foreach (var (stage, published) in new[] { (shelf, publishedShelf), (highPass, publishedHighPass) })
        {
            double[] values = [stage.B0, stage.B1, stage.B2, stage.A1, stage.A2];
            for (var index = 0; index < values.Length; index++) Assert.InRange(values[index] - published[index], -1e-6, 1e-6);
        }
    }

    [Fact]
    public void MomentaryLoudnessMeetsTheSineAnchors()
    {
        foreach (var rate in new[] { 48_000, 44_100 })
            foreach (var (peak, expected) in new[] { (0.0, -3.01), (-20.0, -23.01) })
            {
                var start = rate - VoiceLabLoudness.SampleCount(0.4, rate);
                Assert.InRange(VoiceLabLoudness.MomentaryLufs(Sine(997, peak, rate, rate), rate, start), expected - 0.05, expected + 0.05);
            }
        Assert.Equal(double.NegativeInfinity, VoiceLabLoudness.MomentaryLufs(new float[19_200], 48_000, 0));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.MomentaryLufs(new float[19_199], 48_000, 0));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.MomentaryLufs(new float[19_200], 48_000, -1));
    }

    [Fact]
    public void SeamJumpComparesTheWindowsEitherSideOfEachSeam()
    {
        // 1 kHz has whole cycles in 0.6 s and 0.25 s, so each level step keeps the sine's phase.
        var steady = Sine(1000, -20, 57_600, 48_000);
        Assert.True(VoiceLabLoudness.SeamJumpLu(steady, 48_000, 28_800) < 0.01);
        float[] rising = [.. Sine(1000, -20, 26_460, 44_100), .. Sine(1000, -18.1, 26_460, 44_100)];
        Assert.InRange(VoiceLabLoudness.SeamJumpLu(rising, 44_100, 26_460), 1.89, 1.91);
        Assert.Equal(0, VoiceLabLoudness.SeamJumpLu(Sine(1000, -75, 48_000, 48_000), 48_000, 24_000));
        // At the buffer edge a window shortens, down to 0.1 s on either side.
        float[] edge = [.. Sine(1000, -20, 12_000, 48_000), .. Sine(1000, -21, 36_000, 48_000)];
        Assert.InRange(VoiceLabLoudness.SeamJumpLu(edge, 48_000, 12_000), 0.99, 1.01);
        Assert.True(VoiceLabLoudness.SeamJumpLu(steady, 48_000, 4_800) < 0.01);
        Assert.True(VoiceLabLoudness.SeamJumpLu(steady, 48_000, 52_800) < 0.01);
        Throws(VoiceLabAudioMathErrorCode.InsufficientContext, () => VoiceLabLoudness.SeamJumpLu(steady, 48_000, 4_799));
        Throws(VoiceLabAudioMathErrorCode.InsufficientContext, () => VoiceLabLoudness.SeamJumpLu(steady, 48_000, 52_801));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => VoiceLabLoudness.SeamJumpLu(steady, 48_000, 57_601));
        // A digitally silent side counts as −70 LUFS, so a cut into speech reads a finite 47 LU, which fails QA.
        float[] cut = [.. new float[24_000], .. Sine(1000, -20, 24_000, 48_000)];
        Assert.InRange(VoiceLabLoudness.SeamJumpLu(cut, 48_000, 24_000), 46.99610474618582 - 1e-6, 46.99610474618582 + 1e-6);
        // A recipe carries its largest jump, and 0 when every seam is none.
        Assert.Equal(0, VoiceLabLoudness.LufsJumpLu(edge, 48_000, []));
        var jumps = VoiceLabLoudness.SeamJumps(rising, 44_100, [8_820, 26_460]);
        Assert.True(jumps.Length == 2 && jumps[0] < 0.01);
        Assert.Equal(jumps[1], VoiceLabLoudness.LufsJumpLu(rising, 44_100, [8_820, 26_460]));
    }

    [Fact]
    public void FlatnessScoresTheSpreadOfMomentaryLoudness()
    {
        var steady = VoiceLabLoudness.FlatnessMeasurement(Sine(1000, -20, 96_000, 48_000), 48_000);
        Assert.True(steady.Windows == 17 && steady.Flatness > 0.999);
        float[] halves = [.. Sine(1000, -20, 48_000, 48_000), .. Sine(1000, -23, 48_000, 48_000)];
        var stepped = VoiceLabLoudness.FlatnessMeasurement(halves, 48_000);
        Assert.Equal(17, stepped.Windows);
        Assert.InRange(stepped.Stdev, 1.3854, 1.3874);
        Assert.Equal(1 - stepped.Stdev / 6, stepped.Flatness);
        // The quiet second's windows sit below −70 LUFS and drop out; the loud second and the three windows reaching
        // into it remain.
        float[] rising = [.. Sine(1000, -80, 48_000, 48_000), .. Sine(1000, -20, 48_000, 48_000)];
        var gated = VoiceLabLoudness.FlatnessMeasurement(rising, 48_000);
        Assert.Equal(10, gated.Windows);
        Assert.InRange(gated.Flatness, 0.6814, 0.6834);
        float[] wide = [.. Noise(35, -10, 12_000), .. Noise(36, -30, 12_000), .. Noise(37, -10, 12_000), .. Noise(38, -30, 12_000)];
        Assert.Equal(0, VoiceLabLoudness.Flatness(wide, 24_000));
        Assert.Equal((1, 0.0, 1.0), VoiceLabLoudness.FlatnessMeasurement(Noise(39, -20, 21_600), 48_000));
        var silent = VoiceLabLoudness.FlatnessMeasurement(new float[44_100], 44_100);
        Assert.True(silent.Windows == 0 && silent.Flatness == 1);
        Assert.Equal(1, VoiceLabLoudness.Flatness([], 48_000));
    }

    [Fact]
    public void ConformTrimsSmallDifferencesAndAlignsLargerOnes()
    {
        const int rate = 48_000;
        var speech = Speech(rate, 100);
        VoiceLabConformDecision Decide(float[] output, double search = VoiceLabConform.CleanAudioSearchSeconds) =>
            VoiceLabConform.Decide(Envelope(speech, rate), Envelope(output, rate), speech.Length, output.Length, rate, search);
        Assert.Equal(new VoiceLabConformDecision.TrimOrPad(960), Decide([.. speech, .. new float[960]]));
        Assert.Equal(new VoiceLabConformDecision.TrimOrPad(-960), Decide(speech[..^960]));
        // 21 ms late: the nearest whole frame is 20 ms, which is within 20 ms of Δ.
        var late = Assert.IsType<VoiceLabConformDecision.Shift>(Decide([.. new float[1_008], .. speech]));
        Assert.Equal(960, late.Lag);
        Assert.InRange(late.Peak, 0.9937, 0.9957);
        Assert.Equal(new VoiceLabConformDecision.Shift(5_760, 1), Decide([.. new float[5_760], .. speech]));
        // Extra audio at the end only: the envelopes align at lag 0, but Δ is 100 ms.
        Assert.Equal(new VoiceLabConformDecision.OutOfSync(1, 0), Decide([.. speech, .. new float[4_800]]));
        // 0.4 s late lies outside the voice changer's ±0.3 s search and inside Clean audio's ±0.5 s.
        float[] delayed = [.. new float[19_200], .. speech];
        Assert.IsType<VoiceLabConformDecision.OutOfSync>(Decide(delayed, VoiceLabConform.VoiceChangerSearchSeconds));
        Assert.Equal(new VoiceLabConformDecision.Shift(19_200, 1), Decide(delayed));
        var unrelated = Assert.IsType<VoiceLabConformDecision.OutOfSync>(Decide(Noise(399, -20, speech.Length + 4_800)));
        Assert.InRange(unrelated.Peak, 0.1445, 0.1465);
    }

    [Fact]
    public void ConformBreaksTiesBySmallestThenNegativeLag()
    {
        static VoiceLabConformDecision Decide(float[] input, float[] output) => VoiceLabConform.Decide(
            new AudioEnvelope(48_000, 0.01, input), new AudioEnvelope(48_000, 0.01, output), input.Length * 480L, output.Length * 480L,
            48_000, VoiceLabConform.VoiceChangerSearchSeconds);
        float[] alternating = [1, 0, 1, 0, 1, 0, 1, 0, 1, 0];
        Assert.Equal(new VoiceLabConformDecision.OutOfSync(1, 0), Decide(alternating, [.. alternating, 1, 0, 1]));
        Assert.Equal(new VoiceLabConformDecision.OutOfSync(1, -480), Decide(alternating, [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]));
        Assert.Equal(0, VoiceLabConform.Correlation([1, 1, 1], [2, 3, 4], 0));
        Assert.Equal(0, VoiceLabConform.Correlation([1, 2, 3], [2, 4, 6], 3));
        Assert.Equal(1, VoiceLabConform.Correlation([1, 2, 3], [9, 2, 4, 6], 1));
    }

    [Fact]
    public void ConformScoresOnlyOverlapsOfHalfTheShorterEnvelopeAndAtMostOne()
    {
        double[] ramp = [1, 2, 3, 4, 5, 6];
        // ceil(6 / 2) = 3 frames: a 3-frame overlap scores, a 2-frame one does not.
        Assert.Equal(1.0, VoiceLabConform.Correlation(ramp, ramp, 3));
        Assert.Equal(0.0, VoiceLabConform.Correlation(ramp, ramp, 4));
        Assert.Equal(0.0, VoiceLabConform.Correlation(ramp, ramp, -4));
        // Odd and unequal lengths: the minimum is ceil(min(9, 7) / 2) = 4 frames, not floor (3) or the input's ceil (5).
        double[] nine = [1, 2, 3, 4, 5, 6, 7, 8, 9], seven = [1, 2, 3, 4, 5, 6, 7];
        Assert.Equal(1.0, VoiceLabConform.Correlation(nine, seven, 3));
        Assert.Equal(0.0, VoiceLabConform.Correlation(nine, seven, 4));
        Assert.Equal(1.0, VoiceLabConform.Correlation(nine, seven, -5));
        Assert.Equal(0.0, VoiceLabConform.Correlation(nine, seven, -6));
        // These Float32 levels, one at 0.9 of the other, correlate 1.0000000000000002 before the clamp.
        double[] level = [1.1f, 7.5f, 1.3f], quieter = [0.99f, 6.75f, 1.17f];
        Assert.Equal(1.0, VoiceLabConform.Correlation(level, quieter, 0));
    }

    [Fact]
    public void ConformRejectsEnvelopesOffTheInputGrid()
    {
        var levels = Enumerable.Repeat(0.1f, 100).ToArray();
        var envelope = new AudioEnvelope(48_000, 0.01, levels);
        VoiceLabConformDecision Decide(AudioEnvelope? input = null, long inputSamples = 48_000, int rate = 48_000, double search = 0.3) =>
            VoiceLabConform.Decide(input ?? envelope, envelope, inputSamples, 48_000, rate, search);
        Assert.Equal(new VoiceLabConformDecision.TrimOrPad(0), Decide());
        Assert.Equal(new VoiceLabConformDecision.TrimOrPad(-479), Decide(inputSamples: 48_479));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => Decide(inputSamples: 48_480));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => Decide(new AudioEnvelope(44_100, 0.01, levels)));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => Decide(new AudioEnvelope(48_000, 0.02, levels)));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => Decide(new AudioEnvelope(48_000, 0.01, [.. levels[..^1], float.NaN])));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => Decide(search: -0.1));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => Decide(search: double.PositiveInfinity));
        Throws(VoiceLabAudioMathErrorCode.InvalidInput, () => Decide(rate: 0));
        // Both frame-length conventions name the same 221-sample frame at 22.05 kHz.
        foreach (var frameSeconds in new[] { 0.01, 221.0 / 22_050 })
        {
            var odd = new AudioEnvelope(22_050, frameSeconds, Enumerable.Repeat(0.1f, 99).ToArray());
            Assert.Equal(new VoiceLabConformDecision.TrimOrPad(0), VoiceLabConform.Decide(odd, odd, 21_879, 21_879, 22_050, 0.3));
        }
    }

    [Fact]
    public void SharedVectorsMatchTheNumPyReference()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "audio-math-cases.json")))!;
        Assert.Equal(1, root["version"]!.GetValue<int>());
        var bounds = root["tolerances"]!;
        double Bound(string name) => bounds[name]!.GetValue<double>();
        var largest = new SortedDictionary<string, double>(StringComparer.Ordinal);
        var anchors = new List<string>();
        var checkedCases = 0;
        // A null expectation is −∞ for a peak or a loudness.
        void Check(string metric, double actual, JsonNode? expected, double bound, string id)
        {
            if (expected is null)
            {
                Assert.True(double.IsNegativeInfinity(actual), $"{id} {metric}: {actual}");
                return;
            }
            var difference = Math.Abs(actual - expected.GetValue<double>());
            largest[metric] = Math.Max(largest.GetValueOrDefault(metric), difference);
            Assert.True(difference <= bound, $"{id} {metric}: {actual} against {expected}");
        }
        void Voiced(double? actual, JsonNode? expected, string id)
        {
            Assert.True(actual.HasValue == (expected is not null), $"{id} voicedRmsDb");
            if (actual is { } value && expected is not null) Check("voicedRmsDb", value, expected, Bound("db"), id);
        }
        // The neighbourhood level, or null where it throws NoVoicedAudio.
        static double? Neighbourhood(float[] samples, int rate, JsonNode window)
        {
            try
            {
                return VoiceLabLoudness.NeighbourhoodVoicedRmsDb(samples, rate, window[0]!.GetValue<int>(), window[1]!.GetValue<int>());
            }
            catch (VoiceLabAudioMathException failure) when (failure.Code == VoiceLabAudioMathErrorCode.NoVoicedAudio)
            {
                return null;
            }
        }
        void Decision(VoiceLabConformDecision decision, JsonNode expected, string id)
        {
            var kind = expected["kind"]!.GetValue<string>();
            switch (decision)
            {
                case VoiceLabConformDecision.TrimOrPad trim:
                    Assert.True(kind == "trimOrPad" && trim.Delta == expected["delta"]!.GetValue<long>(), $"{id}: {decision}");
                    break;
                case VoiceLabConformDecision.Shift shift:
                    Assert.True(kind == "shift" && shift.Lag == expected["lag"]!.GetValue<long>(), $"{id}: {decision}");
                    Check("conformPeak", shift.Peak, expected["peak"]!, Bound("correlation"), id);
                    break;
                case VoiceLabConformDecision.OutOfSync outOfSync:
                    Assert.True(kind == "outOfSync" && outOfSync.Lag == expected["lag"]!.GetValue<long>(), $"{id}: {decision}");
                    Check("conformPeak", outOfSync.Peak, expected["peak"]!, Bound("correlation"), id);
                    break;
            }
        }
        static double[] Coefficients((VoiceLabBiquad Shelf, VoiceLabBiquad HighPass) stages) =>
        [
            stages.Shelf.B0, stages.Shelf.B1, stages.Shelf.B2, stages.Shelf.A1, stages.Shelf.A2,
            stages.HighPass.B0, stages.HighPass.B1, stages.HighPass.B2, stages.HighPass.A1, stages.HighPass.A2,
        ];
        static double[] Numbers(JsonNode node) => [.. node.AsArray().Select(value => value!.GetValue<double>())];
        var published = root["publishedKWeighting48k"]!;
        double[] reference48 = [.. Numbers(published["shelf"]!), .. Numbers(published["highPass"]!)];
        var derived48 = Coefficients(VoiceLabLoudness.KWeighting(48_000));
        for (var index = 0; index < derived48.Length; index++) Assert.InRange(derived48[index] - reference48[index], -1e-6, 1e-6);
        foreach (var item in root["cases"]!.AsArray())
        {
            var id = item!["id"]!.GetValue<string>();
            var expected = item["expected"]!;
            switch (item["kind"]!.GetValue<string>())
            {
                case "kWeighting":
                {
                    var values = Coefficients(VoiceLabLoudness.KWeighting(item["rate"]!.GetValue<int>()));
                    var references = expected["shelf"]!.AsArray().Concat(expected["highPass"]!.AsArray()).ToArray();
                    Assert.Equal(values.Length, references.Length);
                    for (var index = 0; index < values.Length; index++) Check("coefficient", values[index], references[index], Bound("coefficient"), id);
                    break;
                }
                case "voiced":
                    Voiced(VoiceLabLoudness.VoicedRmsDb(Render(item["signal"]!), Rate(item["signal"]!)), expected["voicedRmsDb"], id);
                    break;
                case "peaks":
                {
                    var samples = Render(item["signal"]!);
                    var rate = Rate(item["signal"]!);
                    Assert.Equal(expected["oversampling"]!.GetValue<int>(), VoiceLabLoudness.Oversampling(rate));
                    Check("samplePeakDbfs", VoiceLabLoudness.SamplePeakDbfs(samples), expected["samplePeakDbfs"], Bound("db"), id);
                    Check("truePeakDbtp", VoiceLabLoudness.TruePeakDbtp(samples, rate), expected["truePeakDbtp"], Bound("truePeakDb"), id);
                    break;
                }
                case "neighbourhood":
                {
                    var level = Neighbourhood(Render(item["signal"]!), Rate(item["signal"]!), item["window"]!);
                    Assert.True((level is null) == (expected["error"]?.GetValue<string>() == "noVoicedAudio"), id);
                    Voiced(level, expected["voicedRmsDb"], id);
                    break;
                }
                case "levelGain":
                {
                    var source = Render(item["source"]!);
                    var sourceRate = Rate(item["source"]!);
                    var window = item["window"]!;
                    var (windowStart, windowEnd) = (window[0]!.GetValue<int>(), window[1]!.GetValue<int>());
                    var candidate = Render(item["candidate"]!);
                    var candidateRate = Rate(item["candidate"]!);
                    Voiced(Neighbourhood(source, sourceRate, window), expected["sourceVoicedRmsDb"], id);
                    Voiced(VoiceLabLoudness.VoicedRmsDb(candidate, candidateRate), expected["candidateVoicedRmsDb"], id);
                    Check("truePeakDbtp", VoiceLabLoudness.TruePeakDbtp(candidate, candidateRate), expected["candidateTruePeakDbtp"],
                        Bound("truePeakDb"), id);
                    if (expected["error"]?.GetValue<string>() == "noVoicedAudio")
                        Throws(VoiceLabAudioMathErrorCode.NoVoicedAudio,
                            () => VoiceLabLoudness.LevelGainDb(source, sourceRate, windowStart, windowEnd, candidate, candidateRate));
                    else
                        Check("gainDb", VoiceLabLoudness.LevelGainDb(source, sourceRate, windowStart, windowEnd, candidate, candidateRate),
                            expected["gainDb"]!, Bound("db"), id);
                    break;
                }
                case "momentary":
                {
                    var lufs = VoiceLabLoudness.MomentaryLufs(Render(item["signal"]!), Rate(item["signal"]!), item["windowStart"]!.GetValue<int>());
                    Check("momentaryLufs", lufs, expected["lufs"], Bound("db"), id);
                    if (id.StartsWith("anchor-", StringComparison.Ordinal)) anchors.Add($"{id}={lufs.ToString("R", CultureInfo.InvariantCulture)}");
                    break;
                }
                case "seamJump":
                {
                    var samples = Render(item["signal"]!);
                    var rate = Rate(item["signal"]!);
                    int[] seams = [.. item["seams"]!.AsArray().Select(value => value!.GetValue<int>())];
                    if (expected["error"]?.GetValue<string>() == "insufficientContext")
                    {
                        Throws(VoiceLabAudioMathErrorCode.InsufficientContext, () => VoiceLabLoudness.LufsJumpLu(samples, rate, seams));
                        break;
                    }
                    var jumps = VoiceLabLoudness.SeamJumps(samples, rate, seams);
                    var references = expected["jumps"]!.AsArray();
                    Assert.Equal(references.Count, jumps.Length);
                    for (var index = 0; index < jumps.Length; index++) Check("seamJumpLu", jumps[index], references[index], Bound("db"), id);
                    Check("lufsJumpLu", VoiceLabLoudness.LufsJumpLu(samples, rate, seams), expected["lufsJumpLu"]!, Bound("db"), id);
                    break;
                }
                case "flatness":
                {
                    var measured = VoiceLabLoudness.FlatnessMeasurement(Render(item["signal"]!), Rate(item["signal"]!));
                    Assert.Equal(expected["windows"]!.GetValue<int>(), measured.Windows);
                    Check("flatnessStdev", measured.Stdev, expected["stdev"]!, Bound("db"), id);
                    Check("flatness", measured.Flatness, expected["flatness"]!, Bound("flatness"), id);
                    break;
                }
                case "conform":
                {
                    var input = Render(item["input"]!);
                    var output = Render(item["output"]!);
                    var rate = Rate(item["input"]!);
                    Decision(VoiceLabConform.Decide(Envelope(input, rate), Envelope(output, rate), input.Length, output.Length, rate,
                        item["searchSeconds"]!.GetValue<double>()), expected, id);
                    break;
                }
                case "conformEnvelope":
                {
                    var rate = item["rate"]!.GetValue<int>();
                    float[] Levels(string key) => [.. item[key]!.AsArray().Select(value => value!.GetValue<float>())];
                    Decision(VoiceLabConform.Decide(new AudioEnvelope(rate, 0.01, Levels("inputLevels")), new AudioEnvelope(rate, 0.01, Levels("outputLevels")),
                        item["inputSamples"]!.GetValue<long>(), item["outputSamples"]!.GetValue<long>(), rate,
                        item["searchSeconds"]!.GetValue<double>()), expected, id);
                    break;
                }
                default:
                    Assert.Fail($"Unknown audio math case kind {item["kind"]} in {id}");
                    break;
            }
            checkedCases++;
        }
        Assert.Equal(root["cases"]!.AsArray().Count, checkedCases);
        Assert.True(checkedCases >= 92);
        var log = TestContext.Current.TestOutputHelper!;
        log.WriteLine($"audio-math vectors: {checkedCases} cases; anchors {string.Join(' ', anchors)}");
        log.WriteLine("audio-math largest difference per metric: " +
            string.Join(' ', largest.Select(pair => $"{pair.Key}={pair.Value.ToString("R", CultureInfo.InvariantCulture)}")));
    }
}

/// <summary>Runs alone, after the parallel collections, so no other test shares its single measurement.</summary>
[CollectionDefinition("voice-lab timing", DisableParallelization = true)]
public sealed class VoiceLabTimingCollection;

[Collection("voice-lab timing")]
[Trait("Track", "voice-lab")]
public sealed class VoiceLabAudioMathTimingTests
{
    // One timed pass of the measurements a caller makes on a 60 s, 48 kHz take: a single measurement, no repetition.
    // Wall time, because .NET has no portable per-thread CPU clock; its own collection keeps other tests off the CPU.
    [Fact]
    public void SixtySecondsAt48kHzMeasureWithinTwoSeconds()
    {
        const int rate = 48_000;
        var speech = VoiceLabAudioMathTests.Speech(rate, 500);
        var input = Enumerable.Repeat(speech, 28).SelectMany(part => part).Take(60 * rate).ToArray();
        float[] output = [.. new float[4_800], .. input];
        var inputEnvelope = VoiceLabAudioMathTests.Envelope(input, rate);
        var outputEnvelope = VoiceLabAudioMathTests.Envelope(output, rate);
        var timer = Stopwatch.StartNew();
        _ = VoiceLabLoudness.LevelGainDb(input, rate, 29 * rate, 31 * rate, input, rate);
        _ = VoiceLabLoudness.SamplePeakDbfs(input);
        _ = VoiceLabLoudness.LufsJumpLu(input, rate, [20 * rate, 40 * rate]);
        _ = VoiceLabLoudness.Flatness(input, rate);
        _ = VoiceLabConform.Decide(inputEnvelope, outputEnvelope, input.Length, output.Length, rate, VoiceLabConform.CleanAudioSearchSeconds);
        timer.Stop();
        TestContext.Current.TestOutputHelper!.WriteLine(
            $"audio-math 60 s at 48 kHz: {timer.Elapsed.TotalSeconds.ToString("F3", CultureInfo.InvariantCulture)} s");
        Assert.True(timer.Elapsed < TimeSpan.FromSeconds(2), $"60 s at 48 kHz took {timer.Elapsed}");
    }
}
