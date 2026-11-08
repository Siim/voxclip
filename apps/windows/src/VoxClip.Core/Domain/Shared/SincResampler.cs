namespace VoxClip.Core.Domain.Shared;

/// <summary>The mono windowed-sinc resampler (Blackman window, cutoff 0.94 of the lower Nyquist, 32 zero crossings) fed in pieces:
/// the output of every <see cref="Process"/> call and then <see cref="Finish"/>, joined, is the whole input resampled at once, bit
/// for bit. Between calls it keeps only the input its kernel still reads, so a long export resamples in constant memory, and it
/// writes into the caller's buffer. <see cref="VoiceLab.VoiceConsentAudio.Resample(ReadOnlySpan{float}, int, int)"/> runs on it.</summary>
public sealed class SincResampler
{
    private readonly int rate;
    private readonly int targetRate;
    private readonly int radius;
    private readonly int phases;
    private readonly double[][] kernels;
    // The input kept from earlier calls: absolute indices [held, received).
    private float[] kept = [];
    private long held;
    private long received;
    private long produced;

    /// <summary>A resampler from <paramref name="rate"/> to <paramref name="targetRate"/>, both positive.</summary>
    public SincResampler(int rate, int targetRate)
    {
        if (rate <= 0 || targetRate <= 0) throw new ArgumentOutOfRangeException(nameof(rate));
        this.rate = rate; this.targetRate = targetRate;
        var cutoff = 0.94 * Math.Min(1, targetRate / (double)rate);
        radius = (int)Math.Ceiling(32 / cutoff);
        var divisor = rate;
        var remainder = targetRate;
        while (remainder != 0) (divisor, remainder) = (remainder, divisor % remainder);
        phases = targetRate / divisor;
        kernels = new double[phases][];
        for (var phase = 0; phase < phases; phase++)
        {
            var fraction = (long)phase * rate % targetRate / (double)targetRate;
            var weights = new double[radius * 2 + 1];
            for (var tap = -radius; tap <= radius; tap++)
            {
                var distance = tap - fraction;
                if (Math.Abs(distance) > radius) continue;
                var position = cutoff * distance;
                var sinc = Math.Abs(position) < 1e-12 ? 1 : Math.Sin(Math.PI * position) / (Math.PI * position);
                var window = 0.42 + 0.5 * Math.Cos(Math.PI * distance / radius) + 0.08 * Math.Cos(2 * Math.PI * distance / radius);
                weights[tap + radius] = cutoff * sinc * window;
            }
            var sum = weights.Sum();
            for (var index = 0; index < weights.Length; index++) weights[index] /= sum;
            kernels[phase] = weights;
        }
    }

    /// <summary>The most samples the next <see cref="Process"/> of <paramref name="inputLength"/> samples, or <see cref="Finish"/> after
    /// it, writes.</summary>
    public int MaximumOutput(int inputLength) => (int)((received + inputLength) * targetRate / rate - produced);

    /// <summary>Writes the output samples <paramref name="mono"/> completes into <paramref name="output"/> (room for
    /// <see cref="MaximumOutput"/>) and returns how many.</summary>
    public int Process(ReadOnlySpan<float> mono, Span<float> output)
    {
        var start = received;
        received += mono.Length;
        // An output sample is complete once every input its kernel reads has arrived.
        var ready = Math.Max(produced, (received - radius) * targetRate / rate);
        while (ready > produced && Source(ready - 1) + radius >= received) ready--;
        var written = Emit(ready, received, mono, start, output);
        Keep(mono, start);
        return written;
    }

    /// <summary>Writes the remaining output samples, now that the input has ended (the kernel stops at the input's last sample),
    /// into <paramref name="output"/> and returns how many.</summary>
    public int Finish(Span<float> output) => Emit(received * targetRate / rate, received, [], received, output);

    private long Source(long index) => index * rate / targetRate;

    // Keeps the input from the first one a later output sample reads.
    private void Keep(ReadOnlySpan<float> mono, long start)
    {
        var from = Math.Max(held, Source(produced) - radius);
        var length = (int)Math.Max(0, received - from);
        if (kept.Length < length) Array.Resize(ref kept, Math.Max(length, kept.Length * 2));
        var fromKept = (int)Math.Max(0, Math.Min(start, received) - from);
        if (fromKept > 0) kept.AsSpan((int)(from - held), fromKept).CopyTo(kept);
        mono[(int)Math.Max(0, from - start)..].CopyTo(kept.AsSpan(fromKept));
        held = from;
    }

    private int Emit(long until, long length, ReadOnlySpan<float> mono, long start, Span<float> output)
    {
        var total = (int)Math.Max(0, until - produced);
        if (output.Length < total) throw new ArgumentException("The output has no room for the resampled samples.", nameof(output));
        for (var offset = 0; offset < total; offset++)
        {
            var index = produced + offset;
            var source = Source(index);
            var weights = kernels[index % phases];
            var sum = 0.0;
            for (var tap = Math.Max(-radius, -source); tap <= Math.Min(radius, length - 1 - source); tap++)
            {
                var at = source + tap;
                sum += (double)(at >= start ? mono[(int)(at - start)] : kept[(int)(at - held)]) * weights[tap + radius];
            }
            output[offset] = (float)sum;
        }
        produced += total;
        return total;
    }
}
