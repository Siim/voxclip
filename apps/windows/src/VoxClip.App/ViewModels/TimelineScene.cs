using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal readonly record struct TimelineMark(double X, double Y, double Width, double Height);
internal sealed class TimelineRetainedPool<T>
{
    internal const int Layers = 15;
    internal const int Badges = 64;
    internal const int ElementBound = 256;
    internal IReadOnlyList<T> Nodes { get; }
    internal TimelineWindow Viewport { get; private set; }
    internal TimelineRetainedPool(Func<int, T> create) => Nodes = Enumerable.Range(0, Layers + Badges).Select(create).ToArray();
    internal void Move(TimelineWindow window) => Viewport = window;
}

internal sealed class TimelineScene
{
    internal const int Bins = 1024;
    internal List<TimelineMark>[] Layers { get; } = Enumerable.Range(0, TimelineRetainedPool<object>.Layers).Select(_ => new List<TimelineMark>()).ToArray();
    internal List<(double Start, double End, ClipRow Clip)> Clips { get; } = [];
    internal int BuildVersion { get; private set; }
    internal int VisitedWords { get; private set; }
    private IReadOnlyList<TimedWord>? indexedWords;
    private TimelineIntervalIndex intervalIndex = new([]);
    internal void Build(EditorViewModel model, EditPlan plan, TimelineWindow window, IReadOnlyList<float> waveform, double width, bool edited)
    {
        BuildVersion++;
        VisitedWords = 0;
        foreach (var layer in Layers) layer.Clear();
        Clips.Clear();
        double Display(double source) => edited ? plan.MapTime(source) : source;
        double Source(double displayed) => edited ? plan.SourceTime(displayed) : displayed;
        var bins = Math.Clamp((int)Math.Ceiling(width), 1, Bins);
        var kept = new bool[bins]; var fillers = new bool[bins]; var cuts = new bool[bins]; var pauses = new bool[bins];
        void Mark(bool[] target, double start, double end)
        {
            var left = Display(start); var right = Display(end);
            if (left >= right || right <= window.Start || left >= window.End) return;
            var first = Math.Clamp((int)Math.Floor(window.X(left, bins)), 0, bins - 1);
            var last = Math.Clamp((int)Math.Ceiling(window.X(right, bins)), first + 1, bins);
            Array.Fill(target, true, first, last - first);
        }
        var sourceStart = Source(window.Start); var sourceEnd = Source(window.End);
        if (!ReferenceEquals(indexedWords, model.Words))
        {
            indexedWords = model.Words;
            intervalIndex = new(indexedWords);
        }
        intervalIndex.Query(sourceStart, sourceEnd, word =>
        {
            if (model.State?.CutWordIds.Contains(word.Id) == true) { if (!edited) Mark(cuts, word.Start, word.End); }
            else
            {
                Mark(kept, word.Start, word.End);
                if (EditingAlgorithms.IsFillerText(model.DisplayText(word))) Mark(fillers, word.Start, word.End);
            }
        });
        VisitedWords = intervalIndex.VisitedWords;
        if (model.Words.Count == 0) Array.Fill(kept, true);
        void Runs(bool[] flags, int layer, double top, double height)
        {
            var first = -1;
            for (var index = 0; index <= flags.Length; index++)
            {
                if (index < flags.Length && flags[index]) { if (first < 0) first = index; continue; }
                if (first < 0) continue;
                Layers[layer].Add(new(first * width / bins, top, (index - first) * width / bins, height)); first = -1;
            }
        }
        Runs(kept, 0, 0, 30); Runs(fillers, 2, 28, 2);
        if (waveform.Count == 0) Runs(kept, 1, 11, 8);
        else for (var horizontal = 0.0; horizontal < width; horizontal += Math.Max(3, width / Bins))
        {
            var source = Source(window.Time(horizontal, width));
            if (plan.CutContaining(source) is not null || !kept[Math.Clamp((int)(horizontal * bins / width), 0, bins - 1)]) continue;
            var height = Math.Clamp(waveform[Math.Clamp((int)(source / 0.05), 0, waveform.Count - 1)] * 52, 2, 26);
            Layers[1].Add(new(horizontal, (30 - height) / 2, 2, height));
        }
        if (!edited)
        {
            foreach (var pause in model.State?.Pauses ?? [])
                if (model.State!.CutPauseIds.Contains(pause.Id)) Mark(pauses, pause.Start, pause.End);
            Runs(cuts, 3, 0, 30); Runs(pauses, 4, 0, 30);
            Hatch(3, 5, 6); Hatch(4, 6, 9);
        }
        else foreach (var cut in plan.Cuts)
        {
            var horizontal = window.X(plan.MapTime(cut.StartSample / (double)plan.SampleRate), width);
            if (horizontal >= 0 && horizontal <= width) Layers[7].Add(new(horizontal, 0, 1, 30));
        }
        void Hatch(int fill, int line, int period)
        {
            foreach (var area in Layers[fill]) Layers[line].AddRange(HatchMarks(area, period));
        }
        void Band(int first, int last, int fill, int edge, double stroke)
        {
            if (first < 0 || last < first || last >= model.Words.Count) return;
            var left = Math.Clamp(window.X(Display(model.Words[first].Start), width), 0, width);
            var right = Math.Clamp(window.X(Display(model.Words[last].End), width), 0, width);
            if (right <= left) return;
            Layers[fill].Add(new(left, 0, right - left, 30));
            Layers[edge].Add(new(left, 0, stroke, 30)); Layers[edge].Add(new(right - stroke, 0, stroke, 30));
            if (fill == 10) { Layers[edge].Add(new(left, 0, right - left, stroke)); Layers[edge].Add(new(left, 30 - stroke, right - left, stroke)); }
        }
        if (model.HasSelection) Band(model.SelectionStart, model.SelectionEnd, 8, 9, 1.5);
        Band(model.RewriteStart, model.RewriteEnd, 10, 11, 1);
        var indices = model.Words.Select((word, index) => (word.Id, Index: index)).ToDictionary(item => item.Id, item => item.Index, StringComparer.Ordinal);
        foreach (var clip in model.Clips)
        {
            var first = indices.GetValueOrDefault(clip.Clip.StartWordId, -1); var last = indices.GetValueOrDefault(clip.Clip.EndWordId, -1);
            if (first < 0 || last < first) continue;
            var start = Display(model.Words[first].Start); var end = Display(model.Words[last].End);
            if (end < window.Start || start > window.End) continue;
            var left = Math.Clamp(window.X(start, width), 0, width); var right = Math.Clamp(window.X(end, width), 0, width);
            var layer = clip.Id == model.State?.ActiveClipId ? 12 : clip.IsSuggested ? 14 : 13;
            Layers[layer].Add(new(left, -15, right - left, 0));
            Layers[layer].Add(new(left, -15, 0, 6)); Layers[layer].Add(new(right, -15, 0, 6));
            if (Clips.Count < TimelineRetainedPool<object>.Badges && (Clips.Count == 0 || left - window.X(Clips[^1].Start, width) >= 20)) Clips.Add((start, end, clip));
        }
    }
    internal static IEnumerable<TimelineMark> HatchMarks(TimelineMark area, int period)
    {
        for (var horizontal = area.X - 30; horizontal < area.X + area.Width; horizontal += period)
        {
            var left = Math.Max(area.X, horizontal); var right = Math.Min(area.X + area.Width, horizontal + 30);
            if (right > left) yield return new(left, 30 - (left - horizontal), right - left, -(right - left));
        }
    }
}
