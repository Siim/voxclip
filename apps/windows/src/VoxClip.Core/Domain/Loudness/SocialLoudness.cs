using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Loudness;

/// <summary>How an export sets its level (ADR-R47, amended 2026-11-08). Social, the default for every export, gains the
/// exported mix to −14 LUFS and holds its true peak at −1 dBTP with a transparent true-peak limiter; Off writes the mix as
/// composed.</summary>
public enum ExportLoudness
{
    /// <summary>−14 LUFS integrated by one gain, true peak held at −1 dBTP by the limiter.</summary>
    Social,
    /// <summary>The mix as composed.</summary>
    Off
}

/// <summary>Why the social gain is what it is.</summary>
public enum SocialLoudnessLimit
{
    /// <summary>The gain takes the clip to −14 LUFS.</summary>
    None,
    /// <summary>The gain wanted more than +12 dB or less than −20 dB and stopped there.</summary>
    GainLimit,
    /// <summary>The limiter would have reduced more than 9 dB, so the gain stopped where it reduces exactly 9 dB and the
    /// clip lands quieter than −14 LUFS rather than squashed.</summary>
    ReductionCap,
    /// <summary>The gated loudness is undefined (digital silence, everything below −70 LUFS, or shorter than one 400 ms
    /// block), so the gain is 0 dB and nothing is limited.</summary>
    Silent
}

/// <summary>The gain the rule chose, why, and whether the limiter has work: the true peak after the gain is over
/// −1 dBTP.</summary>
public readonly record struct SocialLoudnessDecision(double GainDb, SocialLoudnessLimit Limit, bool Limiting = false)
{
    /// <summary>The reduction cap set the gain; it is the only reason a clip is reported capped.</summary>
    public bool Capped => Limit == SocialLoudnessLimit.ReductionCap;
}

/// <summary>The next step of landing on target: simulate <see cref="GainDb"/> offline, or, when <see cref="Settled"/>,
/// export at <see cref="Decision"/>.</summary>
public readonly record struct SocialLoudnessLanding(bool Settled, double GainDb, SocialLoudnessDecision Decision);

/// <summary>What an export reports about its loudness (the export JSON's <c>loudness</c>, ADR-R47). MeasuredLufs is the
/// composed mix's, before the gain; OutputLufs and TruePeakDbtp are the exported PCM's, after the gain and the limiter.
/// LimiterMaxReductionDb is the limiter's largest reduction and LimitedPercent the share of frames under any reduction, both
/// 0 when the gain alone keeps the true peak under −1 dBTP. A silent mix has no loudness and no gain; digital silence has no
/// true peak either.</summary>
public sealed record SocialLoudnessReport(double? MeasuredLufs, double GainDb, double? OutputLufs, double? TruePeakDbtp, bool Capped,
    double LimiterMaxReductionDb = 0, double LimitedPercent = 0)
{
    /// <summary>The app log's line: numbers only, no paths or names (the Mac's <c>logLine</c>).</summary>
    public string LogLine()
    {
        static string Number(double? value) => value is { } number ? number.ToString("0.00", CultureInfo.InvariantCulture) : "none";
        return $"loudness measured={Number(MeasuredLufs)} gain={Number(GainDb)} output={Number(OutputLufs)} truePeak={Number(TruePeakDbtp)} capped={(Capped ? "true" : "false")} maxReduction={Number(LimiterMaxReductionDb)} limited={Number(LimitedPercent)}";
    }
}

/// <summary>Social loudness (ADR-R47, amended 2026-11-08): the exported mix lands at −14 LUFS integrated (ITU-R BS.1770-4 with
/// EBU R128 gating) by one gain, within −20…+12 dB, and a transparent true-peak limiter (<see cref="SocialLimiter"/>) holds
/// the true peak at −1.0 dBTP. The limiter's largest reduction is exactly the true peak after the gain minus the ceiling, so
/// the gain is lowered until that is at most 9 dB. Offline pre-passes simulate the gain and the limiter, and a limited,
/// uncapped gain is corrected by what the limiter took (<see cref="Landing"/>). Mac Core SocialLoudness; shared vectors
/// shared/fixtures/loudness/social-loudness-cases.json and social-limiter-cases.json.</summary>
public static class SocialLoudness
{
    /// <summary>−14 LUFS.</summary>
    public const double TargetLufs = -14.0;
    /// <summary>−1 dBTP.</summary>
    public const double CeilingDbtp = -1.0;
    /// <summary>+12 dB.</summary>
    public const double MaximumBoostDb = 12.0;
    /// <summary>−20 dB.</summary>
    public const double MaximumCutDb = -20.0;
    /// <summary>9 dB: the most the limiter may reduce.</summary>
    public const double MaximumReductionDb = 9.0;
    /// <summary>A first simulation within this of the target lands with one correction; beyond it, a second one is run.</summary>
    public const double LandingToleranceLu = 0.5;
    internal const double AbsoluteGateLufs = -70.0;
    internal const double RelativeGateLu = -10.0;
    internal const double StepSeconds = 0.1;
    internal const int BlockSteps = 4;

