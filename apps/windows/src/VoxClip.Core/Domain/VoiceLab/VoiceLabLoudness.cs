using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Typed failures of the Voice Lab audio measurements; voice-lab.md §8.7 item 2 and §8.11 item 3.</summary>
public enum VoiceLabAudioMathErrorCode
{
    /// <summary>The source neighbourhood or the candidate has no 10 ms frame above VOICED_FRAME, so no level gain exists.</summary>
    NoVoicedAudio,
    /// <summary>A seam window cut short by the buffer edge is below 0.1 s.</summary>
    InsufficientContext,
    /// <summary>A sample rate, position, envelope or sample value the measurement cannot use.</summary>
    InvalidInput
}

/// <summary>Thrown by <see cref="VoiceLabLoudness"/> and <see cref="VoiceLabConform"/>.</summary>
public sealed class VoiceLabAudioMathException(VoiceLabAudioMathErrorCode code) : Exception(code.ToString())
{
    /// <summary>The typed failure.</summary>
    public VoiceLabAudioMathErrorCode Code { get; } = code;
}

/// <summary>Biquad coefficients normalised to a0 = 1: y = b0·x + b1·x₋₁ + b2·x₋₂ − a1·y₋₁ − a2·y₋₂.</summary>
internal readonly record struct VoiceLabBiquad(double B0, double B1, double B2, double A1, double A2);

/// <summary>Level, peak and loudness measurements on mono Float32 samples; callers downmix. voice-lab.md §8.6,
/// §8.7 item 2 and §8.11 items 2 and 3. No I/O, media framework or global state, and allocations stay O(input).</summary>
public static class VoiceLabLoudness
{
    internal const double LoudnessNeighbourhoodSeconds = 3.0;
    internal const double GainClampDb = 12.0;
    internal const double TruePeakLimitDbtp = -1.0;
    internal const double MomentarySeconds = 0.4;
    internal const double MinimumSeamWindowSeconds = 0.1;
    internal const double SilenceGateLufs = -70.0;
    internal const double FlatnessStepSeconds = 0.1;
    internal const double FlatnessStdevScale = 6.0;

    /// <summary>The RMS over every voiced 10 ms frame, in dBFS, or null when no frame is voiced. Frames are
    /// round_half_up(rate × 0.01) samples from sample 0, a trailing partial frame is ignored, and a frame is voiced
    /// when its RMS exceeds VOICED_FRAME (−45 dBFS).</summary>
    public static double? VoicedRmsDb(ReadOnlySpan<float> samples, int sampleRate)
    {
        Validate(samples, sampleRate);
        return VoicedLevel(samples, [], sampleRate);
    }

