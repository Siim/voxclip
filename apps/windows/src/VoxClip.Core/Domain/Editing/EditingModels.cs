using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Clips;
using TranscriptModel = VoxClip.Core.Domain.Transcript.Transcript;
namespace VoxClip.Core.Domain.Editing;

/// <summary>Derived gap, never stored; editing §2.4.</summary>
public sealed record Pause(string Id, int AfterIndex, double Start, double End, double Duration, string Label);

/// <summary>Manual or accepted-model clip origin; editing §2.5.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ClipOrigin>))]
public enum ClipOrigin
{
    /// <summary>Manual selection.</summary>
    [JsonStringEnumMemberName("manual")] Manual,
    /// <summary>Accepted clip candidate.</summary>
    [JsonStringEnumMemberName("ai")] Ai
}

/// <summary>Inclusive word-id range; editing §2.5 and project schema. A range never rewrites cuts.</summary>
public sealed record ClipRange(string Id, string StartWordId, string EndWordId, string? Title,
    ClipOrigin Origin, string? AiResultId, int? AiClipIndex, bool Selected);

/// <summary>Immutable editor snapshot; editing §2.5.</summary>
public sealed record EditState(TranscriptModel Transcript, IReadOnlyList<Pause> Pauses, double PauseThresholdSeconds,
    double PauseKeepSeconds, IReadOnlySet<string> CutWordIds, IReadOnlySet<string> CutPauseIds,
    IReadOnlyDictionary<string, string> Corrections, IReadOnlyList<ClipRange> Clips, string? ActiveClipId);

/// <summary>Explicit planner kind; editing §2.6. Never infer from an id.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<EditSegmentKind>))]
public enum EditSegmentKind
{
    /// <summary>Transcript item.</summary>
    [JsonStringEnumMemberName("word")] Word,
    /// <summary>Derived pause.</summary>
    [JsonStringEnumMemberName("pause")] Pause,
    /// <summary>Exact cut interval, always cut.</summary>
    [JsonStringEnumMemberName("range")] Range
}

/// <summary>Pure planner input; editing §2.6.</summary>
public sealed record EditSegment(string Id, EditSegmentKind Kind, WordKind? WordKind, string? Text, double Start, double End, bool Cut);

/// <summary>Half-open source sample interval; editing §2.7.</summary>
public readonly record struct MediaInterval(long StartSample, long EndSample);

/// <summary>One edited-timeline join and sample fade lengths; architecture §5.3.</summary>
public readonly record struct Join(long OutSample, long FadeOutLen, long FadeInLen);

