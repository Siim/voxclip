using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal readonly record struct TimelineRange(double Minimum, double Maximum, double Value, double SmallChange, string Text);

internal sealed class TimelineViewportState
{
    private IReadOnlyList<TimedWord> words = [];
    private string[] starts = [];
    private string[] ends = [];
    private int cuts;
    private string[] sourceSpeech = [];
    private string[] editedSpeech = [];
    private EditPlan? speechPlan;
    private int speechCuts = -1;
    internal ClipRow? ActiveClip { get; private set; }
    internal int First { get; private set; }
    internal int Last { get; private set; }
    internal string StartName { get; private set; } = "Clip start";
    internal string EndName { get; private set; } = "Clip end";

    internal void Reset(EditorViewModel model)
    {
        if (!ReferenceEquals(words, model.Words))
        {
            words = model.Words;
            starts = new string[words.Count]; ends = new string[words.Count];
            for (var index = 0; index < words.Count; index++)
            {
                starts[index] = EditorViewModel.Timecode(words[index].Start);
                ends[index] = EditorViewModel.Timecode(words[index].End);
            }
        }
        var number = ActiveClip?.Number;
        ActiveClip = null;
        for (var index = 0; index < model.Clips.Count; index++)
            if (model.Clips[index].Id == model.State?.ActiveClipId) { ActiveClip = model.Clips[index]; break; }
        First = ActiveClip is null ? -1 : model.Index(ActiveClip.Clip.StartWordId);
        Last = ActiveClip is null ? -1 : model.Index(ActiveClip.Clip.EndWordId);
        if (number != ActiveClip?.Number)
        {
            StartName = ActiveClip is null ? "Clip start" : $"Clip {ActiveClip.Number} start";
            EndName = ActiveClip is null ? "Clip end" : $"Clip {ActiveClip.Number} end";
        }
        var summary = model.Summary;
        cuts = summary.CutWordCount + summary.CutPauseCount;
    }

    internal (double Start, double End)? Bounds(int first, int last) => ActiveClip is not null && first >= 0 && last >= first && last < words.Count
        ? (words[first].Start, words[last].End) : null;
    internal TimelineRange Trim(bool start, int first, int last)
    {
        if (Bounds(first, last) is null) return new(0, 0, 0, 1, "");
        var value = start ? first : last;
        return new(start ? 0 : first, start ? last : words.Count - 1, value, 1, start ? starts[value] : ends[value]);
    }
    internal TimelineRange Playhead(EditPlan plan, TimelineWindow window, double source, bool edited)
    {
        var value = edited ? plan.MapTime(source) : source;
        var total = edited ? plan.Duration : plan.TotalSamples / plan.SampleRate;
        Prepare(plan);
        var speech = edited ? editedSpeech : sourceSpeech;
        var playheadText = speech[Math.Clamp((int)Math.Round(value), 0, speech.Length - 1)];
        var next = TimelineLayout.Step(words, source, 1, false);
        var nextTime = next < 0 ? value + 0.1 : edited ? plan.MapTime(words[next].Start) : words[next].Start;
        return new(window.Start, window.End, Math.Clamp(value, window.Start, window.End), Math.Max(0.001, nextTime - value), playheadText);
    }
    internal void Prepare(EditPlan plan)
    {
        if (ReferenceEquals(speechPlan, plan) && speechCuts == cuts) return;
        speechPlan = plan;
        speechCuts = cuts;
        string[] Speech(double duration, bool edited)
        {
            var values = new string[(int)Math.Ceiling(duration) + 1];
            for (var second = 0; second < values.Length; second++) values[second] = TimelineLayout.ValueText(second, duration, cuts, edited);
            return values;
        }
        sourceSpeech = Speech(plan.TotalSamples / (double)plan.SampleRate, false);
        editedSpeech = Speech(plan.Duration, true);
    }
    internal int PointerWord(double source) => words.Count == 0 ? -1 : TimelineLayout.WordAt(words, source);
    internal int WordCount => words.Count;
}
