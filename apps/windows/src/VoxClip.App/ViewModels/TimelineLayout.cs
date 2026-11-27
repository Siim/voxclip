using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal readonly record struct TimelineWindow(double Start, double End)
{
    internal double Duration => Math.Max(0.001, End - Start);
    internal double X(double time, double width) => (time - Start) / Duration * width;
    internal double Time(double position, double width) => Start + Math.Clamp(position / Math.Max(1, width), 0, 1) * Duration;
}

internal static class TimelineLayout
{
    internal const double HeaderWidth = 112;
    internal const double ToolbarHeight = 32;
    internal const double OverviewHeight = 24;
    internal const double RulerHeight = 22;
    internal static TimelineTrackGeometry Tracks(int size, IReadOnlyDictionary<TimelineLane, int>? rows = null) => new(size, rows);
    internal static TimelineWindow Clamp(TimelineWindow window, double duration)
    {
        duration = double.IsFinite(duration) ? Math.Max(.001, duration) : .001;
        var length = double.IsFinite(window.Duration) ? Math.Clamp(window.Duration, Math.Min(.1, duration), duration) : duration;
        var start = double.IsFinite(window.Start) ? Math.Clamp(window.Start, 0, duration - length) : 0;
        return new(start, start + length);
    }
    internal static TimelineWindow Zoom(TimelineWindow window, double duration, double factor, double anchor)
    {
        if (!double.IsFinite(factor) || factor <= 0) return Clamp(window, duration);
        anchor = Math.Clamp(double.IsFinite(anchor) ? anchor : .5, 0, 1);
        var length = window.Duration / factor;
        var start = window.Start + window.Duration * anchor - length * anchor;
        return Clamp(new(start, start + length), duration);
    }
    internal const double TrackTop = 25;
    internal const double BracketTop = TrackTop - 15;
    internal const double BadgeTop = BracketTop - 9;
    internal static TimelineWindow Window(double duration, double? start = null, double? end = null)
    {
        if (start is null || end is null) return new(0, Math.Max(0.001, duration));
        var padding = Math.Clamp((end.Value - start.Value) * 0.1, 1.5, 3);
        return new(Math.Max(0, start.Value - padding), Math.Min(duration, end.Value + padding));
    }
    internal static EditPlan Plan(EditorViewModel model)
    {
        var duration = model.Project.Media.Source.DurationSeconds;
        var rate = model.Project.Media.Source.Audio?.SampleRate ?? 48000;
        if (model.State is { } state)
            return EditingEngine.BuildPlan(model.IsStoryClip ? state : state with { ActiveClipId = null }, duration, rate);
        var samples = (long)Math.Floor(duration * rate + 0.5);
        return new(rate, samples, [], [new(0, samples)], samples, []);
    }
    internal static int HatchPeriod(bool pause) => pause ? 9 : 6;
    internal static double CutOpacity(bool pause) => pause ? 0.1 : 0.16;
    internal static string FitWords(string text, double width, Func<string, double> measure)
    {
        if (width < 24) return "";
        width = Math.Max(0, width - 8);
        if (measure(text) <= width) return text;
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var best = "";
        for (var count = 1; count <= words.Length; count++)
        {
            var candidate = string.Join(" ", words, 0, count);
            if (measure(candidate) > width) break;
            if (measure(candidate + " …") <= width) best = candidate + " …";
            else if (count == 1 && best.Length == 0) best = candidate;
        }
        return best;
    }
    internal static int WordAt(IReadOnlyList<TimedWord> words, double source)
    {
        var low = 0;
        var high = words.Count;
        while (low < high)
        {
            var middle = low + (high - low) / 2;
            if (words[middle].Start <= source) low = middle + 1; else high = middle;
        }
        return Math.Clamp(low - 1, 0, Math.Max(0, words.Count - 1));
    }
    internal static int Step(IReadOnlyList<TimedWord> words, double source, int direction, bool sentence)
    {
        if (words.Count == 0) return -1;
        var index = WordAt(words, source);
        if (!sentence) return Math.Clamp(index + direction, 0, words.Count - 1);
        if (direction < 0)
        {
            index = Math.Max(0, index - 1);
            while (index > 0 && !EndsSentence(words[index - 1].Text)) index--;
        }
        else
        {
            while (index < words.Count - 1 && !EndsSentence(words[index].Text)) index++;
            index = Math.Min(words.Count - 1, index + 1);
        }
        return index;
    }
    private static bool EndsSentence(string text) => text.TrimEnd().EndsWithAny(".!?…");
    internal static (int First, int Last) Trim(int first, int last, int target, int count, bool start) => start
        ? (Math.Clamp(target, 0, last), last) : (first, Math.Clamp(target, first, Math.Max(first, count - 1)));
    internal static bool CommitTrim(EditorViewModel model, string clipId, int first, int last)
    {
        if (model.IsReadOnly || model.Busy || first < 0 || last < first || last >= model.Words.Count) return false;
        var clip = model.Clips.FirstOrDefault(clip => clip.Id == clipId);
        if (clip is null || first == model.Index(clip.Clip.StartWordId) && last == model.Index(clip.Clip.EndWordId)) return false;
        if (clip.Clip.Parts is not null) return false;
        var id = new TimelineItemId(TimelineItemType.Clip, clipId);
        var edits = new List<TimelineEdit>();
        if (last > model.Index(clip.Clip.EndWordId)) edits.Add(new TimelineEdit.Trim(id, TimelineEdge.End, model.Words[last].End));
        if (first != model.Index(clip.Clip.StartWordId)) edits.Add(new TimelineEdit.Trim(id, TimelineEdge.Start, model.Words[first].Start));
        if (last < model.Index(clip.Clip.EndWordId)) edits.Add(new TimelineEdit.Trim(id, TimelineEdge.End, model.Words[last].End));
        return new TimelineEditSession(model, clipId).Commit(edits);
    }
    internal static string ValueText(double time, double total, int cuts, bool edited) =>
        $"{Spoken(time)} of {Spoken(total)}{(edited ? " after cuts" : " source")}, {cuts.ToString(CultureInfo.InvariantCulture)} cuts";
    private static string Spoken(double time)
    {
        var seconds = Math.Max(0, (int)Math.Round(time));
        return seconds < 60 ? $"{seconds} seconds" : $"{seconds / 60} {(seconds < 120 ? "minute" : "minutes")} {seconds % 60:00}";
    }
}