/// <summary>Sample-exact immutable plan; editing §2.7 and §7. win-editing implements the math in place.</summary>
public sealed record EditPlan(double SampleRate, long TotalSamples, IReadOnlyList<MediaInterval> Cuts,
    IReadOnlyList<MediaInterval> Kept, long OutputSamples, IReadOnlyList<Join> Joins)
{
    private readonly double sampleRate = SampleRate;
    private readonly long totalSamples = TotalSamples;
    private readonly IReadOnlyList<MediaInterval> kept = Kept;
    private long outputSamples = NormalizeOutputSamples(Kept, OutputSamples);
    private IReadOnlyList<Join> joins = NormalizeJoins(SampleRate, TotalSamples, Kept, Joins);
    private GainPart[] gainParts = BuildGainParts(SampleRate, TotalSamples, Kept);

    /// <summary>Native audio sample rate. A record copy rebuilds its gain table when changed.</summary>
    public double SampleRate { get => sampleRate; init { sampleRate = value; RebuildDerived(); } }
    /// <summary>Source sample count.</summary>
    public long TotalSamples { get => totalSamples; init { totalSamples = value; RebuildDerived(); } }
    /// <summary>Kept source intervals. A record copy rebuilds its gain table when changed.</summary>
    public IReadOnlyList<MediaInterval> Kept { get => kept; init { kept = value; RebuildDerived(); } }
    /// <summary>Kept sample count; supplied legacy values are normalized, editing §2.7.</summary>
    public long OutputSamples { get => outputSamples; init { } }
    /// <summary>Joins derived from kept intervals and source bounds, editing §2.7.</summary>
    public IReadOnlyList<Join> Joins { get => joins; init { } }

    private void RebuildDerived()
    {
        outputSamples = Kept.Sum(part => part.EndSample - part.StartSample);
        joins = EditingPlanner.BuildJoins(SampleRate, TotalSamples, Kept);
        gainParts = BuildGainParts(SampleRate, TotalSamples, Kept);
    }

    private static long NormalizeOutputSamples(IReadOnlyList<MediaInterval> intervals, long supplied)
    {
        var derived = intervals.Sum(part => part.EndSample - part.StartSample);
        return derived;
    }

    private static IReadOnlyList<Join> NormalizeJoins(double rate, long total, IReadOnlyList<MediaInterval> intervals, IReadOnlyList<Join> supplied)
    {
        var derived = EditingPlanner.BuildJoins(rate, total, intervals);
        return derived;
    }

    private readonly record struct GainPart(long Start, long End, long FadeIn, long FadeOut);

    private static GainPart[] BuildGainParts(double rate, long total, IReadOnlyList<MediaInterval> intervals)
    {
        var parts = new GainPart[intervals.Count];
        long offset = 0;
        for (var index = 0; index < intervals.Count; index++)
        {
            var interval = intervals[index];
            var length = interval.EndSample - interval.StartSample;
            var fade = (long)Math.Min(EditingMath.Round(0.005 * rate), length / 2);
            parts[index] = new(offset, offset + length, interval.StartSample > 0 ? fade : 0, interval.EndSample < total ? fade : 0);
            offset += length;
        }
        return parts;
    }

    /// <summary>Output duration; editing §2.7.</summary>
    public double Duration => OutputSamples / SampleRate;
    /// <summary>Source to edited time; editing §7.4.</summary>
    public double MapTime(double source)
    {
        var sample = EditingMath.ClampSample(double.IsFinite(source) ? source : 0, SampleRate, TotalSamples);
        long removed = 0;
        for (var index = 0; index < Cuts.Count; index++)
        {
            var cut = Cuts[index];
            if (cut.StartSample >= sample) break;
            removed += Math.Min(sample, cut.EndSample) - cut.StartSample;
        }
        return Math.Clamp(sample - removed, 0, OutputSamples) / SampleRate;
    }
    /// <summary>Edited to source time; editing §7.4.</summary>
    public double SourceTime(double edited)
    {
        var remaining = EditingMath.ClampSample(double.IsFinite(edited) ? edited : 0, SampleRate, OutputSamples);
        for (var index = 0; index < Kept.Count; index++)
        {
            var part = Kept[index];
            var length = part.EndSample - part.StartSample;
            if (remaining < length) return (part.StartSample + remaining) / SampleRate;
            remaining -= length;
        }
        return TotalSamples / SampleRate;
    }
    /// <summary>Find the half-open source cut without rounding the probe, editing §7.5.</summary>
    public MediaInterval? CutContaining(double source)
    {
        for (var index = 0; index < Cuts.Count; index++)
        {
            var cut = Cuts[index];
            if (cut.StartSample / SampleRate <= source && source < cut.EndSample / SampleRate) return cut;
        }
        return null;
    }
    /// <summary>Sample-exact gain shared by preview/export; architecture §5.3.</summary>
    public double JoinGain(long sample)
    {
        if (sample < 0 || sample >= OutputSamples) return 1;
        var lower = 0;
        var upper = gainParts.Length;
        while (lower < upper)
        {
            var middle = lower + (upper - lower) / 2;
            if (gainParts[middle].End <= sample) lower = middle + 1;
            else upper = middle;
        }
        if (lower == gainParts.Length) return 1;
        var part = gainParts[lower];
        var relative = sample - part.Start;
        var length = part.End - part.Start;
        var gain = 1.0;
        if (relative < part.FadeIn) gain = gain * relative / part.FadeIn;
        if (length - 1 - relative < part.FadeOut) gain = gain * (length - 1 - relative) / part.FadeOut;
        return (float)gain;
    }
}

