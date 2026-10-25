using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

internal static class EditingPlanner
{
    internal static bool Valid(EditSegment segment) => double.IsFinite(segment.Start) && double.IsFinite(segment.End) && segment.End > segment.Start;

    internal static TimeRange CutRange(IReadOnlyList<EditSegment> segments, int index, double duration, double pauseKeep)
        => CutRange(segments[index], index, new SpeechLookup(segments), duration, pauseKeep);

    private sealed class SpeechLookup
    {
        internal readonly EditSegment[] Words;
        internal readonly int[] Positions;
        internal readonly double[] EarlierEnds;
        private readonly EditSegment[] byEnd;

        internal SpeechLookup(IReadOnlyList<EditSegment> segments)
        {
            var sorted = segments.Select((segment, index) => (segment, index)).Where(pair => pair.segment.Kind == EditSegmentKind.Word && Valid(pair.segment))
                .OrderBy(pair => pair.segment.Start).ThenBy(pair => pair.index).ToArray();
            Words = sorted.Select(pair => pair.segment).ToArray();
            Positions = new int[segments.Count];
            Array.Fill(Positions, -1);
            EarlierEnds = new double[Words.Length];
            var reached = 0.0;
            for (var index = 0; index < sorted.Length; index++)
            {
                Positions[sorted[index].index] = index;
                EarlierEnds[index] = reached;
                reached = Math.Max(reached, Words[index].End);
            }
            byEnd = Words.Select((word, index) => (word, index)).OrderBy(pair => pair.word.End).ThenByDescending(pair => pair.index).Select(pair => pair.word).ToArray();
        }

        internal EditSegment? Before(double end)
        {
            var lower = 0;
            var upper = byEnd.Length;
            while (lower < upper)
            {
                var middle = lower + (upper - lower) / 2;
                if (byEnd[middle].End <= end) lower = middle + 1;
                else upper = middle;
            }
            return lower > 0 ? byEnd[lower - 1] : null;
        }

        internal EditSegment? After(double start)
        {
            var lower = 0;
            var upper = Words.Length;
            while (lower < upper)
            {
                var middle = lower + (upper - lower) / 2;
                if (Words[middle].Start < start) lower = middle + 1;
                else upper = middle;
            }
            return lower < Words.Length ? Words[lower] : null;
        }
    }

    private static TimeRange CutRange(EditSegment segment, int index, SpeechLookup speech, double duration, double pauseKeep)
    {
        if (segment.Kind == EditSegmentKind.Range) return new(segment.Start, segment.End);
        if (segment.Kind == EditSegmentKind.Pause)
        {
            var before = speech.Before(segment.Start + 1e-6);
            var after = speech.After(segment.End - 1e-6);
            return new(segment.Start + (before is { Cut: false } ? pauseKeep : 0), segment.End - (after is { Cut: false } ? pauseKeep : 0));
        }
        var position = speech.Positions[index];
        if (position < 0) throw new ArgumentException("Word segment must have valid timings.", nameof(segment));
        var earlierEnd = speech.EarlierEnds[position];
        if (earlierEnd >= segment.End) return new(segment.Start, segment.End);
        var nextStart = position + 1 < speech.Words.Length ? speech.Words[position + 1].Start : duration;
        return new(segment.Start - Math.Min(0.1, Math.Max(0, segment.Start - earlierEnd) / 2), segment.End + Math.Min(0.1, Math.Max(0, nextStart - segment.End) / 2));
    }

    internal static EditPlan Build(IReadOnlyList<EditSegment> segments, double duration, double rate, double pauseKeep)
    {
        if (!double.IsFinite(duration) || duration < 0 || !double.IsFinite(rate) || rate <= 0 || !double.IsFinite(duration * rate) || EditingMath.Round(duration * rate) >= 9223372036854775808.0)
            throw new ArgumentException("Invalid media duration or sample rate");
        if (!double.IsFinite(pauseKeep) || pauseKeep < 0 || pauseKeep > 1) throw new ArgumentOutOfRangeException(nameof(pauseKeep));
        if (segments.Any(segment => segment.Kind == EditSegmentKind.Range && !segment.Cut)) throw new ArgumentException("Range segments must be cut.", nameof(segments));
        var total = (long)Math.Max(0, EditingMath.Round(duration * rate));
        var speech = new SpeechLookup(segments);
        var selected = new List<(MediaInterval interval, int index)>();
        for (var index = 0; index < segments.Count; index++)
        {
            var segment = segments[index];
            if (!segment.Cut || !Valid(segment)) continue;
            var range = CutRange(segment, index, speech, duration, pauseKeep);
            var start = EditingMath.ClampSample(range.Start, rate, total);
            var end = EditingMath.ClampSample(range.End, rate, total);
            if (end > start) selected.Add((new(start, end), index));
        }
        var cuts = new List<MediaInterval>();
        foreach (var pair in selected.OrderBy(pair => pair.interval.StartSample).ThenBy(pair => pair.index))
        {
            var cut = pair.interval;
            if (cuts.Count > 0 && cut.StartSample <= cuts[^1].EndSample) cuts[^1] = cuts[^1] with { EndSample = Math.Max(cuts[^1].EndSample, cut.EndSample) };
            else cuts.Add(cut);
        }
        var kept = new List<MediaInterval>();
        long cursor = 0;
        foreach (var cut in cuts)
        {
            if (cut.StartSample > cursor) kept.Add(new(cursor, cut.StartSample));
            cursor = cut.EndSample;
        }
        if (cursor < total) kept.Add(new(cursor, total));
        return new(rate, total, cuts.ToArray(), kept.ToArray(), kept.Sum(part => part.EndSample - part.StartSample), BuildJoins(rate, total, kept));
    }

    internal static Join[] BuildJoins(double rate, long total, IReadOnlyList<MediaInterval> kept)
    {
        var joins = new List<Join>();
        long offset = 0;
        long fadeOut = 0;
        foreach (var part in kept)
        {
            var length = part.EndSample - part.StartSample;
            var fade = (long)Math.Min(EditingMath.Round(0.005 * rate), length / 2);
            var fadeIn = part.StartSample > 0 ? fade : 0;
            if (offset > 0 || fadeIn > 0) joins.Add(new(offset, fadeOut, fadeIn));
            fadeOut = part.EndSample < total ? fade : 0;
            offset += length;
        }
        if (kept.Count > 0 && fadeOut > 0) joins.Add(new(offset, fadeOut, 0));
        return joins.ToArray();
    }
}
