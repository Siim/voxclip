namespace VoxClip.App.ViewModels;

internal readonly record struct TimelineAmplitude(double Peak, double Rms);

internal sealed class TimelineWaveform
{
    private readonly float[] peaks;
    private readonly double[] squares;
    private readonly int leafCount;
    internal int Count { get; }
    internal double FrameSeconds { get; }
    private TimelineWaveform(IReadOnlyList<float> levels, double frameSeconds, CancellationToken ct)
    {
        FrameSeconds = frameSeconds;
        Count = levels.Count;
        leafCount = 1;
        while (leafCount < Count) leafCount <<= 1;
        peaks = new float[leafCount * 2];
        squares = new double[leafCount * 2];
        for (var index = 0; index < Count; index++)
        {
            if (index % 4096 == 0) ct.ThrowIfCancellationRequested();
            var value = float.IsFinite(levels[index]) ? Math.Max(0, levels[index]) : 0;
            peaks[leafCount + index] = value;
            squares[leafCount + index] = value * (double)value;
        }
        for (var index = leafCount - 1; index > 0; index--)
        {
            peaks[index] = Math.Max(peaks[index * 2], peaks[index * 2 + 1]);
            squares[index] = squares[index * 2] + squares[index * 2 + 1];
        }
    }
    internal static TimelineWaveform Create(IReadOnlyList<float> levels, double frameSeconds = .05, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        if (!double.IsFinite(frameSeconds) || frameSeconds <= 0) throw new ArgumentOutOfRangeException(nameof(frameSeconds));
        return new(levels, frameSeconds, ct);
    }
    internal TimelineAmplitude Query(double start, double end)
    {
        if (!double.IsFinite(start) || !double.IsFinite(end) || end <= start || Count == 0) return default;
        var first = (int)Math.Clamp(Math.Floor(start / FrameSeconds), 0, Count);
        var last = (int)Math.Clamp(Math.Ceiling(end / FrameSeconds), first, Count);
        var count = last - first;
        double peak = 0, sum = 0;
        for (first += leafCount, last += leafCount; first < last; first >>= 1, last >>= 1)
        {
            if ((first & 1) != 0) { peak = Math.Max(peak, peaks[first]); sum += squares[first++]; }
            if ((last & 1) != 0) { --last; peak = Math.Max(peak, peaks[last]); sum += squares[last]; }
        }
        return count == 0 || peak < .004 ? default : new(peak, Math.Sqrt(sum / count));
    }
}
