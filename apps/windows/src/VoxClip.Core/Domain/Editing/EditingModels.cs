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
    /// <summary>Output duration; editing §2.7.</summary>
    public double Duration => OutputSamples / SampleRate;
    /// <summary>Source to edited time; editing §7.4.</summary>
    public double MapTime(double source) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Edited to source time; editing §7.4.</summary>
    public double SourceTime(double edited) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Sample-exact gain shared by preview/export; architecture §5.3.</summary>
    public double JoinGain(long sample) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
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
}

/// <summary>Scoped counts and action gates, without product copy; editing §6.4.</summary>
public sealed record EditSummary(int FillerCount, int CutWordCount, int PauseCount, int CutPauseCount,
    bool CanCutFillers, bool CanTighten, bool HasEdits, bool CanExport);

/// <summary>Pure edit reducers and planner entry points; editing §6–7.</summary>
public static class EditingEngine
{
    /// <summary>Compute scoped counts and gates without changing the snapshot; editing §6.4.</summary>
    public static EditSummary Summarize(EditState state) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Reduce one undoable operation.</summary>
    public static EditState Reduce(EditState state, EditOperation operation) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Build ranges on the source sample grid.</summary>
    public static EditPlan BuildEditPlan(IReadOnlyList<EditSegment> segments, double duration, double sampleRate, double pauseKeepSeconds = 0.15) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Resolve clip heads/tails and explicit segment kinds.</summary>
    public static IReadOnlyList<EditSegment> BuildSegments(EditState state, double duration) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Words for captions after cuts and corrections.</summary>
    public static IReadOnlyList<CaptionWord> CaptionWords(EditState state, EditPlan plan) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
}

/// <summary>Immutable undo/redo snapshots; editing §6.</summary>
public sealed record EditHistory(EditState Present, IReadOnlyList<EditState> UndoStack, IReadOnlyList<EditState> RedoStack)
{
    /// <summary>Commit a single undo step.</summary>
    public EditHistory Apply(EditOperation operation) => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Restore previous snapshot.</summary>
    public EditHistory Undo() => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
    /// <summary>Restore next snapshot.</summary>
    public EditHistory Redo() => throw new VoxClipException(VoxClipErrorCode.NotImplemented, "win-editing");
}
