namespace VoxClip.App.ViewModels;

internal sealed record FrameTimeSummary(int Frames, double P50Milliseconds, double P95Milliseconds, double MaxMilliseconds,
    double ShareOver16Point7, double ShareOver33, int EstimatedDroppedFrames)
{
    internal static FrameTimeSummary From(IReadOnlyList<double> intervals)
    {
        if (intervals.Count == 0) throw new ArgumentException("Frame intervals are required.", nameof(intervals));
        var sorted = new double[intervals.Count];
        var over16 = 0;
        var over33 = 0;
        var dropped = 0;
        for (var index = 0; index < intervals.Count; index++)
        {
            var interval = intervals[index];
            if (!double.IsFinite(interval) || interval <= 0) throw new ArgumentOutOfRangeException(nameof(intervals));
            sorted[index] = interval;
            if (interval > 16.7) over16++;
            if (interval > 33) over33++;
            dropped += Math.Max(0, (int)Math.Round(interval / (1000.0 / 60)) - 1);
        }
        Array.Sort(sorted);
        return new(sorted.Length, sorted[(int)Math.Ceiling(sorted.Length * 0.50) - 1],
            sorted[(int)Math.Ceiling(sorted.Length * 0.95) - 1], sorted[^1],
            over16 / (double)sorted.Length, over33 / (double)sorted.Length, dropped);
    }
}
