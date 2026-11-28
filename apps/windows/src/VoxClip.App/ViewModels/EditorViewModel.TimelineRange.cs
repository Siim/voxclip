using System.Globalization;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>An exact stretch of the timeline (issue #41): what a Ctrl+drag with Snap off (or Alt held) leaves, or I and O set
/// there. Frame-rounded, in the recording's own seconds, with the recording's key when the project has several (#31). A
/// selection, never part of the project. Twin of the Mac <c>TimelineRange</c>.</summary>
internal sealed record TimelineExactRange(string? Recording, double Start, double End);

/// <summary>Playhead steps on the timeline (issue #41): , and . move one frame with nothing selected.</summary>
internal static class TimelinePrecision
{
    /// <summary>The previous or next frame on the 1/<paramref name="fps"/> grid from <paramref name="time"/> (axis seconds).</summary>
    internal static double FrameStep(double time, double fps, int direction)
    {
        if (!double.IsFinite(fps) || fps <= 0) fps = 30;
        var frame = time * fps;
        var next = direction < 0 ? Math.Ceiling(frame - 1e-6) - 1 : Math.Floor(frame + 1e-6) + 1;
        return next / fps;
    }

    /// <summary>Where the next step starts: the last step's target while the playhead still reads where that step began (its seek
    /// has not landed) or within half a frame of the target (the preview reported a decoded frame time a little off the grid),
    /// so a held key keeps stepping. Otherwise the playhead.</summary>
    internal static double StepOrigin(double playhead, double fps, (double From, double To)? last)
    {
        if (!double.IsFinite(fps) || fps <= 0) fps = 30;
        return last is { } step && (Math.Abs(playhead - step.From) < 1e-9 || Math.Abs(playhead - step.To) < 0.5 / fps) ? step.To : playhead;
    }
}

// Exact positions on the timeline (issue #41, step 1): the playhead steps by frame and by word boundary, and an exact range can
// be marked, played and used. Words stay the unit that cuts. Twin of the Mac EditorModel+TimelineRange.
public sealed partial class EditorViewModel
{
    /// <summary>With nothing selected: how to select, and the reason each range action is disabled. Windows drags scrub, so the
    /// word drag is Ctrl+drag (design §5.2).</summary>
    internal const string TimelineRangeHint = "Ctrl+drag across the waveform to select words. Turn Snapping off for an exact range.";
    internal const string TimelineCutRangeReason = "Exact cuts are coming. Turn Snapping on to cut words.";
    internal const string TimelineMakeClipHelp = "Clip edges follow words";
    internal const string TimelineAlreadyCutReason = "Everything selected is already cut.";
    private const string TimelineNotReady = "The timeline is not ready to edit.";

    private TimelineExactRange? exactRange;
    private string? exactRangeScope;

    /// <summary>The exact range, or null. The words wholly inside it are selected underneath; any other word or item selection
    /// replaces it. A selection, so no undo step.</summary>
    internal TimelineExactRange? ExactRange => exactRange;

    /// <summary>Why the last range action was refused, shown inline in the timeline's edit bar; any selection change clears it.</summary>
    internal string? TimelineRangeMessage { get; private set; }

    /// <summary>Play range: the page seeks to In and plays, stopping at Out (project clock; the page maps both onto the preview's
    /// timeline with <see cref="TimelineRangePlayback"/>).</summary>
    internal event EventHandler<TimeRange>? TimelineRangePlayRequested;

    /// <summary>The take's frame rate: the grid the item nudge uses (TimelineEdits frames), 30 when unknown.</summary>
    internal double TimelineFrameRate => project.Media.Source.Video?.FrameRate is { } fps && double.IsFinite(fps) && fps > 0 ? fps : 30;

    private bool CanEditTimeline => HasTranscript && !IsReadOnly && !Busy && !isLeaving;

    /// <summary>The exact range on the project clock, or null.</summary>
    internal TimeRange? ExactRangeSource
    {
        get
        {
            if (exactRange is not { } range) return null;
            if (range.Recording is not { } key) return new(range.Start, range.End);
            if (RecordingClock is not { } clock || clock.Regions.FirstOrDefault(region => region.Key == key) is not { } region) return null;
            var offset = (double)region.OffsetSamples / clock.SampleRate;
            return new(offset + range.Start, offset + range.End);
        }
    }

    /// <summary>What the edit bar's range actions act on, on the project clock: the exact range, else the selected words.</summary>
    internal TimeRange? TimelineActionRange => ExactRangeSource ?? (HasSelection ? new TimeRange(Words[SelectionStart].Start, Words[SelectionEnd].End) : null);

    /// <summary>The open scope's word spans: the clip's parts, or every word.</summary>
    private IReadOnlyList<(int Start, int End)> TimelineScopeSpans() => Words.Count == 0 ? [] :
        ActiveClip is { } clip ? clip.PlayPartIndices(Words) ?? [] : [(0, Words.Count - 1)];

    /// <summary>The scope on the project clock around <paramref name="time"/>: the story part there (else the nearest), the
    /// clip's play range, or the whole take.</summary>
    private TimeRange TimelineScopeBounds(double time)
    {
        var spans = TimelineScopeSpans();
        if (ActiveClip is not { } clip || spans.Count == 0) return new(0, ProjectClockDuration);
        var ranges = spans.Select((span, index) => EditingAlgorithms.ClipTimes(Words, span.Start, span.End, index == 0 ? clip.LeadInSeconds : null))
            .Select(range => new TimeRange(range.Start, Math.Min(range.End, ProjectClockDuration))).ToArray();
        if (ranges.Length == 1) return ranges[0];
        return ranges.FirstOrDefault(range => range.Start <= time && time <= range.End) is { End: > 0 } inside ? inside
            : ranges.MinBy(range => Math.Min(Math.Abs(range.Start - time), Math.Abs(range.End - time)));
    }

    // MARK: Playhead steps

    /// <summary>⇧, / ⇧. with nothing selected: the previous or next word start or end in the scope from <paramref name="source"/>,
    /// compared on the axis <paramref name="toAxis"/> maps to; with <paramref name="skipCuts"/> (Edited) folded words are skipped,
    /// as ← and → skip them. Null when there is none.</summary>
    internal double? TimelineWordBoundary(double source, int direction, Func<double, double> toAxis, bool skipCuts)
    {
        var current = toAxis(source);
        double? best = null;
        var bestAxis = 0.0;
        var cuts = state?.CutWordIds;
        foreach (var (first, last) in TimelineScopeSpans())
            for (var index = first; index <= last; index++)
            {
                var word = Words[index];
                if (skipCuts && cuts?.Contains(word.Id) == true) continue;
                foreach (var edge in new[] { word.Start, word.End })
                {
                    var time = toAxis(edge);
                    var better = direction > 0 ? time > current + 1e-6 && (best is null || time < bestAxis) : time < current - 1e-6 && (best is null || time > bestAxis);
                    if (better) { best = edge; bestAxis = time; }
                }
            }
        return best;
    }

    // MARK: The exact range

    /// <summary>Marks <paramref name="start"/>–<paramref name="end"/> (project clock) as the exact range, rounded to frames, kept
    /// inside the recording (and the story part) at <paramref name="anchor"/>, at least one frame long, and selects the words
    /// wholly inside it. Returns false, clearing the range, when it can't be kept.</summary>
    internal bool SetExactRange(double start, double end, double anchor)
    {
        if (!double.IsFinite(start) || !double.IsFinite(end) || !double.IsFinite(anchor) || Words.Count == 0) { ClearExactRange(); return false; }
        if (IsStoryClip)
        {
            var part = TimelineScopeBounds(anchor);
            start = Math.Clamp(start, part.Start, part.End); end = Math.Clamp(end, part.Start, part.End);
        }
        string? key = null;
        double offset = 0, spanEnd = ProjectClockDuration;
        if (HasSeveralRecordings && RecordingClock is { } clock)
        {
            var sample = Math.Clamp((long)Math.Floor(anchor * clock.SampleRate), 0, Math.Max(0, clock.TotalSamples - 1));
            if (clock.RegionAt(sample) is not { } region) { ClearExactRange(); return false; }
            key = region.Key;
            offset = (double)region.OffsetSamples / clock.SampleRate;
            spanEnd = (double)region.EndSample / clock.SampleRate;
        }
        var fps = TimelineFrameRate;
        var length = spanEnd - offset;
        double Frame(double time) => Math.Min(length, Math.Round((Math.Clamp(time, offset, spanEnd) - offset) * fps, MidpointRounding.AwayFromZero) / fps);
        var lower = Frame(Math.Min(start, end)); var upper = Frame(Math.Max(start, end));
        if (upper <= lower) { if (lower + 1 / fps <= length) upper = lower + 1 / fps; else lower = Math.Max(0, upper - 1 / fps); }
        if (upper <= lower) { ClearExactRange(); return false; }
        exactRange = new(key, lower, upper);
        exactRangeScope = state?.ActiveClipId;
        SelectWordsInside(new(offset + lower, offset + upper));
        return true;
    }

    /// <summary>Esc on the timeline: the range and the words under it go. False when there was no range.</summary>
    internal bool ClearExactRange()
    {
        if (exactRange is null) return false;
        DropExactRange();
        SetSelectionIndices(-1, -1);
        return true;
    }

    /// <summary>Puts back a range the timeline had before a gesture that Esc cancels.</summary>
    internal void RestoreExactRange(TimelineExactRange range)
    {
        var offset = range.Recording is { } key && RecordingClock is { } clock && clock.Regions.FirstOrDefault(region => region.Key == key) is { } region
            ? (double)region.OffsetSamples / clock.SampleRate : 0;
        SetExactRange(offset + range.Start, offset + range.End, offset + (range.Start + range.End) / 2);
    }

    /// <summary>Forgets the range (and the Ask Claude range it set) without touching the words.</summary>
    private bool DropExactRange()
    {
        if (exactRange is null) return false;
        exactRange = null;
        if (AskClaude.TimeRange is not null) SetAskClaudeTimeRange(null);
        return true;
    }

    /// <summary>⇧-click at <paramref name="point"/> (project clock): the range or word selection out to it. <paramref name="exact"/>
    /// (Snap off, or Alt or N held) keeps an exact range at frame grain; otherwise the selection becomes whole words.</summary>
    internal bool ExtendTimelineSelection(double point, bool exact)
    {
        if (TimelineActionRange is not { } current || !double.IsFinite(point)) return false;
        point = ClampProjectTime(point);
        double lower = current.Start, upper = current.End;
        if (point < lower) lower = point;
        else if (point > upper) upper = point;
        else if (point - lower < upper - point) lower = point;
        else upper = point;
        if (exact) return SetExactRange(lower, upper, (current.Start + current.End) / 2);
        if (SnapToScopeWords(new(lower, upper)) is not { } words) return false;
        DropExactRange();
        SetSelectionIndices(words.First, words.Last);
        return true;
    }

    /// <summary>I or O with timeline focus: the range's In or Out at the playhead, on the frame grid. Without a range, or when
    /// the new edge passes the other one, the other edge is the scope's start or end (the playhead's story part).</summary>
    internal bool SetExactRangeEdge(bool start)
    {
        if (Words.Count == 0) return false;
        var scope = TimelineScopeBounds(ClampProjectTime(SourceTime));
        var playhead = Math.Clamp(SourceTime, scope.Start, scope.End);
        var current = ExactRangeSource;
        var lower = start ? playhead : current is { } before && before.Start < playhead ? before.Start : scope.Start;
        var upper = start ? current is { } after && after.End > playhead ? after.End : scope.End : playhead;
        if (upper <= lower) return false;
        return SetExactRange(lower, upper, start ? playhead : playhead - Math.Min(1e-3, (upper - lower) / 2));
    }

    /// <summary>The words wholly inside <paramref name="range"/> in the scope, as a drag selects them, with the range kept.</summary>
    private void SelectWordsInside(TimeRange range)
    {
        int first = -1, last = -1;
        foreach (var (start, end) in TimelineScopeSpans())
            for (var index = start; index <= end; index++)
            {
                if (Words[index].Start < range.Start - 1e-6 || Words[index].End > range.End + 1e-6) continue;
                if (first < 0) first = index;
                last = index;
            }
        // ✦ Ask Claude asks about a range of at least 0.1 s (design.md §6.8).
        SetAskClaudeTimeRange((range.Start, range.End));
        SetSelectionIndices(first, last);
    }

    /// <summary>Selects words <paramref name="first"/>–<paramref name="last"/> (or nothing for -1) without moving the playhead,
    /// keeping the exact range.</summary>
    private void SetSelectionIndices(int first, int last)
    {
        var previous = (SelectionStart, SelectionEnd);
        selectionAnchor = first;
        selectionEnd = first < 0 ? -1 : last;
        TimelineRangeMessage = null;
        RewriteSelectionRevision++;
        if (CorrectionWordId is not null && previous != (SelectionStart, SelectionEnd)) EndCorrection();
        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(SelectionText));
        SelectionChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The words <paramref name="range"/> runs between: each edge snaps to the nearest word start or end in the scope (and
    /// the recording of its middle), as a drag with Snap on does; with <paramref name="overlapping"/>, only to the words the range
    /// reaches into, and null when it reaches none.</summary>
    private (int First, int Last)? SnapToScopeWords(TimeRange range, bool overlapping = false)
    {
        var region = HasSeveralRecordings ? RecordingClock?.LocalTime((range.Start + range.End) / 2)?.Key : null;
        var candidates = TimelineScopeSpans().SelectMany(span => Enumerable.Range(span.Start, span.End - span.Start + 1))
            .Where(index => region is null || RecordingOf(index)?.Key == region)
            .Where(index => !overlapping || Words[index].Start < range.End && Words[index].End > range.Start).ToArray();
        if (candidates.Length == 0) return null;
        var first = candidates.MinBy(index => Math.Abs(Words[index].Start - range.Start));
        var last = candidates.MinBy(index => Math.Abs(Words[index].End - range.End));
        if (first <= last) return (first, last);
        var middle = (range.Start + range.End) / 2;
        var nearest = candidates.MinBy(index => Math.Abs((Words[index].Start + Words[index].End) / 2 - middle));
        return (nearest, nearest);
    }

    // MARK: Readout

    /// <summary>The toolbar's range readout, "0.43 s · 12:04.10–12:04.53": its length and its In and Out in the recording's own time.</summary>
    internal string? ExactRangeReadout => ExactRangeReadoutParts is { } parts ? parts.Length + " · " + parts.Span : null;

    /// <summary>The readout's two halves: "0.43 s" and "12:04.10–12:04.53".</summary>
    internal (string Length, string Span)? ExactRangeReadoutParts => exactRange is { } range
        ? ((range.End - range.Start).ToString("0.00", CultureInfo.InvariantCulture) + (char)0xA0 + "s", RangeTime(range.Start) + "–" + RangeTime(range.End)) : null;

    /// <summary>"12:04.10", or "1:02:04.10" past an hour: minutes, seconds and hundredths.</summary>
    internal static string RangeTime(double seconds)
    {
        var hundredths = (long)Math.Round(Math.Max(0, double.IsFinite(seconds) ? seconds : 0) * 100, MidpointRounding.AwayFromZero);
        var whole = hundredths / 100; var fraction = hundredths % 100;
        var hours = whole / 3_600; var minutes = whole / 60 % 60; var rest = whole % 60;
        return hours > 0 ? string.Create(CultureInfo.InvariantCulture, $"{hours}:{minutes:00}:{rest:00}.{fraction:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{minutes}:{rest:00}.{fraction:00}");
    }

    /// <summary>What the edit bar says is selected, or how to select.</summary>
    internal string TimelineSelectionStatus
    {
        get
        {
            var words = HasSelection ? SelectionEnd - SelectionStart + 1 : 0;
            if (exactRange is not null) return words == 0 ? "Exact range" : $"Exact range, {words} {Plural(words, "word")} inside";
            if (!HasSelection) return TimelineRangeHint;
            var pauses = state?.Pauses.Count(pause => pause.AfterIndex >= SelectionStart && pause.AfterIndex < SelectionEnd) ?? 0;
            return $"{words} {Plural(words, "word")}" + (pauses == 0 ? "" : $", {pauses} {Plural(pauses, "pause")}");
        }
    }

    // MARK: Range actions (the edit bar)

    /// <summary>Whether Cut selection can run: words or pauses are selected that aren't all cut, and no exact range is set.</summary>
    internal bool TimelineCanCut => TimelineCutReason is null;

    /// <summary>Why Cut selection (Cut range while a range is set) can't run, or null: the edit bar's tooltip and help on the disabled
    /// button.</summary>
    internal string? TimelineCutReason
    {
        get
        {
            if (exactRange is not null) return TimelineCutRangeReason;
            if (!CanEditTimeline || state is not { } current) return TimelineNotReady;
            if (!HasSelection) return TimelineRangeHint;
            for (var index = SelectionStart; index <= SelectionEnd; index++) if (!current.CutWordIds.Contains(Words[index].Id)) return null;
            return current.Pauses.Any(pause => pause.AfterIndex >= SelectionStart && pause.AfterIndex < SelectionEnd && !current.CutPauseIds.Contains(pause.Id))
                ? null : TimelineAlreadyCutReason;
        }
    }

    /// <summary>Why Play range can't run, or null.</summary>
    internal string? TimelinePlayRangeReason => TimelineActionRange is null ? TimelineRangeHint : null;

    /// <summary>Where Play range seeks and stops on the preview's render <paramref name="timeline"/>, both on its edited clock: In
    /// mapped as a start and Out as an end, so a stop at a story part's end is that part's end even when the next part plays earlier
    /// source. Null when nothing of <paramref name="range"/> (project clock) plays.</summary>
    internal static (double Start, double Stop)? TimelineRangePlayback(RenderTimeline timeline, TimeRange range)
    {
        var start = timeline.MapTime(range.Start);
        var stop = timeline.MapEndTime(range.End);
        return stop > start ? (start, stop) : null;
    }

    /// <summary>Play range: from In, stopping at Out.</summary>
    internal bool PlayTimelineRange()
    {
        if (TimelineActionRange is not { } range) return false;
        EndCorrection();
        TimelineRangePlayRequested?.Invoke(this, range);
        return true;
    }

    /// <summary>Why ✦ Ask Claude can't ask about the range or words, or null.</summary>
    internal string? TimelineAskClaudeReason
    {
        get
        {
            if (!CanEditTimeline) return TimelineNotReady;
            if (!CanAskClaude) return $"Choose an AI connector in Settings › {SettingsSections.ProvidersAndKeys}.";
            if (exactRange is not null) return AskClaude.TimeRange is null ? "Mark at least 0.1 s to ask Claude." : null;
            return AskClaudeWordSelection is null ? TimelineRangeHint : null;
        }
    }

    internal bool AskClaudeOnTimelineRange() =>
        TimelineAskClaudeReason is null && (exactRange is not null ? OpenAskClaudeOnTimeRange() : OpenAskClaudeOnSelection());

    /// <summary>Why Add title can't run over the range, or null.</summary>
    internal string? TimelineAddTitleReason => !CanEditTimeline ? TimelineNotReady : TimelineActionRange is null ? TimelineRangeHint : null;

    /// <summary>Add title over the range: a title named "Title" from In to Out, in the open clip, as one "Add title" step. Returns
    /// the new title's id, or null.</summary>
    internal string? AddTimelineTitleOverRange()
    {
        if (TimelineAddTitleReason is not null || TimelineActionRange is not { } range) return null;
        var bounds = ActiveClip is null ? new TimeRange(0, ProjectClockDuration) : TimelineScopeBounds((range.Start + range.End) / 2);
        var start = Math.Clamp(range.Start, bounds.Start, bounds.End);
        var end = Math.Min(Math.Min(range.End, bounds.End), ProjectClockDuration);
        if (end <= start) return Refuse("Move the playhead inside the clip to add a title.");
        var id = ClipEffects.NextId("title", project.ClipEffects.Select(effect => effect.GetProperty("id").GetString()!).ToHashSet(StringComparer.Ordinal));
        var node = new JsonObject { ["id"] = id, ["clipId"] = ActiveClip?.Id, ["kind"] = "title", ["start"] = start, ["end"] = end, ["text"] = "Title", ["position"] = "top" };
        var entry = Element(node);
        if (!ClipEffects.IsValidEntry(entry, project.Id)) return Refuse("This range can't hold a title.");
        try
        {
            if (!ReplaceProject(ClipEffects.Adding([entry], project), "Add title")) return null;
        }
        catch (VoxClipException) { return Refuse("This range can't hold a title."); }
        Announce("Title added over the range.");
        return id;
    }

    private string? Refuse(string reason)
    {
        TimelineRangeMessage = reason;
        Announce(reason);
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        return null;
    }

    /// <summary>The item Trim item to range trims: of the visible titles, pictures, sounds and songs the range overlaps, the one it
    /// overlaps most (the upper lane on a tie), with its kind's name and its source span.</summary>
    internal (TimelineItemId Id, string Kind, TimeRange Span)? TimelineRangeTrimTarget
    {
        get
        {
            if (TimelineActionRange is not { } range || state is null) return null;
            // The edit bar asks on every redraw; the layout only changes with the project or the range.
            if (trimTargetCache is { } cached && ReferenceEquals(cached.Project, project) && cached.Range == range) return cached.Target;
            var target = FindTrimTarget(range);
            trimTargetCache = (project, range, target);
            return target;
        }
    }
    private (Project Project, TimeRange Range, (TimelineItemId Id, string Kind, TimeRange Span)? Target)? trimTargetCache;

    private (TimelineItemId Id, string Kind, TimeRange Span)? FindTrimTarget(TimeRange range)
    {
        var scope = project.Edits.ActiveClipId;
        TimelineItemLayout layout;
        try { layout = TimelineItems.Layout(project, RenderCallerInputs.PlacementPlan(project, scope), scope, TimelineAxis.Source); }
        catch (VoxClipException) { return null; }
        (TimelineItemId Id, string Kind, TimeRange Span, double Overlap)? best = null;
        foreach (var item in layout.Items)
        {
            if (!TimelineItemEditing.Editable(item) || item.Kind is "bleep" or "mute" || item.Id.Type is TimelineItemType.Clip or TimelineItemType.Part ||
                item.AxisIntervals.Count == 0) continue;
            var span = new TimeRange(item.AxisIntervals.Min(interval => interval.Start), item.AxisIntervals.Max(interval => interval.End));
            var overlap = Math.Min(span.End, range.End) - Math.Max(span.Start, range.Start);
            if (overlap <= 0 || overlap <= (best?.Overlap ?? 0)) continue;
            best = (item.Id, TimelineItemEditing.Name(item.Kind), span, overlap);
        }
        return best is { } found ? (found.Id, found.Kind, found.Span) : null;
    }

    /// <summary>Why Trim item to range can't run, or null.</summary>
    internal string? TimelineTrimToRangeReason
    {
        get
        {
            if (!CanEditTimeline) return TimelineNotReady;
            if (TimelineActionRange is not { } range) return TimelineRangeHint;
            if (TimelineRangeTrimTarget is not { } target) return "Put the range over a title, picture, sound or song to trim it.";
            if (range.Start <= target.Span.Start + 1e-6 && range.End >= target.Span.End - 1e-6)
                return $"The {target.Kind.ToLowerInvariant()} already fits inside the range.";
            return null;
        }
    }

    /// <summary>Trim item to range: the target's edges outside the range move to In and Out, as Ctrl+Shift+[ and ] move them to the
    /// playhead, in one "Trim to range" step.</summary>
    internal bool TrimTimelineItemToRange()
    {
        if (TimelineTrimToRangeReason is not null || TimelineActionRange is not { } range || TimelineRangeTrimTarget is not { } target) return false;
        var edits = new List<TimelineEdit>();
        if (range.Start > target.Span.Start + 1e-6) edits.Add(new TimelineEdit.Trim(target.Id, TimelineEdge.Start, range.Start));
        if (range.End < target.Span.End - 1e-6) edits.Add(new TimelineEdit.Trim(target.Id, TimelineEdge.End, range.End));
        var session = new TimelineEditSession(this, project.Edits.ActiveClipId);
        if (session.Preview(edits, "Trim to range") && session.Commit())
        {
            TimelineRangeMessage = null;
            Announce($"Trimmed the {target.Kind.ToLowerInvariant()} to the range.");
            return true;
        }
        if (session.Reason is { } reason) Refuse(reason);
        return false;
    }

    /// <summary>Why Make clip can't run, or null.</summary>
    internal string? TimelineMakeClipReason
    {
        get
        {
            if (!CanEditTimeline) return TimelineNotReady;
            if (exactRange is not null) return TimelineRangeClipWords is null ? "There are no words in this range to make a clip from." : null;
            return HasSelection ? null : TimelineRangeHint;
        }
    }

    /// <summary>The words a clip from the exact range runs between: each edge snaps to the nearest start or end of a word the range
    /// reaches into, never to a neighbour outside it. Null when no word in the scope reaches into the range (a pause or music only).</summary>
    internal (int First, int Last)? TimelineRangeClipWords => ExactRangeSource is { } range ? SnapToScopeWords(range, overlapping: true) : null;

    /// <summary>A1's word ticks between <paramref name="visibleStart"/> and <paramref name="visibleEnd"/> on the axis
    /// <paramref name="toAxis"/> maps to (issue #41): each word's start and end, the open scope's words only, and with
    /// <paramref name="skipCuts"/> (Edited) only the words that play. <paramref name="fromAxis"/>, when the axis runs in source
    /// order, limits the search to the visible words.</summary>
    internal (IReadOnlyList<double> Starts, IReadOnlyList<double> Ends) TimelineWordEdges(double visibleStart, double visibleEnd,
        Func<double, double> toAxis, Func<double, double>? fromAxis, bool skipCuts)
    {
        var starts = new List<double>(); var ends = new List<double>();
        if (!double.IsFinite(visibleStart) || !double.IsFinite(visibleEnd) || visibleEnd < visibleStart) return (starts, ends);
        var cuts = state?.CutWordIds;
        var lower = fromAxis?.Invoke(visibleStart) ?? double.NegativeInfinity;
        var upper = fromAxis?.Invoke(visibleEnd) ?? double.PositiveInfinity;
        foreach (var (first, last) in TimelineScopeSpans())
        {
            int low = first, high = last + 1;
            while (low < high) { var middle = (low + high) / 2; if (Words[middle].End < lower) low = middle + 1; else high = middle; }
            for (var index = low; index <= last && Words[index].Start <= upper; index++)
            {
                if (skipCuts && cuts?.Contains(Words[index].Id) == true) continue;
                var start = toAxis(Words[index].Start); var end = toAxis(Words[index].End);
                if (start >= visibleStart && start <= visibleEnd) starts.Add(start);
                if (end >= visibleStart && end <= visibleEnd) ends.Add(end);
            }
        }
        return (starts, ends);
    }
}