    /// <summary>The source level beside the window being replaced, in dBFS (§8.7 item 2). It takes the voiced frames
    /// within LOUDNESS_NEIGHBOURHOOD (3 s) before windowStart and after windowEnd, each side clamped to the take, and
    /// excludes the window itself. Each side is framed on its own grid from its first sample, a trailing partial frame
    /// is ignored, and the voiced frames of both sides pool into one mean square. Throws NoVoicedAudio when neither side
    /// has one.</summary>
    // Spec: voice-lab.md §8.7 item 2 and §8.3 LOUDNESS_NEIGHBOURHOOD; the window is excluded because it is replaced.
    public static double NeighbourhoodVoicedRmsDb(ReadOnlySpan<float> source, int sampleRate, int windowStart, int windowEnd)
    {
        Validate(source, sampleRate);
        if (windowStart < 0 || windowStart > windowEnd || windowEnd > source.Length)
            throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        // Clamped in Float64 first, so an absurd rate cannot overflow the conversion.
        var reach = (int)Math.Min(EditingMath.Round(LoudnessNeighbourhoodSeconds * sampleRate), source.Length);
        var before = source[Math.Max(0, windowStart - reach)..windowStart];
        var after = source[windowEnd..(int)Math.Min(source.Length, (long)windowEnd + reach)];
        return VoicedLevel(before, after, sampleRate) ?? throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.NoVoicedAudio);
    }

    /// <summary>audio.gainDb for a candidate (§8.7 item 2): the voiced-RMS difference clamped to GAIN_CLAMP, then
    /// lowered until the candidate's true peak sits at −1 dBTP. A recipe stores one static gain, so this cap is the only
    /// form the limit can take; nothing limits dynamically and the voice itself is unaltered.</summary>
    public static double LevelGainDb(double? sourceVoicedRmsDb, double? candidateVoicedRmsDb, double candidateTruePeakDbtp)
    {
        if (sourceVoicedRmsDb is not { } source || candidateVoicedRmsDb is not { } candidate)
            throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.NoVoicedAudio);
        if (!double.IsFinite(source) || !double.IsFinite(candidate) || !double.IsFinite(candidateTruePeakDbtp))
            throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        var gain = Math.Min(Math.Max(source - candidate, -GainClampDb), GainClampDb);
        return Math.Min(gain, TruePeakLimitDbtp - candidateTruePeakDbtp);
    }

    /// <summary>Measures the source beside the window (<see cref="NeighbourhoodVoicedRmsDb"/>) and the trimmed
    /// candidate, each at its own rate, then applies <see cref="LevelGainDb(double?, double?, double)"/>. Both buffers
    /// are validated before either side can report NoVoicedAudio.</summary>
    public static double LevelGainDb(ReadOnlySpan<float> source, int sourceSampleRate, int windowStart, int windowEnd,
        ReadOnlySpan<float> candidate, int candidateSampleRate)
    {
        var candidateDb = VoicedRmsDb(candidate, candidateSampleRate);
        var sourceDb = NeighbourhoodVoicedRmsDb(source, sourceSampleRate, windowStart, windowEnd);
        if (candidateDb is null) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.NoVoicedAudio);
        return LevelGainDb(sourceDb, candidateDb, TruePeakDbtp(candidate, candidateSampleRate));
    }

    /// <summary>20·log10(max |x|), or −∞ for silence. QA's peakDbfs is this value for the final mixed window after
    /// gain (§8.11 item 2).</summary>
    public static double SamplePeakDbfs(ReadOnlySpan<float> samples)
    {
        var peak = 0f;
        foreach (var value in samples)
        {
            if (!float.IsFinite(value)) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
            peak = Math.Max(peak, Math.Abs(value));
        }
        return 20 * Math.Log10(peak);
    }

    /// <summary>The ITU-R BS.1770-4 Annex 2 true peak in dBTP, or −∞ for silence: 4× oversampling below 96 kHz, 2×
    /// below 192 kHz, and the sample peak from 192 kHz. Annex 2 publishes only the 4× filter, so 2× uses its even
    /// phases, 0 and 2. The buffer is silent outside its bounds, so every output of the full interpolation counts,
    /// including the ringing of an abrupt start or end. No phase lands on an input sample, and phases 1 and 2 pass DC at
    /// 0.973, so the filter alone can read below the samples; the true peak is the larger of the two (lead decision).
    /// Both choices are conservative: a higher true peak can only lower the gain cap.</summary>
    // Spec: voice-lab.md §8.7 item 2 (the −1 dBTP limit), measured as in ITU-R BS.1770-4 Annex 2.
    public static double TruePeakDbtp(ReadOnlySpan<float> samples, int sampleRate)
    {
        Validate(samples, sampleRate);
        var factor = Oversampling(sampleRate);
        if (factor == 1 || samples.IsEmpty) return SamplePeakDbfs(samples);
        const int taps = 12, history = taps - 1;
        // The sample peak, taken while padding, is where the search for a larger interpolated value starts.
        var padded = new double[samples.Length + 2 * history];
        var peak = 0.0;
        for (var index = 0; index < samples.Length; index++)
        {
            padded[history + index] = samples[index];
            peak = Math.Max(peak, Math.Abs(padded[history + index]));
        }
        var coefficients = TruePeakTaps;
        for (var n = 0; n < samples.Length + history; n++)
            for (var phase = 0; phase < 4; phase += 4 / factor)
            {
                var sum = 0.0;
                for (var tap = 0; tap < taps; tap++) sum += coefficients[phase * taps + tap] * padded[n + history - tap];
                peak = Math.Max(peak, Math.Abs(sum));
            }
        return 20 * Math.Log10(peak);
    }

    /// <summary>BS.1770-4 momentary loudness in LUFS of the 400 ms window that starts at windowStart, or −∞ for a
    /// silent window: −0.691 + 10·log10 of the K-weighted mean square, with channel weight 1. The K-weighting runs from
    /// sample 0 with zero state, so the samples before the window are its context.</summary>
    public static double MomentaryLufs(ReadOnlySpan<float> samples, int sampleRate, int windowStart)
    {
        Validate(samples, sampleRate);
        var window = SampleCount(MomentarySeconds, sampleRate);
        if (windowStart < 0 || windowStart > samples.Length - window)
            throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        return Loudness(KWeighted(samples[..(windowStart + window)], sampleRate), windowStart, windowStart + window);
    }

    /// <summary>The momentary jump across one seam (§8.11 item 3): |M_after − M_before| over [seam − 0.4 s, seam) and
    /// [seam, seam + 0.4 s) of the mixed audio on its own sample grid. A window cut short by the buffer edge is
    /// shortened, and one below 0.1 s throws InsufficientContext. Each window's loudness is floored at −70 LUFS, so the
    /// jump is always finite: two windows at the floor give 0, and a cut from room tone to digital silence gives the room
    /// tone's distance from −70 LUFS, which QA can catch.</summary>
    public static double SeamJumpLu(ReadOnlySpan<float> samples, int sampleRate, int seamSample) =>
        SeamJumps(samples, sampleRate, [seamSample])[0];

    /// <summary>A recipe's qa.lufsJumpLu: the largest jump over its seams that are not none, or 0 without such a
    /// seam.</summary>
    public static double LufsJumpLu(ReadOnlySpan<float> samples, int sampleRate, IReadOnlyList<int> seamSamples)
    {
        var jumps = SeamJumps(samples, sampleRate, seamSamples);
        return jumps.Length == 0 ? 0 : jumps.Max();
    }

    // Spec: voice-lab.md §8.11 item 3; each window is floored at −70 LUFS, the BS.1770 absolute gate (lead decision).
    internal static double[] SeamJumps(ReadOnlySpan<float> samples, int sampleRate, IReadOnlyList<int> seamSamples)
    {
        Validate(samples, sampleRate);
        var window = SampleCount(MomentarySeconds, sampleRate);
        var minimum = SampleCount(MinimumSeamWindowSeconds, sampleRate);
        foreach (var seam in seamSamples)
        {
            if (seam < 0 || seam > samples.Length) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
            if (seam - Math.Max(0, seam - window) < minimum || Math.Min(samples.Length, seam + window) - seam < minimum)
                throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InsufficientContext);
        }
        if (seamSamples.Count == 0) return [];
        var weighted = KWeighted(samples, sampleRate);
        var jumps = new double[seamSamples.Count];
        for (var index = 0; index < jumps.Length; index++)
        {
            var seam = seamSamples[index];
            var before = Loudness(weighted, Math.Max(0, seam - window), seam);
            var after = Loudness(weighted, seam, Math.Min(samples.Length, seam + window));
            jumps[index] = Math.Abs(Math.Max(after, SilenceGateLufs) - Math.Max(before, SilenceGateLufs));
        }
        return jumps;
    }

    /// <summary>The §8.6 flatness of a trimmed candidate: momentary loudness every 100 ms (400 ms windows from sample 0,
    /// whole windows only) without the windows below −70 LUFS, then 1 − min(1, population stdev ÷ 6). Fewer than two
    /// windows give 1.</summary>
    public static double Flatness(ReadOnlySpan<float> samples, int sampleRate) => FlatnessMeasurement(samples, sampleRate).Flatness;

    internal static (int Windows, double Stdev, double Flatness) FlatnessMeasurement(ReadOnlySpan<float> samples, int sampleRate)
    {
        Validate(samples, sampleRate);
        var window = SampleCount(MomentarySeconds, sampleRate);
        var step = SampleCount(FlatnessStepSeconds, sampleRate);
        var weighted = KWeighted(samples, sampleRate);
        var levels = new List<double>();
        for (var start = 0; start + window <= samples.Length; start += step)
        {
            var level = Loudness(weighted, start, start + window);
            if (level >= SilenceGateLufs) levels.Add(level);
        }
        if (levels.Count < 2) return (levels.Count, 0, 1);
        var sum = 0.0;
        foreach (var level in levels) sum += level;
        var mean = sum / levels.Count;
        var squares = 0.0;
        foreach (var level in levels) squares += (level - mean) * (level - mean);
        var stdev = Math.Sqrt(squares / levels.Count);
        return (levels.Count, stdev, 1 - Math.Min(1, stdev / FlatnessStdevScale));
    }

    // The RMS in dBFS over the voiced 10 ms frames of before and then after, or null when no frame is voiced. Each side
    // is framed from its own first sample, and its trailing partial frame is ignored.
    private static double? VoicedLevel(ReadOnlySpan<float> before, ReadOnlySpan<float> after, int sampleRate)
    {
        var size = SampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate);
        var threshold = VoiceLabPatchConstants.VOICED_FRAME_LEVEL;
        var total = 0.0;
        var voicedFrames = 0;
        AddVoicedFrames(before);
        AddVoicedFrames(after);
        return voicedFrames == 0 ? null : 20 * Math.Log10(Math.Sqrt(total / ((long)voicedFrames * size)));

        void AddVoicedFrames(ReadOnlySpan<float> side)
        {
            for (var start = 0; start + size <= side.Length; start += size)
            {
                var sum = 0.0;
                for (var index = start; index < start + size; index++)
                {
                    var value = (double)side[index];
                    sum += value * value;
                }
                if (Math.Sqrt(sum / size) > threshold)
                {
                    total += sum;
                    voicedFrames++;
                }
            }
        }
    }

    internal static int Oversampling(int sampleRate) => sampleRate < 96_000 ? 4 : sampleRate < 192_000 ? 2 : 1;

    // The shelf's mid-band numerator term is Vh raised to this exponent rather than √Vh.
    internal const double ShelfMidBandExponent = 0.4996667741545416;
    // The RLB high-pass numerator, left unnormalised by a0.
    internal static readonly (double B0, double B1, double B2) HighPassNumerator = (1, -2, 1);

    // The BS.1770 pre-filter shelf and RLB high-pass for sampleRate, by bilinear transform of their analog prototypes,
    // prewarped at each centre frequency. The analog values, ShelfMidBandExponent and HighPassNumerator follow
    // libebur128's derivation (MIT; no code is copied), which reproduces the published 48 kHz coefficients.
    // Spec: voice-lab.md §8.11 item 3 (BS.1770); the published 48 kHz K-weighting coefficients are the normative anchor.
    internal static (VoiceLabBiquad Shelf, VoiceLabBiquad HighPass) KWeighting(int sampleRate)
    {
        var k = Math.Tan(Math.PI * 1681.974450955533 / sampleRate);
        var q = 0.7071752369554196;
        var vh = Math.Pow(10, 3.999843853973347 / 20);
        var vb = Math.Pow(vh, ShelfMidBandExponent);
        var a0 = 1 + k / q + k * k;
        var shelf = new VoiceLabBiquad((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0);
        k = Math.Tan(Math.PI * 38.13547087602444 / sampleRate);
        q = 0.5003270373238773;
        a0 = 1 + k / q + k * k;
        return (shelf, new VoiceLabBiquad(HighPassNumerator.B0, HighPassNumerator.B1, HighPassNumerator.B2,
            2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0));
    }

    // The samples through both K-weighting stages in Float64, each in direct form I from zero state.
    internal static double[] KWeighted(ReadOnlySpan<float> samples, int sampleRate)
    {
        var (shelf, highPass) = KWeighting(sampleRate);
        var output = new double[samples.Length];
        for (var index = 0; index < samples.Length; index++) output[index] = samples[index];
        foreach (var stage in new[] { shelf, highPass })
        {
            double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
            for (var index = 0; index < output.Length; index++)
            {
                var value = output[index];
                var filtered = stage.B0 * value + stage.B1 * x1 + stage.B2 * x2 - stage.A1 * y1 - stage.A2 * y2;
                x2 = x1; x1 = value; y2 = y1; y1 = filtered;
                output[index] = filtered;
            }
        }
        return output;
    }

    internal static double Loudness(ReadOnlySpan<double> weighted, int start, int end)
    {
        var sum = 0.0;
        for (var index = start; index < end; index++) sum += weighted[index] * weighted[index];
        return -0.691 + 10 * Math.Log10(sum / (end - start));
    }

    // ITU-R BS.1770-4 (10/2015), Annex 2: the 48-tap, 4-phase FIR interpolating filter, phase 0 to phase 3.
    private static ReadOnlySpan<double> TruePeakTaps =>
    [
        0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
        0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500,
        -0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
        0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375,
        -0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
        0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875,
        -0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
        0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750,
    ];

    internal static int SampleCount(double seconds, int sampleRate) => (int)EditingMath.Round(seconds * sampleRate);

    internal static void Validate(ReadOnlySpan<float> samples, int sampleRate)
    {
        if (sampleRate <= 0 || SampleCount(VoiceLabPatchConstants.RMS_FRAME, sampleRate) < 1) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        foreach (var value in samples)
            if (!float.IsFinite(value)) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
    }
}
