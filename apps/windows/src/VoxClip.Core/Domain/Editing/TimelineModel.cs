#pragma warning disable CS1591 // Media-free v2 timeline API; shared fixture contract in doc/spec/editing.md.
using System.Globalization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Domain.Editing;

/// <summary>Edited closes cuts; Source uses take time.</summary>
public enum TimelineAxis { Edited, Source }
public enum TimelinePieceKind { Kept, Ai }
public readonly record struct TimelinePiece(TimeRange Source, TimeRange Edited, TimelinePieceKind Kind = TimelinePieceKind.Kept)
{
    public TimeRange Range(TimelineAxis axis) => axis == TimelineAxis.Edited ? Edited : Source;
}

/// <summary>Ascending source/output pieces; visibility is O(log n) plus the visible pieces.</summary>
public sealed class TimelinePieces
{
    public IReadOnlyList<TimelinePiece> Pieces { get; }
    public TimelinePieces(IEnumerable<TimelinePiece> pieces) => Pieces = pieces.ToArray();
    public TimelinePieces(RenderTimeline timeline)
    {
        var pieces = new List<TimelinePiece>();
        switch (timeline)
        {
            case RenderTimeline.Legacy legacy:
                long output = 0;
                foreach (var interval in legacy.Plan.Kept)
                {
                    if (interval.EndSample <= interval.StartSample) continue;
                    var length = interval.EndSample - interval.StartSample;
                    pieces.Add(new(new(interval.StartSample / legacy.Plan.SampleRate, interval.EndSample / legacy.Plan.SampleRate),
                        new(output / legacy.Plan.SampleRate, (output + length) / legacy.Plan.SampleRate)));
                    output += length;
                }
                break;
            case RenderTimeline.VoiceLab voice:
                foreach (var piece in voice.Plan.Pieces)
                {
                    if (piece.OutputEndSample <= piece.OutputStartSample) continue;
                    pieces.Add(new(new(piece.SourceStartSample / voice.Plan.SampleRate, Math.Max(piece.SourceStartSample, piece.SourceEndSample) / voice.Plan.SampleRate),
                        new(piece.OutputStartSample / voice.Plan.SampleRate, piece.OutputEndSample / voice.Plan.SampleRate),
                        piece.Kind == VoiceLabOutputPieceKind.Synth ? TimelinePieceKind.Ai : TimelinePieceKind.Kept));
                }
                break;
            default: throw new ArgumentOutOfRangeException(nameof(timeline));
        }
        Pieces = pieces;
    }
    public double EditedDuration => Pieces.Count == 0 ? 0 : Pieces[^1].Edited.End;
    public TimeRange? SourceSpan => Pieces.Count == 0 ? null : new(Pieces[0].Source.Start, Math.Max(Pieces[0].Source.Start, Pieces[^1].Source.End));
    public bool IsSeam(int index) => index > 0 && index < Pieces.Count && Pieces[index].Source.Start - Pieces[index - 1].Source.End > 1e-6;
    public IReadOnlyList<double> Seams => Enumerable.Range(0, Pieces.Count).Where(IsSeam).Select(index => Pieces[index].Edited.Start).ToArray();
    public IReadOnlyList<TimeRange> Gaps(TimeRange span, double minimum = .02)
    {
        var result = new List<TimeRange>();
        var covered = span.Start;
        var indices = Indices(span, TimelineAxis.Source);
        for (var i = indices.Start.Value; i < indices.End.Value; i++)
        {
            var piece = Pieces[i];
            if (piece.Source.Start - covered > minimum) result.Add(new(covered, piece.Source.Start));
            covered = Math.Max(covered, piece.Source.End);
        }
        if (span.End - covered > minimum) result.Add(new(covered, span.End));
        return result;
    }
    public Range Indices(TimeRange range, TimelineAxis axis)
    {
        var lower = 0; var upper = Pieces.Count;
        while (lower < upper)
        {
            var middle = (lower + upper) / 2;
            if (Pieces[middle].Range(axis).End <= range.Start) lower = middle + 1; else upper = middle;
        }
        var first = lower;
        upper = Pieces.Count;
        while (lower < upper)
        {
            var middle = (lower + upper) / 2;
            if (Pieces[middle].Range(axis).Start < range.End) lower = middle + 1; else upper = middle;
        }
        return new(first, Math.Max(first, lower));
    }
}

