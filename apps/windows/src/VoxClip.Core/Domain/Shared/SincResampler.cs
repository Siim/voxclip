namespace VoxClip.Core.Domain.Shared;

/// <summary>The mono windowed-sinc resampler (Blackman window, cutoff 0.94 of the lower Nyquist, 32 zero crossings) fed in pieces:
/// the output of every <see cref="Process"/> call and then <see cref="Finish"/>, joined, is the whole input resampled at once, bit
/// for bit. It holds only the input the next output samples still read, so a long export resamples in constant memory.
/// <see cref="VoiceLab.VoiceConsentAudio.Resample(ReadOnlySpan{float}, int, int)"/> runs on it.</summary>
public sealed class SincResampler
{
    private readonly int rate;
    private readonly int targetRate;
    private readonly int radius;
    private readonly int phases;
    private readonly double[][] kernels;
    private float[] input = new float[4096];
    // The input held: absolute indices [held, held + count).
    private long held;
    private int count;
    private long received;
    private long produced;
    private float[] output = [];

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

    /// <summary>The output samples <paramref name="mono"/> completes; the span is valid until the next call.</summary>
    public ReadOnlySpan<float> Process(ReadOnlySpan<float> mono)
    {
        Hold(mono);
        // An output sample is complete once every input its kernel reads has arrived.
        var ready = Math.Max(produced, (received - radius) * targetRate / rate);
        while (ready > produced && Source(ready - 1) + radius >= received) ready--;
        return Emit(ready, received);
    }

    /// <summary>The remaining output samples, now that the input has ended: the kernel stops at the input's last sample.</summary>
    public ReadOnlySpan<float> Finish() => Emit(received * targetRate / rate, received);

    private long Source(long index) => index * rate / targetRate;

    private void Hold(ReadOnlySpan<float> mono)
    {
        // Drop the input no later output reads.
        var keep = Math.Max(held, Math.Min(held + count, Source(produced) - radius));
        var dropped = (int)(keep - held);
        if (dropped > 0)
        {
            input.AsSpan(dropped, count - dropped).CopyTo(input);
            count -= dropped; held = keep;
        }
        if (input.Length < count + mono.Length) Array.Resize(ref input, Math.Max(input.Length * 2, count + mono.Length));
        mono.CopyTo(input.AsSpan(count));
        count += mono.Length;
        received += mono.Length;
    }

    private ReadOnlySpan<float> Emit(long until, long length)
    {
        var total = (int)Math.Max(0, until - produced);
        if (output.Length < total) output = new float[total];
        for (var offset = 0; offset < total; offset++)
        {
            var index = produced + offset;
            var source = Source(index);
            var weights = kernels[index % phases];
            var sum = 0.0;
            for (var tap = Math.Max(-radius, -source); tap <= Math.Min(radius, length - 1 - source); tap++)
                sum += (double)input[source + tap - held] * weights[tap + radius];
            output[offset] = (float)sum;
        }
        produced += total;
        return output.AsSpan(0, total);
    }
}
