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
            return EditingEngine.BuildEditPlan(EditingEngine.BuildSegments(state with { ActiveClipId = null }, duration), duration, rate, state.PauseKeepSeconds);
        var samples = (long)Math.Floor(duration * rate + 0.5);
        return new(rate, samples, [], [new(0, samples)], samples, []);
    }
    internal static int HatchPeriod(bool pause) => pause ? 9 : 6;
    internal static double CutOpacity(bool pause) => pause ? 0.1 : 0.16;
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
        var clip = model.Clips.FirstOrDefault(clip => clip.Id == clipId);
        if (clip is null || first == model.Index(clip.Clip.StartWordId) && last == model.Index(clip.Clip.EndWordId)) return false;
        return model.ApplyBatch([new EditOperation.UpdateClip(clipId, first, last)]);
    }
    internal static string ValueText(double time, double total, int cuts, bool edited) =>
        $"{Spoken(time)} of {Spoken(total)}{(edited ? " after cuts" : " source")}, {cuts.ToString(CultureInfo.InvariantCulture)} cuts";
    private static string Spoken(double time)
    {
        var seconds = Math.Max(0, (int)Math.Round(time));
        return seconds < 60 ? $"{seconds} seconds" : $"{seconds / 60} {(seconds < 120 ? "minute" : "minutes")} {seconds % 60:00}";
    }
}
