using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

/// <summary>The namespace of an item's persisted identifier.</summary>
public enum TimelineItemType
{
    /// <summary>Clip effect.</summary>
    Effect,
    /// <summary>Companion picture.</summary>
    Footage,
    /// <summary>Zoom or punch-in.</summary>
    Motion,
    /// <summary>Music segment or unmaterialised bed.</summary>
    Music,
    /// <summary>A single-part clip.</summary>
    Clip,
    /// <summary>One part of a story clip.</summary>
    Part,
    /// <summary>Read-only context-demo placement.</summary>
    ContextDemo,
    /// <summary>Read-only Voice Lab replacement.</summary>
    Voice
}
/// <summary>A stable, namespaced timeline identity.</summary>
/// <param name="Type">Placement namespace.</param>
/// <param name="Value">Persisted placement identity.</param>
public readonly record struct TimelineItemId(TimelineItemType Type, string Value);
/// <summary>The eight lanes in screen order.</summary>
public enum TimelineLane
{
    /// <summary>Captions.</summary>
    CC,
    /// <summary>Titles and overlays.</summary>
    T1,
    /// <summary>B-roll and pictures.</summary>
    B1,
    /// <summary>Zoom, looks and speed.</summary>
    FX,
    /// <summary>Primary video and speech parts.</summary>
    V1,
    /// <summary>Speech audio.</summary>
    A1,
    /// <summary>Sounds and audio censors.</summary>
    S1,
    /// <summary>Music.</summary>
    M1
}
/// <summary>The feature a snap target belongs to.</summary>
public enum TimelineSnapKind
{
    /// <summary>Word start or end.</summary>
    Word,
    /// <summary>Current playhead.</summary>
    Playhead,
    /// <summary>Visible item edge.</summary>
    Item,
    /// <summary>Story-part join.</summary>
    PartSeam,
    /// <summary>In or Out of the scope.</summary>
    ScopeEdge,
    /// <summary>Volume keyframe.</summary>
    GainPoint
}
/// <summary>A point a gesture can snap to.</summary>
/// <param name="Time">Seconds on the requested axis.</param>
/// <param name="Kind">Source of the target.</param>
/// <param name="Item">Owning placement for item-specific targets.</param>
public sealed record TimelineSnapTarget(double Time, TimelineSnapKind Kind, TimelineItemId? Item);
/// <summary>Geometry of one item, without view or media dependencies.</summary>
/// <param name="Id">Stable item identity.</param>
/// <param name="Kind">Wire kind or speech/zoom kind.</param>
/// <param name="Lane">Owning lane.</param>
/// <param name="Row">Zero-based sub-row.</param>
/// <param name="PartId">Owning speech part, if any.</param>
/// <param name="SourceAnchor">The original source anchor.</param>
/// <param name="EditedIntervals">What plays on the edited clock.</param>
/// <param name="AxisIntervals">Intervals to draw on the requested axis.</param>
/// <param name="Hidden">Whether nothing plays.</param>
/// <param name="Marker">Axis position of the hidden marker.</param>
/// <param name="SeamNotches">Axis positions of cuts inside the item.</param>
/// <param name="Reason">Copy explaining a hidden or shortened placement.</param>
public sealed record TimelineItem(TimelineItemId Id, string Kind, TimelineLane Lane, int Row, string? PartId,
    double SourceAnchor, IReadOnlyList<TimeRange> EditedIntervals, IReadOnlyList<TimeRange> AxisIntervals, bool Hidden,
    double? Marker, IReadOnlyList<double> SeamNotches, string? Reason);
/// <summary>The timeline projection for one scope and axis.</summary>
/// <param name="Items">Item geometry in lane order.</param>
/// <param name="RowCounts">Sub-rows per lane, at least one.</param>
/// <param name="SnapTargets">Targets sorted by time.</param>
public sealed record TimelineItemLayout(IReadOnlyList<TimelineItem> Items, IReadOnlyDictionary<TimelineLane, int> RowCounts,
    IReadOnlyList<TimelineSnapTarget> SnapTargets);

