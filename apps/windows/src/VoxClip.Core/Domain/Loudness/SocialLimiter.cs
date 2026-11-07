using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Loudness;

/// <summary>The social-loudness gain and transparent true-peak limiter (ADR-R47, amended 2026-11-08; doc/publishing.md
/// "Loudness"), streamed over interleaved Float32 frames. Mac Core SocialLimiter is the same definition; shared vectors:
/// shared/fixtures/loudness/social-limiter-cases.json.
/// <para>Each frame is gained, z = (double)x × 10^(gain/20). Not limiting, the output is (float)z, at once. Limiting:</para>
/// <list type="number">
/// <item>Detection point n (n = 0 … frames + 10; silence outside the mix) reads frames n−11 … n: p(n) is the largest over the
/// channels of |z(n)| and the four BS.1770-4 Annex 2 phase outputs over those 12 frames. Its overshoot is
/// R(n) = 20·log10 p(n) + 1 dB when p(n) &gt; 10^(−1/20), else 0.</item>
/// <item>Hold: frame m needs H(m) = max R(m … m+11), every point that reads it.</item>
/// <item>Attack over the lookahead L = round(0.005 s × rate) frames: A(m) = max over j = 0…L of H(m+j)·(½ + ½·cos(πj/L)).</item>
/// <item>Release, stereo-linked: E(m) = max(A(m), d), d = E(m−1)·e^(−1/(0.08 s × rate)), with d = 0 once it is below 0.01 dB.
/// E(−1) = 0.</item>
/// <item>Output: (float)(z × 10^(−E/20)) for every channel; (float)z where E = 0. No makeup gain, no knee.</item>
/// </list>
/// <para>The largest E is the largest R, exactly the true peak after the gain minus the ceiling. Output lags input by
/// L + 11 frames; <see cref="Finish"/> flushes them.</para></summary>
public sealed class SocialLimiter
{
    /// <summary>5 ms.</summary>
    public const double LookaheadSeconds = 0.005;
    /// <summary>80 ms.</summary>
    public const double ReleaseSeconds = 0.08;
    /// <summary>0.01 dB: a release below it ends.</summary>
    public const double ReleaseFloorDb = 0.01;
    // Inputs one detection point reads.
    internal const int DetectionTaps = 12;

    private readonly double gain;
    private readonly int lookahead;
    private readonly double threshold;
    private readonly double releaseFactor;
    private readonly double[] shape;
    // Gained frames, slot i % (latency + 1).
    private readonly double[] gained;
    // Per frame, the largest |z| over the channels, slot i % 12.
    private readonly double[] magnitudes = new double[DetectionTaps];
    // Overshoot R, slot n % 12.
    private readonly double[] overshoots = new double[DetectionTaps];
    // Pending attack A, slot m % (lookahead + 1).
    private readonly double[] attack;
    private readonly float[] silence;
    private long inputs;
    private long lastOvershoot = long.MinValue / 2;
    private double reduction;
    // The largest Σ|tap| of a phase: no phase output exceeds it times the largest input it reads.
    private static readonly double PhaseGain = Enumerable.Range(0, 4)
        .Max(phase => Enumerable.Range(0, 12).Sum(tap => Math.Abs(VoiceLabLoudness.TruePeakTaps[phase * 12 + tap])));

    /// <summary>A limiter at <paramref name="gainDb"/> for interleaved frames of <paramref name="channels"/> channels; with
    /// <paramref name="limiting"/> false it applies the gain alone, with no latency.</summary>
    public SocialLimiter(double gainDb, bool limiting, int sampleRate, int channels)
    {
        if (!double.IsFinite(gainDb) || sampleRate <= 0 || sampleRate >= 96_000 || channels is < 1 or > 8)
            throw new VoiceLabAudioMathException(VoiceLabAudioMathErrorCode.InvalidInput);
        GainDb = gainDb; Limiting = limiting; Channels = channels;
        gain = Math.Pow(10, gainDb / 20);
        lookahead = (int)EditingMath.Round(LookaheadSeconds * sampleRate);
        Latency = limiting ? lookahead + DetectionTaps - 1 : 0;
        threshold = Math.Pow(10, SocialLoudness.CeilingDbtp / 20);
        releaseFactor = Math.Exp(-1 / (ReleaseSeconds * sampleRate));
        var span = (double)lookahead;
        shape = Enumerable.Range(0, lookahead + 1).Select(index => 0.5 + 0.5 * Math.Cos(Math.PI * index / span)).ToArray();
        gained = new double[limiting ? (Latency + 1) * channels : 0];
        attack = new double[lookahead + 1];
        silence = new float[channels];
    }