public readonly record struct TimelineTick(double Time, bool Major);
public static class TimelineRuler
{
    public const double LabelSpacing = 90;
    public const double MinorSpacing = 6;
    public static IReadOnlyList<int> MajorSteps { get; } = Array.AsReadOnly(new[] { 5, 10, 30, 60, 120, 300, 600, 1800, 3600 });
    public static IReadOnlyList<int> MinorSteps { get; } = Array.AsReadOnly(new[] { 1, 5, 10, 30, 60, 300, 600, 1800 });
    public static int MajorStep(double ptPerSecond) => double.IsFinite(ptPerSecond) && ptPerSecond > 0
        ? MajorSteps.FirstOrDefault(step => step * ptPerSecond >= LabelSpacing, MajorSteps[^1]) : MajorSteps[^1];
    public static int MinorStep(double ptPerSecond)
    {
        var major = MajorStep(ptPerSecond);
        return double.IsFinite(ptPerSecond) && ptPerSecond > 0
            ? MinorSteps.FirstOrDefault(step => step < major && major % step == 0 && step * ptPerSecond >= MinorSpacing, major) : major;
    }
    public static IReadOnlyList<TimelineTick> Ticks(TimeRange visible, double ptPerSecond)
    {
        if (!double.IsFinite(visible.Start) || !double.IsFinite(visible.End) || !double.IsFinite(ptPerSecond) || ptPerSecond <= 0) return [];
        var major = MajorStep(ptPerSecond); var minor = MinorStep(ptPerSecond);
        var first = (long)Math.Ceiling(visible.Start / minor); var last = (long)Math.Floor(visible.End / minor);
        if (first > last || last - first >= 100000) return [];
        var ticks = new List<TimelineTick>();
        for (var index = first; index <= last; index++)
        {
            var seconds = index * minor;
            ticks.Add(new(seconds, seconds % major == 0));
        }
        return ticks;
    }
    public static double? LabelX(double tickX, double width, IReadOnlyList<double> brackets, double? inBracket, double laneEnd)
    {
        var start = tickX + (inBracket is { } edge && Math.Abs(edge - tickX) < 2 ? 9 : 4);
        var end = start + width;
        return end <= laneEnd + 6 && !brackets.Any(edge => start - 3 <= edge && edge <= end + 2) ? start : null;
    }
}

/// <summary>Non-drop-frame HH:MM:SS:FF with leading zero groups separately dimmable.</summary>
public static class SMPTETimecode
{
    public static long Frame(double seconds, int fps = 30)
    {
        if (!double.IsFinite(seconds) || seconds <= 0 || fps <= 0) return 0;
        var frames = Math.Floor(seconds * fps + 1e-6);
        return frames >= (double)(long.MaxValue / 2) ? long.MaxValue / 2 : (long)frames;
    }
    public static (string DimPrefix, string Value) Format(double seconds, int fps = 30)
    {
        var rate = (long)Math.Max(1, fps); var total = Frame(seconds, fps);
        var frames = total % rate; var whole = total / rate;
        var hours = whole / 3600; var minutes = whole / 60 % 60; var secondsPart = whole % 60;
        static string Two(long value) => value.ToString("D2", CultureInfo.InvariantCulture);
        if (hours > 0) return ("", $"{Two(hours)}:{Two(minutes)}:{Two(secondsPart)}:{Two(frames)}");
        if (minutes > 0) return ("00:", $"{Two(minutes)}:{Two(secondsPart)}:{Two(frames)}");
        return ("00:00:", $"{Two(secondsPart)}:{Two(frames)}");
    }
    public static string String(double seconds, int fps = 30)
    {
        var parts = Format(seconds, fps);
        return parts.DimPrefix + parts.Value;
    }
}

public sealed record TimelineCue(TimeRange Range, string Text, IReadOnlyList<TimeRange> Cuts);
public static class TimelineCaptions
{
    public const double Hold = .6;
    public readonly record struct Page(TimeRange Edited, TimeRange Source, string Text);
    public static IReadOnlyList<TimelineCue> Cues(IReadOnlyList<Page> pages, TimelineAxis axis, IReadOnlyList<TimeRange>? removed = null)
    {
        removed ??= [];
        var cues = new List<TimelineCue>();
        var cut = 0;
        for (var index = 0; index < pages.Count; index++)
        {
            var page = pages[index];
            Page? next = index + 1 < pages.Count ? pages[index + 1] : null;
            var holds = next is { } following && following.Edited.Start - page.Edited.End <= Hold + 1e-9;
            var own = axis == TimelineAxis.Edited ? page.Edited : page.Source;
            var end = holds ? (axis == TimelineAxis.Edited ? next!.Value.Edited.Start : next!.Value.Source.Start) : own.End;
            var upper = Math.Max(own.End, end);
            if (upper <= own.Start || page.Text.Length == 0) continue;
            var range = new TimeRange(own.Start, upper);
            var inside = new List<TimeRange>();
            if (axis == TimelineAxis.Source)
            {
                while (cut < removed.Count && removed[cut].End <= range.Start) cut++;
                var probe = cut;
                while (probe < removed.Count && removed[probe].Start < range.End)
                {
                    inside.Add(new(Math.Max(range.Start, removed[probe].Start), Math.Min(range.End, removed[probe].End)));
                    probe++;
                }
            }
            cues.Add(new(range, page.Text, inside));
        }
        return cues;
    }
    public static Range Indices(IReadOnlyList<TimelineCue> cues, TimeRange range)
    {
        var lower = 0; var upper = cues.Count;
        while (lower < upper)
        {
            var middle = (lower + upper) / 2;
            if (cues[middle].Range.Start < range.Start) lower = middle + 1; else upper = middle;
        }
        var first = lower;
        while (first > 0 && cues[first - 1].Range.End > range.Start) first--;
        var last = lower;
        while (last < cues.Count && cues[last].Range.Start < range.End) last++;
        return new(first, Math.Max(first, last));
    }
}