/// <summary>Lay out source-anchored items using an existing edit plan.</summary>
public static class TimelineItems
{
    /// <summary>Guide copy for a drop on cut source time.</summary>
    public const string CutDropCopy = "Lands on a cut · plays at the seam";

    /// <summary>Convert one axis position to a sample-grid source anchor.</summary>
    public static double SourceAnchor(double time, TimelineAxis axis, EditPlan plan) =>
        EditingMath.Round((axis == TimelineAxis.Edited ? plan.SourceTime(time) : time) * plan.SampleRate) / plan.SampleRate;

    /// <summary>Guide copy when the requested source position falls in a cut.</summary>
    public static string? DropHint(double time, TimelineAxis axis, EditPlan plan) =>
        axis == TimelineAxis.Source && plan.CutContaining(SourceAnchor(time, axis, plan)) is not null ? CutDropCopy : null;

    /// <summary>Project the scope's placements. Null scope selects the full take; playhead uses the requested axis.</summary>
    public static TimelineItemLayout Layout(Project project, EditPlan plan, string? scope, TimelineAxis axis, double? playhead = null)
    {
        var clock = new TimelineClock(project, plan, scope);
        var entries = TimelineEntry.Collect(project, clock);
        var targets = new List<TimelineSnapTarget>();
        void Target(double time, TimelineSnapKind kind, TimelineItemId? item = null) => targets.Add(new(clock.Round(time), kind, item));
        if (playhead is { } head && double.IsFinite(head)) Target(head, TimelineSnapKind.Playhead);
        if (axis == TimelineAxis.Edited)
        {
            Target(0, TimelineSnapKind.ScopeEdge); Target(plan.Duration, TimelineSnapKind.ScopeEdge);
            foreach (var seam in plan.PartSeams) Target(seam / plan.SampleRate, TimelineSnapKind.PartSeam);
        }
        else
        {
            for (var index = 0; index < clock.Parts.Length; index++)
            {
                var part = clock.Parts[index].Range;
                Target(part.Start, index == 0 ? TimelineSnapKind.ScopeEdge : TimelineSnapKind.PartSeam);
                Target(part.End, index == clock.Parts.Length - 1 ? TimelineSnapKind.ScopeEdge : TimelineSnapKind.PartSeam);
            }
        }
        foreach (var word in clock.Words)
        {
            var span = clock.Range(word.Start, word.End);
            if (axis == TimelineAxis.Edited)
                foreach (var interval in clock.Projected(span))
                {
                    Target(interval.Edited.Start, TimelineSnapKind.Word); Target(interval.Edited.End, TimelineSnapKind.Word);
                }
            else if (clock.Parts.Any(part => StoryClips.Overlaps(part.Range, span)))
            {
                Target(span.Start, TimelineSnapKind.Word); Target(span.End, TimelineSnapKind.Word);
            }
        }
        var items = new List<TimelineItem>();
        var counts = new Dictionary<TimelineLane, int>();
        foreach (var lane in Enum.GetValues<TimelineLane>())
        {
            var placed = new List<(TimeRange Range, int Row)>();
            foreach (var entry in entries.Where(entry => entry.Lane == lane))
            {
                var item = clock.Display(entry, axis);
                var span = item.AxisIntervals.Count == 0 ? new(item.Marker ?? 0, item.Marker ?? 0) :
                    new TimeRange(item.AxisIntervals.Min(interval => interval.Start), item.AxisIntervals.Max(interval => interval.End));
                var row = 0;
                while (placed.Any(location => location.Row == row && StoryClips.Overlaps(location.Range, span))) row++;
                placed.Add((span, row));
                items.Add(item with { Row = row });
                if (item.Hidden) continue;
                foreach (var interval in item.AxisIntervals)
                {
                    Target(interval.Start, TimelineSnapKind.Item, item.Id); Target(interval.End, TimelineSnapKind.Item, item.Id);
                }
                foreach (var point in entry.Points ?? [])
                {
                    var time = clock.Round(item.EditedIntervals[0].Start + point.T);
                    if (time <= item.EditedIntervals[^1].End)
                        Target(axis == TimelineAxis.Edited ? time : clock.SourceAt(time), TimelineSnapKind.GainPoint, item.Id);
                }
            }
            counts[lane] = placed.Count == 0 ? 1 : placed.Max(location => location.Row) + 1;
        }
        return new(items, counts, targets.Distinct().OrderBy(target => target.Time).ToArray());
    }
}