    /// <summary>The plan from the measured mix alone. A null loudness (silent) gets 0 dB and no limiting.</summary>
    public static SocialLoudnessDecision Decide(double? measuredLufs, double? truePeakDbtp)
    {
        if (measuredLufs is not { } measured || !double.IsFinite(measured)) return new(0, SocialLoudnessLimit.Silent);
        var wanted = TargetLufs - measured;
        var gain = Math.Min(Math.Max(wanted, MaximumCutDb), MaximumBoostDb);
        var limit = gain == wanted ? SocialLoudnessLimit.None : SocialLoudnessLimit.GainLimit;
        if (truePeakDbtp is not { } peak || !double.IsFinite(peak)) return new(gain, limit);
        var cap = CeilingDbtp + MaximumReductionDb - peak;
        if (gain > cap) { gain = cap; limit = SocialLoudnessLimit.ReductionCap; }
        return new(gain, limit, peak + gain > CeilingDbtp);
    }

    /// <summary>Landing on target from offline pre-passes that simulate the gain and the limiter. <paramref name="trials"/> are
    /// the (gain, simulated output LUFS) pairs so far; the answer is the next gain to simulate or the settled decision. Only an
    /// uncapped, limited plan moves: one simulation and one correction by target minus what it measured; when the limiter took
    /// more than 0.5 LU, the corrected gain is simulated too and a secant step through the two lands it. Every gain stays
    /// within −20…+12 dB and the 9 dB reduction cap.</summary>
    public static SocialLoudnessLanding Landing(SocialLoudnessDecision plan, double? truePeakDbtp, IReadOnlyList<(double GainDb, double? Lufs)> trials)
    {
        ArgumentNullException.ThrowIfNull(trials);
        SocialLoudnessLanding Settled(double gain, SocialLoudnessLimit limit) =>
            new(true, gain, new(gain, limit, (truePeakDbtp ?? double.NegativeInfinity) + gain > CeilingDbtp));
        if (!plan.Limiting || plan.Limit != SocialLoudnessLimit.None || truePeakDbtp is not { } peak) return new(true, plan.GainDb, plan);
        if (trials.Count == 0) return new(false, plan.GainDb, plan);
        var first = trials[0];
        if (first.Lufs is not { } firstLufs) return new(true, plan.GainDb, plan);
        var corrected = Bounded(first.GainDb + TargetLufs - firstLufs, peak);
        if (trials.Count == 1)
        {
            if (Math.Abs(TargetLufs - firstLufs) <= LandingToleranceLu || corrected.GainDb == first.GainDb)
                return Settled(corrected.GainDb, corrected.Limit);
            return new(false, corrected.GainDb, plan);
        }
        var second = trials[1];
        if (second.Lufs is not { } secondLufs) return Settled(second.GainDb, corrected.Limit);
        var slope = (secondLufs - firstLufs) / (second.GainDb - first.GainDb);
        var step = slope > 0.05 ? (TargetLufs - secondLufs) / slope : TargetLufs - secondLufs;
        var landed = Bounded(second.GainDb + step, peak);
        return Settled(landed.GainDb, landed.Limit);
    }

    // A gain kept within −20 dB, +12 dB and the 9 dB reduction cap, and what stopped it.
    internal static (double GainDb, SocialLoudnessLimit Limit) Bounded(double gainDb, double truePeakDbtp)
    {
        var cap = CeilingDbtp + MaximumReductionDb - truePeakDbtp;
        var bound = Math.Min(MaximumBoostDb, cap);
        if (gainDb > bound) return (bound, cap <= MaximumBoostDb ? SocialLoudnessLimit.ReductionCap : SocialLoudnessLimit.GainLimit);
        return (Math.Max(gainDb, MaximumCutDb), SocialLoudnessLimit.None);
    }

    /// <summary>The report of an export at <paramref name="decision"/>. Gain alone (not limiting): the input measurement scaled
    /// by the gain. Limited: <paramref name="output"/>, the meter of the exported PCM, and the limiter's own counts.</summary>
    public static SocialLoudnessReport Report(SocialLoudnessMeasurement measurement, SocialLoudnessDecision decision, SocialLimiter limiter,
        SocialLoudnessMeasurement? output)
    {
        ArgumentNullException.ThrowIfNull(measurement);
        ArgumentNullException.ThrowIfNull(limiter);
        var measured = measurement.IntegratedLufs();
        if (!decision.Limiting || output is null)
            return new(measured, decision.GainDb, measurement.IntegratedLufs(decision.GainDb),
                measurement.TruePeakDbtp is { } peak ? peak + decision.GainDb : null, decision.Capped);
        return new(measured, decision.GainDb, output.IntegratedLufs(), output.TruePeakDbtp, decision.Capped,
            limiter.MaximumReductionDb, limiter.LimitedPercent);
    }