internal readonly record struct TimelineTrackGeometry
{
    private readonly (double Top, double Height, double Row)[] lanes;
    internal double Top(TimelineLane lane) => lanes[(int)lane].Top;
    internal double LaneHeight(TimelineLane lane) => lanes[(int)lane].Height;
    internal double RowHeight(TimelineLane lane) => lanes[(int)lane].Row;
    internal double VideoTop => Top(TimelineLane.V1);
    internal double AudioTop => Top(TimelineLane.A1);
    internal double CaptionTop => Top(TimelineLane.CC);
    internal double EffectsTop => Top(TimelineLane.FX);
    internal double MusicTop => Top(TimelineLane.M1);
    internal double VideoHeight => LaneHeight(TimelineLane.V1);
    internal double AudioHeight => LaneHeight(TimelineLane.A1);
    internal double CaptionHeight => LaneHeight(TimelineLane.CC);
    internal double EffectsHeight => LaneHeight(TimelineLane.FX);
    internal double MusicHeight => LaneHeight(TimelineLane.M1);
    internal double Height { get; }
    internal TimelineTrackGeometry(int size, IReadOnlyDictionary<TimelineLane, int>? rows)
    {
        size = Math.Clamp(size, 0, 2);
        var ordered = Enum.GetValues<TimelineLane>();
        lanes = new (double, double, double)[ordered.Length];
        double top = TimelineLayout.OverviewHeight + TimelineLayout.RulerHeight + 1;
        foreach (var lane in ordered)
        {
            var count = Math.Max(1, rows?.GetValueOrDefault(lane) ?? 1);
            var row = lane switch
            {
                TimelineLane.V1 => size switch { 0 => 28, 2 => 52, _ => 36 },
                TimelineLane.A1 => size switch { 0 => 32, 2 => 64, _ => 44 },
                TimelineLane.S1 or TimelineLane.M1 => size switch { 0 => 22, 2 => 44, _ => 30 },
                _ => size switch { 0 => 20, 2 => 28, _ => 24 }
            };
            var height = row * count;
            lanes[(int)lane] = (top, height, row);
            top += height + 1;
        }
        Height = top + 9;
    }
}