internal sealed record TimelineEntry(TimelineItemId Id, string Kind, TimelineLane Lane, TimeRange Span,
    bool OwnLength = false, bool Scoped = true, double? Offset = null, double? Available = null, IReadOnlyList<GainPoint>? Points = null)
{
    internal string Name => Kind switch
    {
        "lowerThird" => "lower third", "sticker" => "emoji", "motionTemplate" => "template", "bRoll" => "B-roll",
        "videoStack" => "video stack", "colourLook" => "look", "speedForPart" => "speed change", _ => Kind
    };
    internal bool WordLocked => Kind is "bleep" or "mute";
    internal bool Footage => Id.Type == TimelineItemType.Footage;
    internal bool Audio => Kind is "sound" or "music";

    internal static TimelineEntry[] Collect(Project project, TimelineClock clock)
    {
        var scope = clock.Scope;
        var result = new List<TimelineEntry>();
        foreach (var effect in ClipEffects.Rendered(project, scope))
        {
            var lane = effect.Kind switch
            {
                "sound" or "bleep" or "mute" => TimelineLane.S1, "illustration" => TimelineLane.B1,
                "colourLook" or "speedForPart" or "freeze" => TimelineLane.FX, _ => TimelineLane.T1
            };
            result.Add(new(new(TimelineItemType.Effect, effect.Id), effect.Kind, lane, new(effect.Start, effect.End),
                effect.Kind == "sound", effect.ClipId == scope && effect.Kind is not ("bleep" or "mute"),
                effect.MediaOffsetSeconds, effect.Sound?.DurationSeconds, effect.GainPoints));
        }
        foreach (var footage in (project.Media.Footage ?? []).Where(value => value.ClipId == scope))
        {
            var duration = project.Media.AdditionalSources?.FirstOrDefault(source => source.Video is not null && source.FootageKey == footage.Footage.SourceKey)?.DurationSeconds;
            result.Add(new(new(TimelineItemType.Footage, footage.Id), footage.Kind, TimelineLane.B1, new(footage.Start, footage.End),
                Offset: footage.Footage.Start, Available: duration));
        }
        foreach (var cue in project.MotionCues.Where(cue => cue.ClipID == scope))
            result.Add(new(new(TimelineItemType.Motion, cue.Id), "zoom", TimelineLane.FX, new(cue.SourceStart, cue.SourceEnd)));
        if (project.Music.FirstOrDefault(track => track.ClipId == scope) is { } track)
        {
            var segments = track.Segments ?? (clock.Bed(track) is { } bed ? [bed] : []);
            foreach (var segment in segments)
                result.Add(new(new(TimelineItemType.Music, segment.Id), "music", TimelineLane.M1,
                    new(segment.AnchorSeconds, segment.AnchorSeconds + segment.LengthSeconds), true, Offset: segment.SongFromSeconds,
                    Available: track.Asset.DurationSeconds, Points: segment.GainPoints));
        }
        if (clock.Clip is { } clip)
            foreach (var part in clock.Parts)
                result.Add(new(new(clip.Parts is null ? TimelineItemType.Clip : TimelineItemType.Part, part.Id ?? clip.Id),
                    clip.Parts is null ? "clip" : "part", TimelineLane.V1, part.Range));
        if (scope is null)
            foreach (var placement in project.ContextDemo?.Placements ?? [])
            {
                var start = clock.SourceAt(placement.EditedStartSeconds);
                result.Add(new(new(TimelineItemType.ContextDemo, placement.Id), "contextDemo", TimelineLane.B1,
                    new(start, start + (placement.Source.End - placement.Source.Start)), true));
            }
        foreach (var segment in project.VoiceLab.Segments.Where(segment => segment.Enabled))
            if (clock.Parts.Any(part => StoryClips.Overlaps(part.Range, new(segment.Replace.Start, segment.Replace.End))))
                result.Add(new(new(TimelineItemType.Voice, segment.Id), "voice", TimelineLane.A1,
                    new(segment.Replace.Start, segment.Replace.End)));
        return result.ToArray();
    }
}