/// <summary>Edited-timeline word, derived and never stored; editing §2.8.</summary>
public sealed record CaptionWord(string Id, string Text, double Start, double End);

/// <summary>Editor operations; editing §6. Reducers are pure and one operation is one undo step.</summary>
public abstract record EditOperation
{
    /// <summary>Flip one word or pause cut by lookup, not id prefix; editing §6.3.</summary>
    public sealed record Toggle(string Id) : EditOperation;
    /// <summary>Toggle all selected word/pause ids as one undo step; editing §6.3.</summary>
    public sealed record CutSelection(IReadOnlyList<string> Ids) : EditOperation;
    /// <summary>Uncut selected word/pause ids; editing §6.3.</summary>
    public sealed record RestoreSelection(IReadOnlyList<string> Ids) : EditOperation;
    /// <summary>Set cut state of selected items.</summary>
    public sealed record SetWordCuts(IReadOnlyList<string> Ids, bool Cut) : EditOperation;
    /// <summary>Set cut state of pauses.</summary>
    public sealed record SetPauseCuts(IReadOnlyList<string> Ids, bool Cut) : EditOperation;
    /// <summary>Apply caption correction without moving timings.</summary>
    public sealed record Correct(string Id, string Text) : EditOperation;
    /// <summary>Cut fillers using current corrected text.</summary>
    public sealed record CutFillers : EditOperation;
    /// <summary>Cut detected pauses.</summary>
    public sealed record TightenPauses : EditOperation;
    /// <summary>Restore cuts but keep corrections and clips.</summary>
    public sealed record RestoreCuts : EditOperation;
    /// <summary>Select a range layer, or the full edit.</summary>
    public sealed record SetActiveClip(string? Id) : EditOperation;
    /// <summary>Add an inclusive range.</summary>
    public sealed record AddClip(ClipRange Clip) : EditOperation;
    /// <summary>Add new result ranges in one Find clips undo step; editing §6.3 and AI §11.8.</summary>
    public sealed record AddAiClips(string ResultId, IReadOnlyList<AiClip> Clips) : EditOperation;
    /// <summary>Move inclusive clip edges without changing cuts; editing §6.3.</summary>
    public sealed record UpdateClip(string Id, int StartIndex, int EndIndex) : EditOperation;
    /// <summary>Set trimmed title or clear it; editing §6.3.</summary>
    public sealed record RenameClip(string Id, string? Title) : EditOperation;
    /// <summary>Set the export checkbox only; editing §6.3.</summary>
    public sealed record SetClipSelected(string Id, bool Selected) : EditOperation;
    /// <summary>Delete one range layer.</summary>
    public sealed record RemoveClip(string Id) : EditOperation;
    /// <summary>Set retained pause breath in seconds; editing §6.3.</summary>
    public sealed record SetPauseKeep(double Seconds) : EditOperation;
    /// <summary>Re-derive pauses and prune missing pause ids; editing §6.3.</summary>
    public sealed record SetPauseThreshold(double Seconds) : EditOperation;
    /// <summary>Replace imported source words and clear transcript-dependent edits, editing §10.5.</summary>
    public sealed record ReplaceTranscript(TranscriptModel Transcript) : EditOperation;
}

/// <summary>Scoped counts and action gates, without product copy; editing §6.4.</summary>
public sealed record EditSummary(int FillerCount, int CutWordCount, int PauseCount, int CutPauseCount,
    bool CanCutFillers, bool CanTighten, bool HasEdits, bool CanExport);