    /// <summary>The linear sample factor of a gain in dB.</summary>
    public static float LinearGain(double gainDb) => (float)Math.Pow(10, gainDb / 20);
}

/// <summary>A measured mix: the K-weighted energy of every whole 100 ms step, summed over the channels, and the true peak.</summary>
public sealed class SocialLoudnessMeasurement
{
    internal SocialLoudnessMeasurement(double[] stepEnergies, int stepFrames, double truePeak)
    { StepEnergies = stepEnergies; StepFrames = stepFrames; TruePeak = truePeak; }

    /// <summary>Σ over channels and the step's frames of the K-weighted sample squared; a trailing partial step is dropped.</summary>
    public IReadOnlyList<double> StepEnergies { get; }
    /// <summary>Frames in one step: round(0.1 s × rate).</summary>
    public int StepFrames { get; }
    /// <summary>The largest of the sample peak and the Annex 2 interpolated peak over every channel, linear.</summary>
    public double TruePeak { get; }
    /// <summary>The true peak in dBTP, or null for digital silence.</summary>
    public double? TruePeakDbtp => TruePeak > 0 ? 20 * Math.Log10(TruePeak) : null;

    /// <summary>BS.1770-4 integrated loudness of the mix scaled by <paramref name="gainDb"/>: 400 ms blocks every 100 ms, the
    /// −70 LUFS absolute gate, then the gate 10 LU below the absolute-gated loudness. Null when no block passes the absolute
    /// gate.</summary>
    public double? IntegratedLufs(double gainDb = 0)
    {
        const int steps = SocialLoudness.BlockSteps;
        if (StepEnergies.Count < steps || StepFrames <= 0) return null;
        var scale = Math.Pow(10, gainDb / 10) / (steps * StepFrames);
        var blocks = new double[StepEnergies.Count - steps + 1];
        for (var index = 0; index < blocks.Length; index++)
        {
            var sum = 0.0;
            for (var step = index; step < index + steps; step++) sum += StepEnergies[step];
            blocks[index] = sum * scale;
        }
        static double Lufs(double meanSquare) => meanSquare > 0 ? -0.691 + 10 * Math.Log10(meanSquare) : double.NegativeInfinity;
        var absolute = blocks.Where(block => Lufs(block) > SocialLoudness.AbsoluteGateLufs).ToArray();
        if (absolute.Length == 0) return null;
        var relative = Lufs(Sum(absolute) / absolute.Length) + SocialLoudness.RelativeGateLu;
        var gated = absolute.Where(block => Lufs(block) > relative).ToArray();
        return Lufs(Sum(gated) / gated.Length);
    }

    // In order, as the Mac's reduce(0, +).
    private static double Sum(double[] values)
    {
        var total = 0.0;
        foreach (var value in values) total += value;
        return total;
    }
}

/// <summary>Streams interleaved Float32 frames into a <see cref="SocialLoudnessMeasurement"/> in O(steps) memory. Each channel
/// runs the BS.1770 K-weighting (VoiceLabLoudness's shelf and RLB high-pass) from zero state and the Annex 2 4× true-peak filter
/// with silence before the first sample and after the last, so the measurement equals VoiceLabLoudness's whole-buffer
/// definitions. Below 96 kHz only; exports measure at 48 kHz.</summary>
public sealed class SocialLoudnessMeter
{
    private readonly VoiceLabBiquad shelf;
    private readonly VoiceLabBiquad highPass;
    private readonly int stepFrames;
    // Per channel: x1, x2, m1, m2, y1, y2.
    private readonly double[] filter;
    // Per channel: the last 11 inputs, oldest first.
    private readonly double[] history;
    private readonly List<double> steps = [];
    private double stepSum;
    private int stepFilled;
    private double peak;
    private double[] squares = [];
    private double[] lane = [];
    // The largest Σ|tap| of a phase: no interpolated value exceeds it times the largest input it reads.
    private static readonly double PhaseGain = Enumerable.Range(0, 4)
        .Max(phase => Enumerable.Range(0, 12).Sum(tap => Math.Abs(VoiceLabLoudness.TruePeakTaps[phase * 12 + tap])));

    /// <summary>A meter for interleaved frames of <paramref name="channels"/> channels at <paramref name="sampleRate"/>.</summary>
    public SocialLoudnessMeter(int sampleRate, int channels)
    {
        if (sampleRate <= 0 || sampleRate >= 96_000 || channels is < 1 or > 8)
            throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        SampleRate = sampleRate; Channels = channels;
        (shelf, highPass) = VoiceLabLoudness.KWeighting(sampleRate);
        stepFrames = (int)EditingMath.Round(SocialLoudness.StepSeconds * sampleRate);
        filter = new double[6 * channels];
        history = new double[11 * channels];
    }