internal sealed class TimelineClock
{
    internal readonly record struct Part(string? Id, TimeRange Range);
    internal readonly record struct Piece(TimeRange Source, TimeRange Edited);
    internal EditPlan Plan { get; }
    internal string? Scope { get; }
    internal ClipRange? Clip { get; }
    internal IReadOnlyList<TimedWord> Words { get; }
    private HashSet<string> CutWordIds { get; }
    internal Part[] Parts { get; }
    private Piece[] Pieces { get; }
    private Piece[] SourcePieces { get; }
    private Piece[][] PartPieces { get; }

    internal TimelineClock(Project project, EditPlan plan, string? scope)
    {
        Plan = plan; Scope = scope;
        Clip = project.Edits.Clips.FirstOrDefault(clip => clip.Id == scope);
        Words = ProjectClock.Build(project).Words;
        CutWordIds = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var duration = plan.TotalSamples / plan.SampleRate;
        var bounds = Clip is { } clip ? StoryClips.Times(clip, Words) : [new TimeRange(0, duration)];
        Parts = bounds.Select((bound, index) => new Part(Clip?.PlayParts[index].Id,
            new(Round(bound.Start), Math.Min(duration, Round(bound.End))))).ToArray();
        long output = 0;
        Pieces = plan.Kept.Select(kept =>
        {
            var start = output;
            output += kept.EndSample - kept.StartSample;
            return new Piece(new(kept.StartSample / plan.SampleRate, kept.EndSample / plan.SampleRate),
                new(start / plan.SampleRate, output / plan.SampleRate));
        }).ToArray();
        SourcePieces = Pieces.OrderBy(piece => piece.Source.Start).ToArray();
        PartPieces = Parts.Select(part => Pieces.Where(piece => StoryClips.Overlaps(piece.Source, part.Range)).ToArray()).ToArray();
    }

    internal double Round(double seconds) => EditingMath.Round(seconds * Plan.SampleRate) / Plan.SampleRate;
    internal TimeRange Range(double start, double end) => new(Round(start), Round(end));
    internal MusicSegment? Bed(ProjectMusic track) => Pieces.Length == 0 ? null : new(track.Id, Pieces[0].Source.Start,
        Plan.Duration, Round(track.StartOffsetSeconds), true, 0, Round(track.FadeInSeconds), Round(track.FadeOutSeconds));

    internal int? PartAt(double source)
    {
        var index = Array.FindIndex(Parts, part => part.Range.Start <= source && source < part.Range.End);
        return index < 0 ? null : index;
    }

    internal double EditedAt(double source, int? part)
    {
        if (part is not { } index || Parts.Length <= 1) return Plan.MapTime(source);
        var owned = PartPieces[index];
        for (var previous = owned.Length - 1; previous >= 0; previous--)
            if (owned[previous].Source.Start <= source)
                return Math.Min(owned[previous].Edited.End, Round(owned[previous].Edited.Start + source - owned[previous].Source.Start));
        if (owned.Length > 0) return owned[0].Edited.Start;
        for (var earlier = index - 1; earlier >= 0; earlier--)
            if (PartPieces[earlier].Length > 0) return PartPieces[earlier][^1].Edited.End;
        return 0;
    }

    internal double SourceAt(double edited) => edited >= Plan.Duration && Pieces.Length > 0 ? Pieces[^1].Source.End : Plan.SourceTime(edited);