    /// <summary>The gain, dB.</summary>
    public double GainDb { get; }
    /// <summary>Whether the limiter runs; false applies the gain alone.</summary>
    public bool Limiting { get; }
    /// <summary>The channel count.</summary>
    public int Channels { get; }
    /// <summary>Frames the output lags the input: 0 for gain alone.</summary>
    public int Latency { get; }
    /// <summary>The largest reduction so far, dB.</summary>
    public double MaximumReductionDb { get; private set; }
    /// <summary>Output frames under any reduction.</summary>
    public long LimitedFrames { get; private set; }
    /// <summary>Output frames so far.</summary>
    public long Frames { get; private set; }
    /// <summary>The share of output frames under any reduction, percent.</summary>
    public double LimitedPercent => Frames > 0 ? 100.0 * LimitedFrames / Frames : 0;

    /// <summary>Takes <c>input.Length / Channels</c> whole frames and writes the frames now due to <paramref name="output"/>,
    /// which has room for as many; returns how many it wrote.</summary>
    public int Process(ReadOnlySpan<float> input, Span<float> output)
    {
        var count = input.Length / Channels;
        if (count <= 0) return 0;
        if (output.Length < count * Channels) throw new ArgumentException("The output has no room for the frames.", nameof(output));
        if (!Limiting)
        {
            for (var index = 0; index < count * Channels; index++) output[index] = (float)(input[index] * gain);
            Frames += count;
            return count;
        }
        var written = 0;
        for (var frame = 0; frame < count; frame++)
            if (Push(input.Slice(frame * Channels, Channels), output.Slice(written * Channels))) written++;
        return written;
    }

    /// <summary>The last <see cref="Latency"/> frames (fewer when fewer came in), written to <paramref name="output"/>, which has
    /// room for them; returns how many it wrote.</summary>
    public int Finish(Span<float> output)
    {
        if (!Limiting) return 0;
        var written = 0;
        for (var index = 0; index < Latency; index++)
            if (Push(silence, output.Slice(written * Channels))) written++;
        return written;
    }

    // One input frame in; true when it completed an output frame at the start of target.
    private bool Push(ReadOnlySpan<float> frame, Span<float> target)
    {
        var index = inputs++;
        var slot = (int)(index % (Latency + 1));
        var largest = 0.0;
        for (var channel = 0; channel < Channels; channel++)
        {
            var value = frame[channel] * gain;
            gained[slot * Channels + channel] = value;
            largest = Math.Max(largest, Math.Abs(value));
        }
        magnitudes[index % DetectionTaps] = largest;
        // Detection point index reads frames index-11 ... index.
        var bound = 0.0;
        foreach (var value in magnitudes) if (value > bound) bound = value;
        var peak = largest;
        if (bound * PhaseGain > threshold) peak = Math.Max(peak, InterpolatedPeak(index));
        var over = peak > threshold ? 20 * Math.Log10(peak) - SocialLoudness.CeilingDbtp : 0;
        overshoots[index % DetectionTaps] = over;
        if (over > 0) lastOvershoot = index;
        // Frame index - 11 now has every point that reads it.
        var held = index - DetectionTaps + 1;
        if (held < 0) return false;
        var hold = 0.0;
        if (index - lastOvershoot < DetectionTaps) foreach (var value in overshoots) if (value > hold) hold = value;
        var span = lookahead + 1;
        attack[(int)(held % span)] = hold;
        if (hold > 0)
        {
            for (var step = 1; step <= lookahead && held - step >= 0; step++)
            {
                var candidate = shape[step] * hold;
                var position = (int)((held - step) % span);
                if (candidate > attack[position]) attack[position] = candidate;
            }
        }
        var output = held - lookahead;
        if (output < 0) return false;
        var released = reduction * releaseFactor;
        if (released < ReleaseFloorDb) released = 0;
        var current = attack[(int)(output % span)];
        reduction = current > released ? current : released;
        var factor = reduction > 0 ? Math.Pow(10, -reduction / 20) : 1;
        var source = (int)(output % (Latency + 1)) * Channels;
        for (var channel = 0; channel < Channels; channel++) target[channel] = (float)(gained[source + channel] * factor);
        Frames++;
        if (reduction > 0)
        {
            LimitedFrames++;
            if (reduction > MaximumReductionDb) MaximumReductionDb = reduction;
        }
        return true;
    }

    // The largest |output| over the channels of the four Annex 2 phases at detection point index, which reads the gained frames
    // index-11 ... index (silence before the first).
    private double InterpolatedPeak(long index)
    {
        var peak = 0.0;
        var ring = Latency + 1;
        var reach = (int)Math.Min(DetectionTaps, index + 1);
        var taps = VoiceLabLoudness.TruePeakTaps;
        for (var channel = 0; channel < Channels; channel++)
        {
            for (var phase = 0; phase < 4; phase++)
            {
                // In tap order from zero, as the generator sums.
                var sum = 0.0;
                for (var tap = 0; tap < reach; tap++) sum += taps[12 * phase + tap] * gained[(int)((index - tap) % ring) * Channels + channel];
                if (Math.Abs(sum) > peak) peak = Math.Abs(sum);
            }
        }
        return peak;
    }
}