    /// <summary>The sample rate.</summary>
    public int SampleRate { get; }
    /// <summary>The channel count.</summary>
    public int Channels { get; }

    /// <summary>Adds <c>samples.Length / Channels</c> whole frames. A non-finite sample is invalid input.</summary>
    public void Append(ReadOnlySpan<float> samples)
    {
        var frames = samples.Length / Channels;
        if (frames <= 0) return;
        if (squares.Length < frames) squares = new double[frames];
        if (lane.Length < frames + 11) lane = new double[frames + 11];
        Array.Clear(squares, 0, frames);
        for (var channel = 0; channel < Channels; channel++)
        {
            Weigh(samples, frames, channel);
            Interpolate(samples, Channels, channel, frames, channel);
        }
        var index = 0;
        while (index < frames)
        {
            var take = Math.Min(stepFrames - stepFilled, frames - index);
            for (var frame = index; frame < index + take; frame++) stepSum += squares[frame];
            stepFilled += take; index += take;
            if (stepFilled == stepFrames) { steps.Add(stepSum); stepSum = 0; stepFilled = 0; }
        }
    }

    /// <summary>The measurement, after the filter's ringing past the last sample (eleven silent inputs per channel).</summary>
    public SocialLoudnessMeasurement Finish()
    {
        Span<float> zeros = stackalloc float[11];
        if (lane.Length < 22) lane = new double[22];
        for (var channel = 0; channel < Channels; channel++) Interpolate(zeros, 1, 0, 11, channel);
        return new([.. steps], stepFrames, peak);
    }

    // One channel through the shelf and the high-pass; adds y² to squares.
    private void Weigh(ReadOnlySpan<float> samples, int frames, int channel)
    {
        var offset = 6 * channel;
        double x1 = filter[offset], x2 = filter[offset + 1], m1 = filter[offset + 2];
        double m2 = filter[offset + 3], y1 = filter[offset + 4], y2 = filter[offset + 5];
        for (var frame = 0; frame < frames; frame++)
        {
            var value = samples[frame * Channels + channel];
            if (!float.IsFinite(value)) throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
            double x = value;
            var m = shelf.B0 * x + shelf.B1 * x1 + shelf.B2 * x2 - shelf.A1 * m1 - shelf.A2 * m2;
            var y = highPass.B0 * m + highPass.B1 * m1 + highPass.B2 * m2 - highPass.A1 * y1 - highPass.A2 * y2;
            x2 = x1; x1 = x; m2 = m1; m1 = m; y2 = y1; y1 = y;
            squares[frame] += y * y;
        }
        filter[offset] = x1; filter[offset + 1] = x2; filter[offset + 2] = m1;
        filter[offset + 3] = m2; filter[offset + 4] = y1; filter[offset + 5] = y2;
    }

    // One channel's sample peak and Annex 2 interpolated peak. The filter runs only where its bound (the largest input it reads
    // times PhaseGain) could beat the peak so far, which leaves the maximum unchanged.
    private void Interpolate(ReadOnlySpan<float> samples, int stride, int first, int frames, int channel)
    {
        var offset = 11 * channel;
        double largest = 0, current = peak;
        for (var index = 0; index < 11; index++)
        {
            lane[index] = history[offset + index];
            largest = Math.Max(largest, Math.Abs(lane[index]));
        }
        for (var index = 0; index < frames; index++)
        {
            double value = samples[first + index * stride];
            lane[11 + index] = value;
            var magnitude = Math.Abs(value);
            if (magnitude > largest) largest = magnitude;
            if (magnitude > current) current = magnitude;
        }
        if (largest * PhaseGain > current)
        {
            var taps = VoiceLabLoudness.TruePeakTaps;
            for (var phase = 0; phase < 4; phase++)
            {
                var c = taps.Slice(12 * phase, 12);
                for (var x = 11; x < 11 + frames; x++)
                {
                    var sum = c[0] * lane[x] + c[1] * lane[x - 1] + c[2] * lane[x - 2] + c[3] * lane[x - 3] + c[4] * lane[x - 4]
                        + c[5] * lane[x - 5] + c[6] * lane[x - 6] + c[7] * lane[x - 7] + c[8] * lane[x - 8] + c[9] * lane[x - 9]
                        + c[10] * lane[x - 10] + c[11] * lane[x - 11];
                    if (sum > current) current = sum; else if (-sum > current) current = -sum;
                }
            }
        }
        for (var index = 0; index < 11; index++) history[offset + index] = lane[frames + index];
        peak = current;
    }
}