    internal IEnumerable<Piece> Projected(TimeRange span)
    {
        if (span.Start >= span.End) return [];
        var lower = 0;
        var upper = SourcePieces.Length;
        while (lower < upper)
        {
            var middle = lower + (upper - lower) / 2;
            if (SourcePieces[middle].Source.End <= span.Start) lower = middle + 1; else upper = middle;
        }
        var projected = new List<Piece>();
        for (var index = lower; index < SourcePieces.Length && SourcePieces[index].Source.Start < span.End; index++)
        {
            var piece = SourcePieces[index];
            var start = Math.Max(piece.Source.Start, span.Start);
            var end = Math.Min(piece.Source.End, span.End);
            projected.Add(new(new(start, end), Range(piece.Edited.Start + start - piece.Source.Start, piece.Edited.Start + end - piece.Source.Start)));
        }
        return Parts.Length > 1 && projected.Count > 1 ? projected.OrderBy(piece => piece.Edited.Start) : projected;
    }

    private bool AllCoveredWordsCut(TimeRange span)
    {
        if (CutWordIds.Count == 0) return false;
        var covered = false;
        foreach (var word in Words.TakeWhile(word => word.Start < span.End).Where(word => word.End > span.Start))
        {
            if (!CutWordIds.Contains(word.Id)) return false;
            covered = true;
        }
        return covered;
    }

    internal TimelineItem Display(TimelineEntry entry, TimelineAxis axis)
    {
        var span = Range(entry.Span.Start, entry.Span.End);
        var owner = PartAt(span.Start);
        var anchor = EditedAt(span.Start, owner);
        var intervals = new List<TimeRange>();
        var visible = new List<TimeRange>();
        var notches = new List<double>();
        string? reason = null;
        if (entry.OwnLength)
        {
            var end = Math.Min(Plan.Duration, Round(anchor + span.End - span.Start));
            if (owner is not null && anchor < end)
            {
                intervals.Add(new(anchor, end));
                if (axis == TimelineAxis.Source)
                {
                    foreach (var piece in Pieces.Where(piece => StoryClips.Overlaps(piece.Edited, intervals[0])))
                        visible.Add(Range(piece.Source.Start + Math.Max(anchor, piece.Edited.Start) - piece.Edited.Start,
                            piece.Source.Start + Math.Min(end, piece.Edited.End) - piece.Edited.Start));
                    if (visible.Count > 0 && span.Start < visible[0].Start) visible[0] = visible[0] with { Start = span.Start };
                }
            }
        }
        else if ((!entry.Scoped || (owner is { } part && span.End <= Parts[part].Range.End)) &&
                 (entry.Lane == TimelineLane.V1 || !AllCoveredWordsCut(span)))
        {
            var remaining = entry.Footage && entry.Kind != "screenshot" && entry.Available is { } available
                ? Math.Max(0, Round(available - (entry.Offset ?? 0))) : double.PositiveInfinity;
            foreach (var interval in Projected(span))
            {
                var length = Round(interval.Edited.End - interval.Edited.Start);
                var shown = Math.Min(remaining, length);
                if (shown < length) reason = "The recording ends here.";
                if (shown <= 0) continue;
                if (intervals.Count > 0) notches.Add(axis == TimelineAxis.Edited ? interval.Edited.Start : interval.Source.Start);
                intervals.Add(Range(interval.Edited.Start, interval.Edited.Start + shown));
                visible.Add(Range(interval.Source.Start, interval.Source.Start + shown));
                remaining -= shown;
            }
        }
        var hidden = intervals.Count == 0;
        if (hidden && reason is null)
            reason = owner is null || (entry.Scoped && !entry.OwnLength && span.End > Parts[owner.Value].Range.End)
                ? "Hidden · outside this clip" : "Hidden · its words are cut";
        return new(entry.Id, entry.Kind, entry.Lane, 0, owner is { } index ? Parts[index].Id : null, span.Start, intervals,
            axis == TimelineAxis.Edited ? intervals : visible, hidden, hidden ? axis == TimelineAxis.Edited ? anchor : span.Start : null, notches, reason);
    }
}
