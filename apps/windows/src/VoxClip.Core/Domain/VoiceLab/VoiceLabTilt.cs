using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>Tone match at render (voice-lab.md §8.7 item 2b, ADR-R44; Mac <c>VoiceLabTilt</c>): a generated take is tilted towards the
/// spectral slope of the original speech beside it. Measured once when the take is processed, stored on the segment as
/// <c>audio.tiltDbPerOctave</c>, and applied before the static gain wherever the take is heard (the take's own mix, the preview and the
/// export), so they all match. Loudness and room tone are unchanged.
///
/// Pure binary64 arithmetic in a fixed order; the vectors are <c>shared/fixtures/voice-lab/tilt-cases.json</c>
/// (<c>tools/fixtures/voice-lab/generate_tilt.py</c>). They use libm (cos, sin, tan, pow, log10), so they are compared within the file's
/// float tolerances.</summary>
public static class VoiceLabTilt
{
    /// <summary>The largest tilt applied either way, in dB per octave.</summary>
    public const double MaximumDbPerOctave = 2.0;
    /// <summary>Tilts are stored in steps of this size; a measured difference that rounds to 0 applies nothing.</summary>
    public const double StepDbPerOctave = 0.1;
    /// <summary>The frequency the tilt pivots on: its gain there is 0 dB.</summary>
    public const double PivotHz = 1_000.0;
    /// <summary>The cascade: one first-order high shelf per two octaves, each with twice the tilt as its gain.</summary>
    public static IReadOnlyList<double> ShelfHz { get; } = [250, 1_000, 4_000];
    /// <summary>One-third-octave band centres, 1 kHz × 2^(b/3) for b = −10…9: 100 Hz to 7.94 kHz.</summary>
    public static IReadOnlyList<int> BandIndices { get; } = Enumerable.Range(-10, 20).ToArray();
    /// <summary>A frame is voiced when its RMS is above −45 dBFS, the <c>VOICED_FRAME</c> of the level match.</summary>
    public static readonly double VoicedRms = Math.Pow(10, -45.0 / 20);
    /// <summary>The fewest bands both measurements must have for a slope.</summary>
    public const int MinimumBands = 4;

    /// <summary>The power spectrum of a signal's voiced frames, summed per one-third-octave band. <see cref="Power"/> is, per band in
    /// <see cref="BandIndices"/> order, the sum over voiced frames and bins of |X[k]|², or null when the band has no bin below Nyquist.</summary>
    public sealed record Bands(int SampleRate, int FrameSize, IReadOnlyList<double?> Power, int Frames)
    {
        /// <summary>Equal when every field and every band's power are (Mac <c>Bands: Equatable</c>).</summary>
        public bool Equals(Bands? other) => other is not null && SampleRate == other.SampleRate && FrameSize == other.FrameSize &&
            Frames == other.Frames && Power.SequenceEqual(other.Power);
        /// <inheritdoc/>
        public override int GetHashCode() => HashCode.Combine(SampleRate, FrameSize, Frames, Power.Count);
    }

    /// <summary>The FFT size for a rate: the smallest power of two at least 40 ms long.</summary>
    public static int FrameSize(int sampleRate)
    {
        var size = 1;
        while (size < sampleRate * 0.04) size *= 2;
        return size;
    }

    /// <summary>The bins [first, end) of band <paramref name="band"/>: centre <c>fc = 1000 × 2^(band/3)</c>, bins k in 1…N/2−1 with
    /// <c>fc × 2^(−1/6) ≤ k × rate / N &lt; fc × 2^(1/6)</c>. Empty (0, 0) when the band's upper edge passes Nyquist.</summary>
    public static (int First, int End) Bins(int band, int sampleRate, int frameSize)
    {
        var centre = PivotHz * Math.Pow(2, band / 3.0);
        double lower = centre * Math.Pow(2, -1.0 / 6), upper = centre * Math.Pow(2, 1.0 / 6);
        if (upper > sampleRate / 2.0) return (0, 0);
        var spacing = (double)sampleRate / frameSize;
        var first = 1;
        while (first < frameSize / 2 && first * spacing < lower) first++;
        var end = first;
        while (end < frameSize / 2 && end * spacing < upper) end++;
        return (first, end);
    }