/// <summary>Pure edit reducers and planner entry points; editing §6–7.</summary>
public static class EditingEngine
{
    /// <summary>Restore the persisted edit subset, or null without a transcript; editing §10.4 and plan W3.</summary>
    public static EditState? FromProject(Project project) => EditingProject.FromProject(project);
    /// <summary>Store only persistent editing fields and prune removed clip captions; editing §10.4–10.7 and plan W3.</summary>
    public static Project ApplyToProject(Project project, EditState state) => EditingProject.ApplyToProject(project, state);
    /// <summary>Compute scoped counts and gates without changing the snapshot; editing §6.4.</summary>
    public static EditSummary Summarize(EditState state) => EditingSession.Summarize(state);
    /// <summary>Reduce one undoable operation.</summary>
    public static EditState Reduce(EditState state, EditOperation operation) => EditingSession.Reduce(state, operation);
    /// <summary>Reduce with project AI-reference and batch validation, editing §6.3.</summary>
    public static EditState Reduce(EditState state, EditOperation operation, IReadOnlyList<AiResult> aiResults) => EditingSession.Reduce(state, operation, aiResults);
    /// <summary>Build ranges on the source sample grid.</summary>
    public static EditPlan BuildEditPlan(IReadOnlyList<EditSegment> segments, double duration, double sampleRate, double pauseKeepSeconds = 0.15)
        => EditingPlanner.Build(segments, duration, sampleRate, pauseKeepSeconds);
    /// <summary>Resolve clip heads/tails and explicit segment kinds.</summary>
    public static IReadOnlyList<EditSegment> BuildSegments(EditState state, double duration) => EditingSession.BuildSegments(state);
    /// <summary>Words for captions after cuts and corrections.</summary>
    public static IReadOnlyList<CaptionWord> CaptionWords(EditState state, EditPlan plan) => CaptionCopy(BuildSegments(state, plan.TotalSamples / plan.SampleRate), plan);
    /// <summary>Derive transcript copy from current speech text, never split a multi-word correction, editing §6.5.</summary>
    public static string TranscriptText(EditState state)
        => string.Join(" ", state.Transcript.Words.Where(word => word.Kind == Shared.WordKind.Word).Select(word => state.Corrections.GetValueOrDefault(word.Id, word.Text)));
    /// <summary>Pre-rounding cut bounds by original segment index (identity, not value), editing §7.3.</summary>
    public static TimeRange CutRange(IReadOnlyList<EditSegment> segments, int index, double duration, double pauseKeepSeconds = 0.15)
        => EditingPlanner.CutRange(segments, index, duration, pauseKeepSeconds);
    /// <summary>Map valid kept speech words independently, preserving corrected text exactly, editing §7.6.</summary>
    public static IReadOnlyList<CaptionWord> CaptionCopy(IReadOnlyList<EditSegment> segments, EditPlan plan)
        => segments.Where(segment => segment.Kind == EditSegmentKind.Word && (segment.WordKind ?? Shared.WordKind.Word) == Shared.WordKind.Word && !segment.Cut && EditingPlanner.Valid(segment))
            .Select(segment => new CaptionWord(segment.Id, segment.Text ?? "", plan.MapTime(segment.Start), plan.MapTime(segment.End))).Where(word => word.End > word.Start).ToArray();
}

/// <summary>Immutable undo/redo snapshots; editing §6.</summary>
public sealed record EditHistory(EditState Present, IReadOnlyList<EditState> UndoStack, IReadOnlyList<EditState> RedoStack)
{
    /// <summary>Commit a single undo step.</summary>
    public EditHistory Apply(EditOperation operation) => Record(EditingEngine.Reduce(Present, operation));
    /// <summary>Commit one step with the project's current AI-reference context, editing §6.3.</summary>
    public EditHistory Apply(EditOperation operation, IReadOnlyList<AiResult> aiResults) => Record(EditingEngine.Reduce(Present, operation, aiResults));
    private EditHistory Record(EditState next) => ReferenceEquals(next, Present) ? this : new(next, UndoStack.TakeLast(499).Append(Present).ToArray(), []);
    /// <summary>Restore previous snapshot.</summary>
    public EditHistory Undo() => UndoStack.Count == 0 ? this : new(UndoStack[^1], UndoStack.Take(UndoStack.Count - 1).ToArray(), RedoStack.Append(Present).ToArray());
    /// <summary>Restore next snapshot.</summary>
    public EditHistory Redo() => RedoStack.Count == 0 ? this : new(RedoStack[^1], UndoStack.TakeLast(499).Append(Present).ToArray(), RedoStack.Take(RedoStack.Count - 1).ToArray());
}
