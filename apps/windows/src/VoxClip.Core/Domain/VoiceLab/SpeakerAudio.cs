#pragma warning disable CS1591
namespace VoxClip.Core.Domain.VoiceLab;

public static class SpeakerAudio
{
    public const string Version = "sinc32-blackman94-silero-6.2.0-kaldi80-v2";
    public const int WindowSize = 48000;
    public const int HopSize = 24000;
    public const int PartWindows = 3;
    /// <summary>A sample's embedding: the normalised sum of its window embeddings, added in window order.</summary>
    public static float[] Embedding(IReadOnlyList<float[]> windows) => Normalized(Sum(windows, 0, windows.Count));
    /// <summary>voice-lab.md §6.6 for project spans: the span's embedding and one per part of <see cref="PartWindows"/> consecutive
    /// windows, about the six seconds each S6 calibration clip held. A last part of a single window joins the part before it.</summary>
    public static (float[] Whole, float[][] Parts) PartEmbeddings(IReadOnlyList<float[]> windows)
    {
        var starts = Enumerable.Range(0, (windows.Count + PartWindows - 1) / PartWindows).Select(part => part * PartWindows).ToList();
        if (starts.Count > 1 && windows.Count - starts[^1] == 1) starts.RemoveAt(starts.Count - 1);
        var parts = starts.Select((start, index) => Normalized(Sum(windows, start, index + 1 < starts.Count ? starts[index + 1] : windows.Count))).ToArray();
        return (Embedding(windows), parts);
    }
    private static float[] Sum(IReadOnlyList<float[]> windows, int start, int end)
    {
        if (windows.Count == 0 || windows.Any(window => window.Length != windows[0].Length)) throw Mismatch();
        var sum = new float[windows[0].Length];
        for (var window = start; window < end; window++)
            for (var index = 0; index < sum.Length; index++) sum[index] += windows[window][index];
        return sum;
    }
    public static float[] Normalized(IReadOnlyList<float> vector)
    {
        if (vector.Count == 0 || vector.Any(value => !float.IsFinite(value))) throw Mismatch();
        var norm = Math.Sqrt(vector.Sum(value => (double)value * value));
        if (norm == 0 || !double.IsFinite(norm)) throw Mismatch();
        return vector.Select(value => (float)(value / norm)).ToArray();
    }
    public static double Cosine(IReadOnlyList<float> left, IReadOnlyList<float> right)
    {
        if (left.Count != right.Count || left.Count == 0) throw Mismatch();
        var unitLeft = Normalized(left);
        var unitRight = Normalized(right);
        var score = 0.0;
        for (var index = 0; index < unitLeft.Length; index++) score += (double)unitLeft[index] * unitRight[index];
        return Math.Clamp(score, -1, 1);
    }
    public static IEnumerable<float[]> Windows(float[] speech)
    {
        if (speech.Length < WindowSize || speech.Any(sample => !float.IsFinite(sample))) throw Mismatch();
        for (var start = 0; start <= speech.Length - WindowSize; start += HopSize) yield return speech[start..(start + WindowSize)];
    }
    public static float[] Select(float[] pcm, IReadOnlyList<(int Start, int End)> ranges)
    {
        if (pcm.Any(sample => !float.IsFinite(sample))) throw Mismatch();
        var end = 0;
        var output = new List<float>();
        foreach (var range in ranges)
        {
            if (range.Start < end || range.End <= range.Start || range.End > pcm.Length) throw Mismatch();
            output.AddRange(pcm[range.Start..range.End]);
            end = range.End;
        }
        return output.ToArray();
    }
    public static float[] Features(float[] pcm)
    {
        if (pcm.Length != WindowSize || pcm.Any(sample => !float.IsFinite(sample))) throw Mismatch();
        const int frameCount = 298;
        var bank = MelBank();
        var output = new double[frameCount * 80];
        for (var frame = 0; frame < frameCount; frame++)
        {
            var values = new double[400];
            for (var index = 0; index < 400; index++) values[index] = (double)pcm[frame * 160 + index] * 32768;
            var average = values.Sum() / 400;
            for (var index = 0; index < 400; index++) values[index] -= average;
            for (var index = 399; index >= 1; index--) values[index] -= 0.97 * values[index - 1];
            values[0] *= 0.03;
            for (var index = 0; index < 400; index++) values[index] *= 0.54 - 0.46 * Math.Cos(2 * Math.PI * index / 399);
            var spectrum = Power(values);
            for (var band = 0; band < 80; band++)
            {
                var energy = 0.0;
                foreach (var (index, weight) in bank[band]) energy += spectrum[index] * weight;
                output[frame * 80 + band] = Math.Log(Math.Max(1.1920928955078125e-7, energy));
            }
        }
        for (var band = 0; band < 80; band++)
        {
            var mean = 0.0;
            for (var frame = 0; frame < frameCount; frame++) mean += output[frame * 80 + band];
            mean /= frameCount;
            for (var frame = 0; frame < frameCount; frame++) output[frame * 80 + band] -= mean;
        }
        return output.Select(value => (float)value).ToArray();
    }
    private static List<(int Index, double Weight)>[] MelBank()
    {
        var low = 1127 * Math.Log(1 + 20.0 / 700);
        var high = 1127 * Math.Log(1 + 8000.0 / 700);
        var step = (high - low) / 81;
        var result = new List<(int, double)>[80];
        for (var band = 0; band < 80; band++)
        {
            result[band] = [];
            var left = low + band * step;
            for (var index = 0; index < 256; index++)
            {
                var mel = 1127 * Math.Log(1 + (index * 16000.0 / 512) / 700);
                var weight = Math.Max(0, Math.Min((mel - left) / step, (left + 2 * step - mel) / step));
                if (weight > 0) result[band].Add((index, weight));
            }
        }
        return result;
    }
    private static double[] Power(double[] samples)
    {
        var real = new double[512];
        samples.CopyTo(real, 0);
        var imaginary = new double[512];
        var reversed = 0;
        for (var index = 1; index < 512; index++)
        {
            var bit = 256;
            while ((reversed & bit) != 0) { reversed ^= bit; bit >>= 1; }
            reversed ^= bit;
            if (index < reversed) (real[index], real[reversed]) = (real[reversed], real[index]);
        }
        for (var length = 2; length <= 512; length *= 2)
            for (var start = 0; start < 512; start += length)
                for (var offset = 0; offset < length / 2; offset++)
                {
                    var angle = -2 * Math.PI * offset / length;
                    var other = start + offset + length / 2;
                    var current = start + offset;
                    var realPart = real[other] * Math.Cos(angle) - imaginary[other] * Math.Sin(angle);
                    var imaginaryPart = real[other] * Math.Sin(angle) + imaginary[other] * Math.Cos(angle);
                    real[other] = real[current] - realPart;
                    imaginary[other] = imaginary[current] - imaginaryPart;
                    real[current] += realPart;
                    imaginary[current] += imaginaryPart;
                }
        return Enumerable.Range(0, 257).Select(index => real[index] * real[index] + imaginary[index] * imaginary[index]).ToArray();
    }
    private static VoiceConsentException Mismatch() => new(VoiceConsentError.SpeakerMismatch);
}
