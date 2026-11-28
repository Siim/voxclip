using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

internal readonly record struct SourceMapEntry(MediaInterval Source, long OutputStart, long OutputEnd);

internal static class EditingPlanner
{
    internal static SourceMapEntry[] SourceIndex(IReadOnlyList<MediaInterval> kept)
    {
        long output = 0;
        return kept.Select(span => new SourceMapEntry(span, output, output += span.EndSample - span.StartSample))
            .OrderBy(entry => entry.Source.StartSample).ToArray();
    }

    internal static int FindSource<T>(IReadOnlyList<T> entries, long sample, Func<T, long> start)
    {
        var lower = 0;
        var upper = entries.Count;
        while (lower < upper)
        {
            var middle = lower + (upper - lower) / 2;
            if (start(entries[middle]) <= sample) lower = middle + 1; else upper = middle;
        }
        return lower - 1;
    }

    internal static IEnumerable<ClipRange> SinglePartClips(ClipRange clip) => clip.PlayParts.Select((part, index) => clip with
    {
        StartWordId = part.StartWordId, EndWordId = part.EndWordId, Parts = null, Kind = null,
        LeadInSeconds = index == 0 ? clip.LeadInSeconds : null
    });

    internal static EditPlan BuildStoryPlan(EditState state, ClipRange clip, double duration, double rate)
    {
        if (clip.Parts is null || !StoryClips.Valid(clip, state.Transcript.Words))
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Invalid story clip parts or source hull.");
        var plans = SinglePartClips(clip).Select(part => EditingEngine.BuildPlan(state with { Clips = [part], ActiveClipId = part.Id }, duration, rate)).ToArray();
        var kept = new List<MediaInterval>();
        var seams = new List<long>();
        long output = 0;
        foreach (var plan in plans.Where(plan => plan.Kept.Count > 0))
        {
            if (output > 0) seams.Add(output);
            kept.AddRange(plan.Kept);
            output += plan.OutputSamples;
        }
        var sorted = kept.OrderBy(span => span.StartSample).ToArray();
        if (sorted.Zip(sorted.Skip(1)).Any(pair => pair.First.EndSample > pair.Second.StartSample))
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "Story parts overlap on the source sample grid.");
        return new EditPlan(plans[0].SampleRate, plans[0].TotalSamples, Complement(sorted, plans[0].TotalSamples), kept, output, [])
            { PartSeams = seams, RecordingRegions = plans[0].RecordingRegions };
    }

    internal static TimeRange ScopedClipTimes(EditState state, int start, int end, double? leadIn)
    {
        var words = state.Transcript.Words;
        if (state.ProjectClock is not { Regions.Count: > 1 } clock) return EditingAlgorithms.ClipTimes(words, start, end, leadIn);
        var (region, range) = LocalClipTimes(words, start, end, leadIn, clock);
        var offset = (double)region.OffsetSamples / clock.SampleRate;
        return new(range.Start + offset, range.End + offset);
    }

    private static (ProjectClock.Region Region, TimeRange Range) LocalClipTimes(IReadOnlyList<TimedWord> words, int first, int last,
        double? leadIn, ProjectClock clock)
    {
        if (clock.RegionOf(words[first].Id) is not { } region || region != clock.RegionOf(words[last].Id))
            throw new VoxClipException(VoxClipErrorCode.ProjectUnreadable, "A part comes from one recording.");
        var start = first > 0 && clock.RegionOf(words[first - 1].Id) == region ? first - 1 : first;
        var end = last + 1 < words.Count && clock.RegionOf(words[last + 1].Id) == region ? last + 1 : last;
        var local = Enumerable.Range(start, end - start + 1).Select(index => words[index] with
        {
            Start = RecordingLocalTime(words[index].Start, region, clock.SampleRate),
            End = RecordingLocalTime(words[index].End, region, clock.SampleRate),
        }).ToArray();
        var times = EditingAlgorithms.ClipTimes(local, first - start, last - start, leadIn);
        return (region, new(times.Start, Math.Min(times.End, (double)region.DurationSamples / clock.SampleRate)));
    }

    private static double RecordingLocalTime(double time, ProjectClock.Region region, double rate) => region.OffsetSamples == 0
        ? time : (EditingMath.Round(time * rate) - region.OffsetSamples) / rate;

    internal static EditPlan BuildScopedPlan(IReadOnlyList<EditSegment> segments, EditState state, double duration, double rate)
    {
        if (state.ProjectClock is not { Regions.Count: > 1 } clock) return Build(segments, duration, rate, state.PauseKeepSeconds);
        rate = clock.SampleRate;
        var clip = state.Clips.FirstOrDefault(item => item.Id == state.ActiveClipId);
        (ProjectClock.Region Region, TimeRange Range)? scope = clip?.PlayPartIndices(state.Transcript.Words) is { Count: 1 } ranges
            ? LocalClipTimes(state.Transcript.Words, ranges[0].Start, ranges[0].End, clip.LeadInSeconds, clock) : null;
        var kept = new List<MediaInterval>();
        foreach (var region in clock.Regions.Where(region => scope is null || scope.Value.Region == region))
        {
            var offset = region.OffsetSamples / rate;
            var end = region.EndSample / rate;
            var length = region.DurationSamples / rate;
            var local = segments.Where(segment => segment.Kind != EditSegmentKind.Range && offset <= segment.Start && segment.Start < end &&
                (segment.Kind != EditSegmentKind.Pause || segment.End <= end)).Select(segment => segment with
                {
                    Start = RecordingLocalTime(segment.Start, region, rate), End = RecordingLocalTime(segment.End, region, rate),
                }).ToList();
            if (scope is { } selected)
            {
                local.Add(new("clip-head", EditSegmentKind.Range, null, null, 0, selected.Range.Start, true));
                local.Add(new("clip-tail", EditSegmentKind.Range, null, null, selected.Range.End, length, true));
            }
            var plan = Build(local, length, rate, state.PauseKeepSeconds);
            kept.AddRange(plan.Kept.Select(span => new MediaInterval(span.StartSample + region.OffsetSamples, span.EndSample + region.OffsetSamples)));
        }
        return new EditPlan(rate, clock.TotalSamples, Complement(kept, clock.TotalSamples), kept, 0, []) { RecordingRegions = clock.SampleRegions };
    }

    internal static long[] RecordingSeams<T>(IEnumerable<T> pieces, IReadOnlyList<MediaInterval> regions, Func<T, long> source, Func<T, long> output)
    {
        if (regions.Count < 2) return [];
        var seams = new List<long>();
        MediaInterval? previous = null;
        foreach (var piece in pieces)
        {
            var sample = source(piece);
            MediaInterval? current = null;
            foreach (var region in regions)
                if (region.StartSample <= sample && sample < region.EndSample) { current = region; break; }
            if (previous is not null && current is not null && previous != current) seams.Add(output(piece));
            previous = current;
        }
        return seams.ToArray();
    }

    private static MediaInterval[] Complement(IEnumerable<MediaInterval> ordered, long total)
    {
        var cuts = new List<MediaInterval>();
        long cursor = 0;
        foreach (var span in ordered)
        {
            if (cursor < span.StartSample) cuts.Add(new(cursor, span.StartSample));
            cursor = span.EndSample;
        }
        if (cursor < total) cuts.Add(new(cursor, total));
        return cuts.ToArray();
    }

    internal static IReadOnlyList<CaptionWord> StoryCaptions(IReadOnlyList<EditSegment> segments, EditPlan plan)
    {
        var result = new List<CaptionWord>();
        long offset = 0, position = 0;
        var index = 0;
        foreach (var end in plan.CaptionSeams.Append(plan.OutputSamples))
        {
            var kept = new List<MediaInterval>();
            while (index < plan.Kept.Count && position < end)
            {
                var span = plan.Kept[index++];
                kept.Add(span);
                position += span.EndSample - span.StartSample;
            }
            var part = new EditPlan(plan.SampleRate, plan.TotalSamples, Complement(kept, plan.TotalSamples), kept, position - offset, []);
            result.AddRange(ShiftCaptions(EditingEngine.CaptionCopy(segments, part), offset, plan.SampleRate, result.Count > 0));
            offset = end;
        }
        return result;
    }

    internal static IEnumerable<CaptionWord> ShiftCaptions(IReadOnlyList<CaptionWord> captions, long offset, double rate, bool startsPart) =>
        captions.Select((word, index) => word with { Start = word.Start + offset / rate, End = word.End + offset / rate,
            StartsPart = index == 0 && startsPart ? true : word.StartsPart });
    internal static bool Valid(EditSegment segment) => double.IsFinite(segment.Start) && double.IsFinite(segment.End) && segment.End > segment.Start;

    internal static TimeRange CutRange(IReadOnlyList<EditSegment> segments, int index, double duration, double pauseKeep)
        => CutRange(segments[index], index, new SpeechLookup(segments), duration, pauseKeep);

    private sealed class SpeechLookup
    {
        private readonly record struct SpeechEntry(EditSegment Word, int Index);

        internal readonly EditSegment[] Words;
        internal readonly int[] Positions;
        internal readonly double[] EarlierEnds;
        private SpeechEntry[]? byEnd;

        internal SpeechLookup(IReadOnlyList<EditSegment> segments)
        {
            var wordCount = 0;
            for (var index = 0; index < segments.Count; index++)
                if (segments[index].Kind == EditSegmentKind.Word && Valid(segments[index])) wordCount++;
            var sorted = new SpeechEntry[wordCount];
            var ordered = true;
            var previousStart = double.NegativeInfinity;
            for (int index = 0, next = 0; index < segments.Count; index++)
            {
                var segment = segments[index];
                if (segment.Kind != EditSegmentKind.Word || !Valid(segment)) continue;
                if (segment.Start < previousStart) ordered = false;
                previousStart = segment.Start;
                sorted[next++] = new(segment, index);
            }
            if (!ordered)
                Array.Sort(sorted, static (left, right) =>
                {
                    var order = left.Word.Start.CompareTo(right.Word.Start);
                    return order != 0 ? order : left.Index.CompareTo(right.Index);
                });
            Words = new EditSegment[wordCount];
            Positions = new int[segments.Count];
            Array.Fill(Positions, -1);
            EarlierEnds = new double[wordCount];
            var reached = 0.0;
            for (var index = 0; index < sorted.Length; index++)
            {
                Words[index] = sorted[index].Word;
                Positions[sorted[index].Index] = index;
                EarlierEnds[index] = reached;
                reached = Math.Max(reached, Words[index].End);
            }
        }

        internal EditSegment? Before(double end)
        {
            if (byEnd is null)
            {
                byEnd = new SpeechEntry[Words.Length];
                for (var index = 0; index < Words.Length; index++) byEnd[index] = new(Words[index], index);
                Array.Sort(byEnd, static (left, right) =>
                {
                    var order = left.Word.End.CompareTo(right.Word.End);
                    return order != 0 ? order : right.Index.CompareTo(left.Index);
                });
            }
            var lower = 0;
            var upper = byEnd.Length;
            while (lower < upper)
            {
                var middle = lower + (upper - lower) / 2;
                if (byEnd[middle].Word.End <= end) lower = middle + 1;
                else upper = middle;
            }
            return lower > 0 ? byEnd[lower - 1].Word : null;
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
        var selectedOrdered = true;
        for (var index = 1; index < selected.Count; index++)
            if (selected[index].interval.StartSample < selected[index - 1].interval.StartSample) { selectedOrdered = false; break; }
        if (!selectedOrdered)
            selected.Sort(static (left, right) =>
            {
                var order = left.interval.StartSample.CompareTo(right.interval.StartSample);
                return order != 0 ? order : left.index.CompareTo(right.index);
            });
        foreach (var pair in selected)
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
        // EditPlan derives output length and joins from Kept in its constructor.
        return new(rate, total, cuts.ToArray(), kept.ToArray(), 0, []);
    }

    internal static (long FadeIn, long FadeOut) Fades(double rate, long total, MediaInterval span, IReadOnlyList<MediaInterval> regions)
    {
        var fade = (long)Math.Min(EditingMath.Round(0.005 * rate), (span.EndSample - span.StartSample) / 2);
        var atStart = span.StartSample <= 0 || regions.Any(region => region.StartSample == span.StartSample);
        var atEnd = span.EndSample >= total || regions.Any(region => region.EndSample == span.EndSample);
        return (atStart ? 0 : fade, atEnd ? 0 : fade);
    }

    internal static Join[] BuildJoins(double rate, long total, IReadOnlyList<MediaInterval> kept, IReadOnlyList<MediaInterval> regions)
    {
        var joins = new List<Join>();
        long offset = 0;
        long fadeOut = 0;
        foreach (var part in kept)
        {
            var length = part.EndSample - part.StartSample;
            var (fadeIn, nextFadeOut) = Fades(rate, total, part, regions);
            if (offset > 0 || fadeIn > 0) joins.Add(new(offset, fadeOut, fadeIn));
            fadeOut = nextFadeOut;
            offset += length;
        }
        if (kept.Count > 0 && fadeOut > 0) joins.Add(new(offset, fadeOut, 0));
        return joins.ToArray();
    }
}
