using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record TimelineMediaTile(TimelinePieces Pieces, TimelineMark[] Video, TimelineMark[] Peaks, TimelineMark[] Core,
    TimelineMark[] GhostPeaks, TimelineMark[] GhostCore, TimelineMark[] Gaps, TimelineMark[] Seams);

internal sealed class TimelineTileCache
{
    internal const int Capacity = 8;
    private readonly record struct Key(EditPlan Plan, TimelineWaveform? Waveform, TimelineWindow View, double Width, bool Edited);
    private readonly LinkedList<(Key Key, TimelineMediaTile Tile)> entries = new();
    private EditPlan? piecePlan;
    private TimelinePieces pieces = new([]);
    internal int Count => entries.Count;
    internal int Builds { get; private set; }
    internal void Clear() { entries.Clear(); piecePlan = null; pieces = new([]); }
    internal TimelineMediaTile Get(EditPlan plan, TimelineWaveform? waveform, TimelineWindow window, double width, bool edited)
    {
        var key = new Key(plan, waveform, window, width, edited);
        for (var node = entries.First; node is not null; node = node.Next)
            if (ReferenceEquals(node.Value.Key.Plan, plan) && node.Value.Key == key)
            {
                var tile = node.Value.Tile;
                entries.Remove(node); entries.AddFirst(node);
                return tile;
            }
        if (!ReferenceEquals(piecePlan, plan))
        {
            entries.Clear(); piecePlan = plan; pieces = new(new RenderTimeline.Legacy(plan));
        }
        var video = new List<TimelineMark>();
        var peaks = new List<TimelineMark>(); var core = new List<TimelineMark>();
        var ghostPeaks = new List<TimelineMark>(); var ghostCore = new List<TimelineMark>();
        var gaps = new List<TimelineMark>(); var seams = new List<TimelineMark>();
        var axis = edited ? TimelineAxis.Edited : TimelineAxis.Source;
        var visible = pieces.Indices(new(window.Start, window.End), axis);
        var column = Math.Max(1, width / 2048);
        for (var index = visible.Start.Value; index < visible.End.Value; index++)
        {
            var piece = pieces.Pieces[index];
            var range = piece.Range(axis);
            var left = Math.Clamp(window.X(range.Start, width), 0, width);
            var right = Math.Clamp(window.X(range.End, width), 0, width);
            if (right <= left) continue;
            video.Add(new(left, 0, right - left, 30));
            if (edited && pieces.IsSeam(index)) seams.Add(new(left, 0, 1, 30));
            Wave(left, right, piece.Source.Start - range.Start, peaks, core);
        }
        if (!edited)
        {
            var cuts = plan.Cuts;
            var low = 0; var high = cuts.Count;
            while (low < high)
            {
                var middle = low + (high - low) / 2;
                if (cuts[middle].EndSample / plan.SampleRate <= window.Start) low = middle + 1; else high = middle;
            }
            for (var index = low; index < cuts.Count; index++)
            {
                var start = cuts[index].StartSample / plan.SampleRate;
                if (start >= window.End) break;
                var left = Math.Clamp(window.X(start, width), 0, width);
                var right = Math.Clamp(window.X(cuts[index].EndSample / plan.SampleRate, width), 0, width);
                if (right <= left) continue;
                gaps.Add(new(left, 0, right - left, 30));
                Wave(left, right, 0, ghostPeaks, ghostCore);
            }
        }
        void Wave(double left, double right, double offset, List<TimelineMark> peakMarks, List<TimelineMark> coreMarks)
        {
            if (waveform is null) return;
            for (var horizontal = left; horizontal < right; horizontal += column)
            {
                var end = Math.Min(right, horizontal + column);
                var amplitude = waveform.Query(window.Time(horizontal, width) + offset, window.Time(end, width) + offset);
                if (amplitude.Peak <= 0) continue;
                var peakHeight = Math.Min(28, amplitude.Peak * Math.Sqrt(2) * 30);
                var rmsHeight = Math.Min(peakHeight, amplitude.Rms * 30);
                peakMarks.Add(new(horizontal, (30 - peakHeight) / 2, end - horizontal, peakHeight));
                coreMarks.Add(new(horizontal, (30 - rmsHeight) / 2, end - horizontal, rmsHeight));
            }
        }
        var result = new TimelineMediaTile(pieces, video.ToArray(), peaks.ToArray(), core.ToArray(), ghostPeaks.ToArray(), ghostCore.ToArray(), gaps.ToArray(), seams.ToArray());
        Builds++;
        entries.AddFirst((key, result));
        if (entries.Count > Capacity) entries.RemoveLast();
        return result;
    }
}