    /// <summary>The bands of <paramref name="sides"/>, each framed on its own grid from its first sample: Hann-windowed (periodic) frames of
    /// <see cref="FrameSize"/> samples every half frame, whole frames only; a frame counts when its own RMS, before the window, is above
    /// <see cref="VoicedRms"/>.</summary>
    public static Bands Measure(IReadOnlyList<ReadOnlyMemory<float>> sides, int sampleRate)
    {
        var size = FrameSize(sampleRate);
        var ranges = BandIndices.Select(band => Bins(band, sampleRate, size)).ToArray();
        var power = ranges.Select(range => range.End > range.First ? 0.0 : (double?)null).ToArray();
        var frames = 0;
        var window = new double[size];
        for (var index = 0; index < size; index++) window[index] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * index / size);
        var real = new double[size];
        var imaginary = new double[size];
        foreach (var memory in sides)
        {
            var side = memory.Span;
            for (var start = 0; side.Length - start >= size; start += size / 2)
            {
                var energy = 0.0;
                for (var index = 0; index < size; index++) { var value = (double)side[start + index]; energy += value * value; }
                if (Math.Sqrt(energy / size) <= VoicedRms) continue;
                for (var index = 0; index < size; index++) { real[index] = side[start + index] * window[index]; imaginary[index] = 0; }
                Fft(real, imaginary);
                for (var band = 0; band < ranges.Length; band++)
                {
                    if (ranges[band].End <= ranges[band].First) continue;
                    var sum = 0.0;
                    for (var bin = ranges[band].First; bin < ranges[band].End; bin++) sum += real[bin] * real[bin] + imaginary[bin] * imaginary[bin];
                    power[band] += sum;
                }
                frames++;
            }
        }
        return new(sampleRate, size, power, frames);
    }

    /// <summary>The bands of the speech beside a window, from the same sides as the level match (§8.7 item 2): up to
    /// <c>LOUDNESS_NEIGHBOURHOOD</c> before and after it, each clamped to the take; the window itself is excluded. Null when the window or
    /// its sides are not in <paramref name="source"/>.</summary>
    public static Bands? NeighbourhoodBands(VoiceLabSourceExcerpt source, int sampleRate, long windowStart, long windowEnd)
    {
        if (sampleRate <= 0 || windowStart < 0 || windowEnd < windowStart || windowEnd > source.TotalFrames) return null;
        var reach = (long)Math.Min(EditingMath.Round(VoiceLabLoudness.LoudnessNeighbourhoodSeconds * sampleRate), source.TotalFrames);
        if (source.Samples(Math.Max(0, windowStart - reach), windowStart) is not { } before ||
            source.Samples(windowEnd, Math.Min(source.TotalFrames, windowEnd + reach)) is not { } after) return null;
        return Measure([before, after], sampleRate);
    }

    /// <summary>A band's level, <c>10 × log10(power / (bins × frames))</c>; null when it is absent, silent or nothing was voiced.</summary>
    public static double? Level(Bands bands, int band)
    {
        if (bands.Frames <= 0 || bands.Power[band] is not { } power || power <= 0) return null;
        var (first, end) = Bins(BandIndices[band], bands.SampleRate, bands.FrameSize);
        return 10 * Math.Log10(power / ((end - first) * (double)bands.Frames));
    }

    /// <summary>The least-squares slope, in dB per octave, of the band levels against <c>index / 3</c>, over the bands present in
    /// <paramref name="bands"/> and in <paramref name="other"/>. Null without a voiced frame or with fewer than <see cref="MinimumBands"/>.</summary>
    public static double? Slope(Bands bands, Bands other)
    {
        if (bands.Frames <= 0) return null;
        List<(double X, double Y)> points = [];
        for (var band = 0; band < BandIndices.Count; band++)
        {
            if (bands.Power[band] is not { } power || other.Power[band] is not { } theirs || power <= 0 || theirs <= 0) continue;
            var (first, end) = Bins(BandIndices[band], bands.SampleRate, bands.FrameSize);
            points.Add((BandIndices[band] / 3.0, 10 * Math.Log10(power / ((end - first) * (double)bands.Frames))));
        }
        if (points.Count < MinimumBands) return null;
        var meanX = points.Aggregate(0.0, (sum, point) => sum + point.X) / points.Count;
        var meanY = points.Aggregate(0.0, (sum, point) => sum + point.Y) / points.Count;
        double covariance = 0, variance = 0;
        foreach (var point in points)
        {
            covariance += (point.X - meanX) * (point.Y - meanY);
            variance += (point.X - meanX) * (point.X - meanX);
        }
        return variance > 0 ? covariance / variance : null;
    }

    /// <summary>The tilt that brings a take's slope to the speech beside it: the difference of the two slopes over their common bands,
    /// clamped to ±<see cref="MaximumDbPerOctave"/> and rounded to <see cref="StepDbPerOctave"/> (half away from zero). Null when either
    /// can't be measured or the step rounds to 0: the take is left as it is.</summary>
    public static double? Match(Bands source, Bands take)
    {
        if (Slope(source, take) is not { } target || Slope(take, source) is not { } current) return null;
        var clamped = Math.Min(Math.Max(target - current, -MaximumDbPerOctave), MaximumDbPerOctave);
        var stepped = Math.Round(clamped / StepDbPerOctave, MidpointRounding.AwayFromZero) * StepDbPerOctave;
        var value = Math.Round(stepped * 10, MidpointRounding.AwayFromZero) / 10;
        return value == 0 ? null : value;
    }

    /// <summary>A first-order section: <c>y[n] = b0 × x[n] + b1 × x[n−1] − a1 × y[n−1]</c>.</summary>
    public readonly record struct Section(double B0, double B1, double A1);

    /// <summary>The tilt's cascade at a rate: a bilinear first-order high shelf per <see cref="ShelfHz"/> below 0.45 × rate, prewarped at its
    /// frequency, with gain <c>2 × tilt</c> dB (low frequencies 0 dB, half the gain at the shelf frequency). The first section is scaled so
    /// the cascade's gain at <see cref="PivotHz"/> is exactly 0 dB. Empty for a 0 or non-finite tilt.</summary>
    public static IReadOnlyList<Section> Sections(double tiltDbPerOctave, int sampleRate)
    {
        if (!double.IsFinite(tiltDbPerOctave) || tiltDbPerOctave == 0 || sampleRate <= 0) return [];
        var clamped = Math.Min(Math.Max(tiltDbPerOctave, -MaximumDbPerOctave), MaximumDbPerOctave);
        List<Section> sections = [];
        foreach (var frequency in ShelfHz.Where(frequency => frequency < 0.45 * sampleRate))
        {
            var gain = Math.Pow(10, 2 * clamped / 20);
            var root = Math.Sqrt(gain);
            var k = Math.Tan(Math.PI * frequency / sampleRate);
            var a0 = 1 + k * root;
            sections.Add(new(gain * (1 + k / root) / a0, gain * (k / root - 1) / a0, (k * root - 1) / a0));
        }
        if (sections.Count == 0) return [];
        var pivot = Magnitude(sections, PivotHz, sampleRate);
        sections[0] = sections[0] with { B0 = sections[0].B0 / pivot, B1 = sections[0].B1 / pivot };
        return sections;
    }

    /// <summary>The cascade's linear magnitude at <paramref name="hertz"/>.</summary>
    public static double Magnitude(IReadOnlyList<Section> sections, double hertz, int sampleRate)
    {
        var omega = 2 * Math.PI * hertz / sampleRate;
        var c = Math.Cos(omega);
        var result = 1.0;
        foreach (var section in sections)
        {
            var numerator = section.B0 * section.B0 + section.B1 * section.B1 + 2 * section.B0 * section.B1 * c;
            var denominator = 1 + section.A1 * section.A1 + 2 * section.A1 * c;
            result *= Math.Sqrt(numerator / denominator);
        }
        return result;
    }

    /// <summary>The cascade run sample by sample from zero state, in binary64, for one channel. The take's mix, the preview and the export
    /// all run it from the asset's first frame, so every reader of a frame hears the same sample.</summary>
    public sealed class Filter(IReadOnlyList<Section> sections)
    {
        private readonly double[] input = new double[sections.Count];
        private readonly double[] output = new double[sections.Count];
        /// <summary>The cascade this filter runs.</summary>
        public IReadOnlyList<Section> Sections { get; } = sections;
        /// <summary>One sample through every section, rounded to binary32 once.</summary>
        public float Process(float sample) => (float)Step(sample);
        /// <summary>One sample through every section, in binary64.</summary>
        public double Step(double sample)
        {
            var value = sample;
            for (var index = 0; index < Sections.Count; index++)
            {
                var section = Sections[index];
                var result = section.B0 * value + section.B1 * input[index] - section.A1 * output[index];
                input[index] = value; output[index] = result;
                value = result;
            }
            return value;
        }
    }

    /// <summary><paramref name="samples"/> through the cascade from zero state at their first sample; a copy, unchanged without sections.</summary>
    public static float[] Apply(ReadOnlySpan<float> samples, IReadOnlyList<Section> sections)
    {
        var result = samples.ToArray();
        if (sections.Count == 0) return result;
        var filter = new Filter(sections);
        for (var index = 0; index < result.Length; index++) result[index] = filter.Process(result[index]);
        return result;
    }

    /// <summary>In-place iterative radix-2 FFT (decimation in time, bit-reversed input order), the length a power of two. The twiddle for
    /// stage length m and offset j is <c>cos(−2πj/m) + i sin(−2πj/m)</c>, computed directly.</summary>
    internal static void Fft(double[] real, double[] imaginary)
    {
        var count = real.Length;
        if (count <= 1) return;
        var j = 0;
        for (var i = 1; i < count; i++)
        {
            var bit = count >> 1;
            while ((j & bit) != 0) { j ^= bit; bit >>= 1; }
            j |= bit;
            if (i < j) { (real[i], real[j]) = (real[j], real[i]); (imaginary[i], imaginary[j]) = (imaginary[j], imaginary[i]); }
        }
        for (var length = 2; length <= count; length *= 2)
        {
            var half = length / 2;
            for (var offset = 0; offset < half; offset++)
            {
                var angle = -2 * Math.PI * offset / length;
                double wr = Math.Cos(angle), wi = Math.Sin(angle);
                for (var start = 0; start < count; start += length)
                {
                    int a = start + offset, b = a + half;
                    double tr = wr * real[b] - wi * imaginary[b], ti = wr * imaginary[b] + wi * real[b];
                    real[b] = real[a] - tr; imaginary[b] = imaginary[a] - ti;
                    real[a] += tr; imaginary[a] += ti;
                }
            }
        }
    }
}
