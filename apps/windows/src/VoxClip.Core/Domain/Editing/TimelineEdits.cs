using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

/// <summary>The boundary being dragged.</summary>
public enum TimelineEdge
{
    /// <summary>Leading boundary.</summary>
    Start,
    /// <summary>Trailing boundary.</summary>
    End
}
/// <summary>The unit of a keyboard nudge.</summary>
public enum TimelineNudge
{
    /// <summary>Frames of the source recording.</summary>
    Frames,
    /// <summary>Kept word starts in playback order.</summary>
    Words
}

/// <summary>A pure edit of timeline placements or speech-part boundaries.</summary>
public abstract record TimelineEdit
{
    /// <summary>Re-anchor a selection.</summary>
    /// <param name="Items">Selection, with its reference item first.</param>
    /// <param name="ToAnchor">New source anchor of the reference item.</param>
    public sealed record Move(IReadOnlyList<TimelineItemId> Items, double ToAnchor) : TimelineEdit;
    /// <summary>Step a selection by a signed count.</summary>
    /// <param name="Items">Selection, with its reference item first.</param>
    /// <param name="Unit">Step unit.</param>
    /// <param name="Count">Signed number of steps.</param>
    public sealed record Nudge(IReadOnlyList<TimelineItemId> Items, TimelineNudge Unit, int Count) : TimelineEdit;
    /// <summary>Change one boundary.</summary>
    /// <param name="Item">Placement or speech band.</param>
    /// <param name="Edge">Boundary to trim.</param>
    /// <param name="ToSource">Requested source boundary.</param>
    public sealed record Trim(TimelineItemId Item, TimelineEdge Edge, double ToSource) : TimelineEdit;
    /// <summary>Split connected items.</summary>
    /// <param name="Items">Selection, or empty for items under the playhead.</param>
    /// <param name="AtSource">Playhead in source seconds.</param>
    public sealed record Split(IReadOnlyList<TimelineItemId> Items, double AtSource) : TimelineEdit;
    /// <summary>Split speech as well as connected items.</summary>
    /// <param name="AtSource">Playhead in source seconds.</param>
    public sealed record SplitAll(double AtSource) : TimelineEdit;
    /// <summary>Set an entrance or exit fade.</summary>
    /// <param name="Item">Placement to shape.</param>
    /// <param name="Edge">Boundary to shape.</param>
    /// <param name="Seconds">Fade duration.</param>
    public sealed record Fade(TimelineItemId Item, TimelineEdge Edge, double Seconds) : TimelineEdit;
    /// <summary>Set an audio placement's level.</summary>
    /// <param name="Item">Sound or music segment.</param>
    /// <param name="Db">Level in dB, relative to the track for music.</param>
    public sealed record SetGain(TimelineItemId Item, double Db) : TimelineEdit;
    /// <summary>Set the music track's level, leaving segment offsets unchanged.</summary>
    public sealed record SetTrackGain(string Track, double Db) : TimelineEdit;
    /// <summary>Dip an item's envelope over a range in source seconds.</summary>
    public sealed record DipGain(TimelineItemId Item, double FromSource, double ToSource, double ByDb) : TimelineEdit;
    /// <summary>Insert a point on the item's gain envelope.</summary>
    /// <param name="Item">Sound or music segment.</param>
    /// <param name="AtSource">Point position in source seconds.</param>
    /// <param name="Db">Relative gain in dB.</param>
    public sealed record AddGainPoint(TimelineItemId Item, double AtSource, double Db) : TimelineEdit;
    /// <summary>Change a gain point's position and level.</summary>
    /// <param name="Item">Sound or music segment.</param>
    /// <param name="From">Existing point's item-local time.</param>
    /// <param name="ToSource">Requested position in source seconds.</param>
    /// <param name="Db">Relative gain in dB.</param>
    public sealed record MoveGainPoint(TimelineItemId Item, double From, double ToSource, double Db) : TimelineEdit;
    /// <summary>Remove an envelope point.</summary>
    /// <param name="Item">Sound or music segment.</param>
    /// <param name="At">Existing point's item-local time.</param>
    public sealed record RemoveGainPoint(TimelineItemId Item, double At) : TimelineEdit;
    /// <summary>Slide the media under a placement without moving it.</summary>
    /// <param name="Item">Sound, music segment or companion footage.</param>
    /// <param name="BySeconds">Signed change to the media offset.</param>
    public sealed record Slip(TimelineItemId Item, double BySeconds) : TimelineEdit;
    /// <summary>Set whether a music segment repeats its track.</summary>
    /// <param name="Item">Music segment.</param>
    /// <param name="Enabled">Whether to loop.</param>
    public sealed record SetLoop(TimelineItemId Item, bool Enabled) : TimelineEdit;
    /// <summary>Set a track's automatic ducking depth.</summary>
    /// <param name="Track">Track identity, not segment identity.</param>
    /// <param name="Db">Ducking depth in dB; zero switches it off.</param>
    public sealed record SetDuck(string Track, double Db) : TimelineEdit;
    /// <summary>Copy placements without copying their assets.</summary>
    /// <param name="Items">Selection, with its reference item first.</param>
    /// <param name="ToAnchor">New reference source anchor; null duplicates in place or after overlapping footage.</param>
    public sealed record Duplicate(IReadOnlyList<TimelineItemId> Items, double? ToAnchor = null) : TimelineEdit;
    /// <summary>Remove placements without deleting their assets.</summary>
    /// <param name="Items">Selection to remove.</param>
    public sealed record Delete(IReadOnlyList<TimelineItemId> Items) : TimelineEdit;
}

/// <summary>One atomic timeline edit or an inline refusal.</summary>
public abstract record TimelineEditResult
{
    /// <summary>An accepted edit.</summary>
    /// <param name="Project">Resulting snapshot, with no I/O performed.</param>
    /// <param name="UndoName">The name to use if the snapshot changed.</param>
    public sealed record Applied(Project Project, string UndoName) : TimelineEditResult;
    /// <summary>An unchanged project with a reason.</summary>
    /// <param name="Refusal">Why the edit did not apply.</param>
    public sealed record Refused(TimelineEditRefusal Refusal) : TimelineEditResult;
}

/// <summary>The reason a timeline edit did not apply.</summary>
/// <param name="Copy">Text to show in the item bar.</param>
public sealed record TimelineEditRefusal(string Copy);

/// <summary>The media-free timeline reducer.</summary>
public static class TimelineEdits
{
    /// <summary>Apply one edit to a snapshot. Null scope selects the full take.</summary>
    public static TimelineEditResult Apply(TimelineEdit edit, Project project, EditPlan plan, string? scope)
    {
        if (!double.IsFinite(plan.SampleRate) || plan.SampleRate <= 0)
            return new TimelineEditResult.Refused(new("The timeline is not ready."));
        try
        {
            var reducer = new Reducer(project, plan, scope);
            var name = reducer.Apply(edit);
            var result = reducer.Project;
            if (result != project)
                result = (result.SchemaVersion < 4 ? ContextDemoProject.UpgradeToV4(result) : result) with { SchemaVersion = Math.Max(result.SchemaVersion, TimelineEditFields.Version) };
            return new TimelineEditResult.Applied(result, name);
        }
        catch (Refusal refusal) { return new TimelineEditResult.Refused(new(refusal.Message)); }
        catch (VoxClipException) { return new TimelineEditResult.Refused(new(Invalid)); }
    }

    private const string InsidePart = "Place it inside one part.";
    private const string WholeWords = "A bleep covers whole words. Trim it to fewer words instead.";
    private const string TooShort = "Too short to split here.";
    private const string NoItem = "Select an item on this timeline.";
    private const string InvalidTime = "Enter a valid time.";
    private const string ReadOnly = "This item is read-only.";
    private const string Invalid = "This edit would make the item invalid.";
    private sealed class Refusal(string copy) : Exception(copy);

    private sealed class Reducer
    {
        internal Project Project { get; private set; }
        private readonly TimelineClock clock;
        private readonly TimelineEntry[] entries;

        internal Reducer(Project project, EditPlan plan, string? scope)
        {
            Project = project;
            clock = new(project, plan, scope);
            entries = TimelineEntry.Collect(project, clock);
        }

        internal string Apply(TimelineEdit edit)
        {
            if (clock.Scope is not null && clock.Clip is null) throw new Refusal(NoItem);
            switch (edit)
            {
                case TimelineEdit.Move move: return Move(Select(move.Items), Time(move.ToAnchor), "Move");
                case TimelineEdit.Nudge nudge: return Nudge(nudge);
                case TimelineEdit.Duplicate duplicate:
                    return Move(Select(duplicate.Items), duplicate.ToAnchor is { } anchor ? Time(anchor) : null, "Duplicate", true);
                case TimelineEdit.Delete delete:
                {
                    var selected = Select(delete.Items);
                    foreach (var item in selected) Delete(item);
                    return Name("Delete", selected);
                }
                case TimelineEdit.Trim trim:
                {
                    var item = Entry(trim.Item);
                    var source = Time(trim.ToSource);
                    if (item.Lane == TimelineLane.V1) return TrimSpeech(item, trim.Edge, source);
                    Trim(item, trim.Edge, source);
                    return Name("Trim", [item]);
                }
                case TimelineEdit.Split split:
                {
                    var source = Time(split.AtSource);
                    var selected = split.Items.Count == 0 ? UnderPlayhead(source, false) : Select(split.Items);
                    if (selected.Length == 0) throw new Refusal(NoItem);
                    foreach (var item in selected) Split(item, source);
                    return Name("Split", selected);
                }
                case TimelineEdit.SplitAll split:
                {
                    var source = Time(split.AtSource);
                    if (clock.Scope is null) return SplitFullTake(source);
                    var (clip, leftEnd, rightStart) = SplitSpeech(source);
                    CheckSpeech(clip);
                    var before = Project;
                    var crossing = UnderPlayhead(rightStart, true);
                    foreach (var item in crossing)
                    {
                        if (item.OwnLength) Split(item, rightStart);
                        else if (item.Span.Start < leftEnd) Split(item, rightStart, leftEnd);
                        else Trim(item, TimelineEdge.Start, rightStart);
                    }
                    if (leftEnd < rightStart)
                        foreach (var item in UnderPlayhead(leftEnd, true).Where(item => !item.OwnLength && !crossing.Any(other => other.Id == item.Id)))
                            Trim(item, TimelineEdge.End, leftEnd);
                    ReplaceSpeech(clip, before);
                    return "Split all";
                }
                case TimelineEdit.Fade fade:
                {
                    var item = Entry(fade.Item);
                    RequireEditable(item);
                    var maximum = item.Kind == "music" ? 10 : item.Footage ? 2 : 5;
                    if (item.Id.Type is not (TimelineItemType.Footage or TimelineItemType.Music) &&
                        (item.Id.Type != TimelineItemType.Effect || !AllowsFades(item.Kind))) throw Unsupported("fade", item);
                    var draft = new Draft(item, clock);
                    var seconds = Math.Clamp(Time(fade.Seconds), 0, maximum);
                    if (fade.Edge == TimelineEdge.Start) draft.FadeIn = seconds; else draft.FadeOut = seconds;
                    Write(item, draft);
                    return Name("Fade", [item]);
                }
                case TimelineEdit.SetGain gain:
                {
                    var item = Audio(gain.Item);
                    Write(item, new Draft(item, clock) { Gain = item.Kind == "sound" ? Level(gain.Db, -30, 6) : Level(gain.Db, -40, 12) });
                    return "Change volume";
                }
                case TimelineEdit.SetTrackGain gain:
                {
                    var track = Project.Music.FirstOrDefault(track => track.Id == gain.Track && track.ClipId == clock.Scope) ?? throw new Refusal(NoItem);
                    var db = Level(gain.Db, -40, 0);
                    // Track level only: a continuous bed stays a bed that follows the clip.
                    if (db != track.GainDb) StoreTrack(track with { GainDb = db });
                    return "Change volume";
                }
                case TimelineEdit.DipGain dip:
                    DipGain(dip.Item, dip.FromSource, dip.ToSource, dip.ByDb); return "Dip volume";
                case TimelineEdit.AddGainPoint point:
                    GainPoint(point.Item, null, (point.AtSource, point.Db)); return "Add volume keyframe";
                case TimelineEdit.MoveGainPoint point:
                    GainPoint(point.Item, point.From, (point.ToSource, point.Db)); return "Move volume keyframe";
                case TimelineEdit.RemoveGainPoint point:
                    GainPoint(point.Item, point.At, null); return "Remove volume keyframe";
                case TimelineEdit.Slip slip:
                {
                    var item = Entry(slip.Item);
                    RequireEditable(item);
                    if (!item.Audio && !item.Footage) throw Unsupported("slip", item);
                    var draft = new Draft(item, clock) { Offset = Time((item.Offset ?? 0) + Time(slip.BySeconds)) };
                    CheckMedia(item, draft, Length(item, draft.Span));
                    Write(item, draft);
                    return Name("Slip", [item]);
                }
                case TimelineEdit.SetLoop loop:
                {
                    var item = Entry(loop.Item);
                    RequireEditable(item);
                    if (item.Kind != "music") throw Unsupported("loop", item);
                    var draft = new Draft(item, clock) { Loop = loop.Enabled };
                    CheckMedia(item, draft, Length(item, draft.Span));
                    Write(item, draft);
                    return "Loop music";
                }
                case TimelineEdit.SetDuck duck:
                {
                    var track = Project.Music.FirstOrDefault(track => track.Id == duck.Track && track.ClipId == clock.Scope) ?? throw new Refusal(NoItem);
                    var depth = Level(duck.Db, -24, 0);
                    StoreTrack(Materialise(track) with { DuckDb = depth, Ducking = depth != 0 });
                    return "Change ducking";
                }
                default: throw new Refusal(Invalid);
            }
        }

        private string Nudge(TimelineEdit.Nudge nudge)
        {
            var selected = Select(nudge.Items);
            var start = selected[0].Span.Start;
            if (nudge.Unit == TimelineNudge.Frames)
            {
                var fps = Project.Media.Source.Video?.FrameRate ?? 30;
                return Move(selected, Time(start + nudge.Count * clock.Round(1 / (fps > 0 ? fps : 30))), "Nudge");
            }
            var words = clock.Words.Where(word => clock.Projected(clock.Range(word.Start, word.End)).Any())
                .Select(word => (Word: word, Edited: clock.EditedAt(word.Start, clock.PartAt(word.Start))))
                .OrderBy(word => word.Edited).ToArray();
            if (words.Length == 0) throw new Refusal(NoItem);
            var position = clock.EditedAt(start, clock.PartAt(start));
            var index = nudge.Count < 0 ? Array.FindIndex(words, word => word.Edited >= position) : Array.FindLastIndex(words, word => word.Edited <= position);
            if (nudge.Count < 0 && index == -1) index = words.Length;
            var next = (long)index + nudge.Count;
            return Move(selected, Time(next >= 0 && next < words.Length ? words[next].Word.Start : start), "Nudge");
        }

        private double Time(double value) => double.IsFinite(value) && double.IsFinite(value * clock.Plan.SampleRate) ? clock.Round(value) : throw new Refusal(InvalidTime);
        private static double Level(double value, double minimum, double maximum) => double.IsFinite(value) ? Math.Clamp(value, minimum, maximum) : throw new Refusal(Invalid);
        private TimelineEntry Entry(TimelineItemId id) => entries.FirstOrDefault(entry => entry.Id == id) ?? throw new Refusal(NoItem);
        private TimelineEntry[] Select(IReadOnlyList<TimelineItemId> ids) => ids.Count > 0 ? ids.Distinct().Select(Entry).ToArray() : throw new Refusal(NoItem);
        private static string Name(string action, IReadOnlyList<TimelineEntry> items) => $"{action} {(items.Count == 1 ? items[0].Name : $"{items.Count} items")}";
        private static Refusal Unsupported(string action, TimelineEntry item) => new($"You can’t {action} this {item.Name}.");
        private static bool AllowsFades(string kind) => kind is not ("bleep" or "mute" or "speedForPart" or "freeze");

        private static void RequireEditable(TimelineEntry item)
        {
            if (item.Lane is TimelineLane.V1 or TimelineLane.A1 || item.Kind == "contextDemo") throw new Refusal(ReadOnly);
        }

        private TimelineEntry Audio(TimelineItemId id)
        {
            var item = Entry(id);
            RequireEditable(item);
            return item.Audio ? item : throw Unsupported("change the volume of", item);
        }

        private double Length(TimelineEntry item, TimeRange span) => item.Footage
            ? clock.Round(clock.Projected(span).Sum(interval => interval.Edited.End - interval.Edited.Start)) : clock.Round(span.End - span.Start);
        private double Edited(double source, TimelineEntry item) => clock.EditedAt(source, clock.PartAt(source) ?? clock.PartAt(item.Span.Start));
        private double Local(double source, TimelineEntry item) => clock.Round(Edited(source, item) - Edited(item.Span.Start, item));

        private void CheckSpan(TimelineEntry item, TimeRange span)
        {
            var minimum = item.Kind switch { "music" => 0.1 + 1 / clock.Plan.SampleRate, "sound" => 0.05, "zoom" => 0.1, _ => 1 / clock.Plan.SampleRate };
            if (clock.Round(span.End - span.Start) < minimum - 1e-9) throw new Refusal("Keep a longer item.");
            if (clock.PartAt(span.Start) is not { } part || (!item.OwnLength && span.End > clock.Parts[part].Range.End))
                throw new Refusal(clock.Clip is null ? "Place it inside the take." : InsidePart);
        }

        private void CheckMedia(TimelineEntry item, Draft draft, double length)
        {
            var duration = item.Available ?? throw new Refusal(Invalid);
            var offset = draft.Offset ?? item.Offset ?? 0;
            var loop = draft.Loop ?? Segment(item)?.Loop ?? false;
            if (offset >= 0 && offset < duration && (loop || item.Kind == "screenshot" || length <= duration - offset + 1e-9)) return;
            if (item.Kind == "music" && !loop && offset >= 0)
                throw new Refusal($"The song ends at {StoryClips.Clock(duration)}. Turn on Loop to extend it.");
            if (item.Footage) throw new Refusal("The recording ends here.");
            throw new Refusal(item.Kind == "sound" ? "Keep it inside the sound." : "Keep it inside the song.");
        }

        private string Move(TimelineEntry[] items, double? anchor, string verb, bool duplicate = false)
        {
            if (items.Length == 1 && items[0].Id.Type == TimelineItemType.Part && !duplicate && anchor is { } to)
                return MovePart(items[0].Id.Value, to);
            var delta = anchor is { } target ? clock.Round(target - clock.Round(items[0].Span.Start)) : duplicate ? DuplicateOffset(items) : 0;
            foreach (var item in items)
            {
                RequireEditable(item);
                if (delta == 0 && !duplicate) continue;
                var draft = new Draft(item, clock) { TrackShift = delta };
                draft.Span = clock.Range(draft.Span.Start + delta, draft.Span.End + delta);
                if (item.WordLocked) SnapWords(item, draft, null);
                if (item.WordLocked && !duplicate && draft.Span == item.Span) continue;
                CheckSpan(item, draft.Span);
                if (duplicate) draft.NewId = Fresh(item.Id.Value, AllIds(item.Id.Type));
                Write(item, draft);
            }
            if (items.Any(item => item.Footage)) CheckFootageOverlap();
            return Name(verb, items);
        }

        private void Trim(TimelineEntry item, TimelineEdge edge, double source)
        {
            RequireEditable(item);
            var draft = new Draft(item, clock);
            var oldLength = Length(item, draft.Span);
            var consumed = 0.0;
            if (edge == TimelineEdge.Start)
            {
                if (item.OwnLength)
                {
                    consumed = Local(source, item);
                    draft.Span = clock.Range(source, source + oldLength - consumed);
                }
                else
                {
                    draft.Span = draft.Span with { Start = source };
                    if (item.Footage)
                        consumed = Length(item, clock.Range(Math.Min(source, item.Span.Start), Math.Max(source, item.Span.Start))) * (source < item.Span.Start ? -1 : 1);
                }
            }
            else draft.Span = draft.Span with { End = item.OwnLength ? clock.Round(draft.Span.Start + Local(source, item)) : source };
            if (item.WordLocked) SnapWords(item, draft, edge);
            CheckSpan(item, draft.Span);
            if (item.Footage) CheckFootageOverlap(item, draft.Span);
            var newLength = Length(item, draft.Span);
            if (item.Audio || item.Footage)
            {
                if (edge == TimelineEdge.Start && item.Kind != "screenshot") draft.Offset = MediaOffset(item, consumed);
                CheckMedia(item, draft, newLength);
            }
            draft.Points = Envelope(item.Points, consumed, clock.Round(consumed + newLength));
            Write(item, draft);
        }

        private double MediaOffset(TimelineEntry item, double seconds)
        {
            var offset = clock.Round((item.Offset ?? 0) + seconds);
            if (Segment(item)?.Loop == true && item.Available is > 0 and var duration)
            {
                var wrapped = offset % duration;
                var grid = clock.Round(wrapped < 0 ? wrapped + duration : wrapped);
                return grid >= duration ? 0 : grid;
            }
            return offset;
        }

        private TimelineEntry[] UnderPlayhead(double source, bool skipUnsupported)
        {
            var time = clock.EditedAt(source, clock.PartAt(source));
            return entries.Where(item =>
            {
                if (item.Lane is TimelineLane.V1 or TimelineLane.A1 || item.Kind == "contextDemo" || (skipUnsupported && item.WordLocked)) return false;
                var layout = clock.Display(item, TimelineAxis.Edited);
                return layout.EditedIntervals.Count > 0 && layout.EditedIntervals[0].Start < time && time < layout.EditedIntervals[^1].End &&
                    (item.OwnLength || (item.Span.Start < source && source < item.Span.End));
            }).ToArray();
        }

        private void Split(TimelineEntry item, double source, double? leftEnd = null)
        {
            if (item.Lane == TimelineLane.V1) throw new Refusal("Use Split All to split speech.");
            RequireEditable(item);
            if (item.WordLocked) throw new Refusal(WholeWords);
            var left = new Draft(item, clock);
            var right = new Draft(item, clock);
            var full = Length(item, left.Span);
            var leftEdge = leftEnd ?? source;
            var offset = item.OwnLength ? Local(source, item) : Length(item, clock.Range(item.Span.Start, leftEdge));
            var skipped = item.OwnLength ? 0 : Length(item, clock.Range(leftEdge, source));
            var rest = clock.Round(full - offset - skipped);
            var minimum = item.Kind switch { "zoom" => 0.2, "music" => 0.1 + 1 / clock.Plan.SampleRate, "sound" => 0.05, _ => 1 / clock.Plan.SampleRate };
            if (offset < minimum - 1e-9 || rest < minimum - 1e-9 || (!item.OwnLength && !(left.Span.Start < source && source < left.Span.End)))
                throw new Refusal(TooShort);
            left.Span = left.Span with { End = item.OwnLength ? clock.Round(left.Span.Start + offset) : leftEdge };
            right.Span = right.Span with { Start = source, End = item.OwnLength ? clock.Round(source + rest) : right.Span.End };
            CheckSpan(item, left.Span); CheckSpan(item, right.Span);
            if (item.Audio || (item.Footage && item.Kind != "screenshot"))
            {
                right.Offset = MediaOffset(item, offset + skipped);
                CheckMedia(item, right, item.Footage ? Math.Min(rest, (item.Available ?? 0) - (right.Offset ?? 0)) : rest);
            }
            if (item.Audio) { left.Points = Envelope(item.Points, 0, offset); right.Points = Envelope(item.Points, offset, full); }
            if (item.Footage || item.Audio || (item.Id.Type == TimelineItemType.Effect && item.Kind != "illustration" && AllowsFades(item.Kind)))
            {
                left.FadeOut = 0; right.FadeIn = 0;
            }
            if (item.Id.Type == TimelineItemType.Motion)
            {
                var cue = Project.MotionCues.First(cue => cue.Id == item.Id.Value);
                var duration = cue.SourceEnd - cue.SourceStart;
                var lower = (leftEdge - cue.SourceStart) / duration;
                var upper = (source - cue.SourceStart) / duration;
                MotionKeyframe Frame(double progress, double time)
                {
                    var pose = MotionCueRendering.Transform(cue, time);
                    return new(progress, pose.Scale, pose.AnchorX, pose.AnchorY);
                }
                MotionKeyframe Resample(MotionKeyframe key, double from, double to) => key with { Progress = (key.Progress - from) / (to - from) };
                left.Motion = cue.Keyframes.Where(key => key.Progress < lower).Select(key => Resample(key, 0, lower)).Append(Frame(1, leftEdge)).ToArray();
                right.Motion = cue.Keyframes.Where(key => key.Progress > upper).Select(key => Resample(key, upper, 1)).Prepend(Frame(0, source)).ToArray();
            }
            right.NewId = Fresh(item.Id.Value, AllIds(item.Id.Type));
            Write(item, right); Write(item, left);
        }

        private IReadOnlyList<GainPoint>? Envelope(IReadOnlyList<GainPoint>? points, double from, double to)
        {
            if (points is not { Count: > 0 }) return points;
            double Gain(double time)
            {
                for (var index = 0; index < points.Count; index++)
                {
                    if (points[index].T <= time) continue;
                    if (index == 0) return points[0].Db;
                    var left = points[index - 1]; var right = points[index];
                    return left.Db + (right.Db - left.Db) * (time - left.T) / (right.T - left.T);
                }
                return points[^1].Db;
            }
            var result = points.Where(point => point.T >= from && point.T <= to).Select(point => new GainPoint(clock.Round(point.T - from), point.Db)).ToList();
            if (from > points[0].T && from < points[^1].T && (result.Count == 0 || result[0].T != 0)) result.Insert(0, new(0, Gain(from)));
            var end = clock.Round(to - from);
            if (to > points[0].T && to < points[^1].T && (result.Count == 0 || result[^1].T != end)) result.Add(new(end, Gain(to)));
            if (result.Count == 0) result.Add(new(0, Gain(from)));
            return result;
        }

        private void GainPoint(TimelineItemId id, double? removing, (double Source, double Db)? adding)
        {
            var item = Audio(id);
            var points = (item.Points ?? []).ToList();
            if (removing is { } time)
            {
                var original = Time(time);
                var index = points.FindIndex(point => clock.Round(point.T) == original);
                if (index < 0) throw new Refusal("Choose a volume keyframe.");
                points.RemoveAt(index);
            }
            if (adding is { } point)
            {
                var position = Local(Time(point.Source), item);
                if (position < 0 || position > Length(item, item.Span)) throw new Refusal("Place the keyframe inside the item.");
                if (points.Any(point => clock.Round(point.T) == position)) throw new Refusal("There is already a volume keyframe here.");
                if (points.Count >= ItemShape.MaximumGainPoints) throw new Refusal("An item can have up to 64 volume keyframes.");
                points.Add(new(position, Level(point.Db, -60, 12)));
                points.Sort((left, right) => left.T.CompareTo(right.T));
            }
            Write(item, new Draft(item, clock) { Points = points });
        }

        private void DipGain(TimelineItemId id, double from, double to, double db)
        {
            var item = Audio(id);
            var start = Local(Time(from), item);
            var end = Local(Time(to), item);
            var ramp = Math.Min(0.05, (end - start) / 3);
            var innerStart = clock.Round(start + ramp);
            var innerEnd = clock.Round(end - ramp);
            if (start < 0 || end > Length(item, item.Span) || start >= innerStart || innerStart >= innerEnd || innerEnd >= end)
                throw new Refusal("Select a longer range inside the item.");
            var depth = Level(db, -60, 0);
            if (depth == 0) return;
            var original = item.Points ?? [];
            var points = original.Where(point => point.T < start || point.T > end).ToList();
            if (points.Count + 4 > ItemShape.MaximumGainPoints) throw new Refusal("An item can have up to 64 volume keyframes.");
            foreach (var position in new[] { start, innerStart, innerEnd, end })
            {
                var envelope = MusicMix.EnvelopeDb(position, original);
                points.Add(new(position, Level(envelope + (position == start || position == end ? 0 : depth), -60, 12)));
            }
            points.Sort((left, right) => left.T.CompareTo(right.T));
            Write(item, new Draft(item, clock) { Points = points });
        }

        private void SnapWords(TimelineEntry item, Draft draft, TimelineEdge? edge)
        {
            var words = clock.Words;
            var first = Nearest(draft.Span.Start, 0, words.Count, index => words[index].Start);
            var count = edge is null ? Effect(item.Id.Value).GetProperty("wordIds").GetArrayLength() : 0;
            var last = count > 0 ? first + count - 1 : Nearest(draft.Span.End, 0, words.Count, index => words[index].End);
            if (first is not { } firstIndex || last is not { } lastIndex || lastIndex < firstIndex || lastIndex >= words.Count || lastIndex - firstIndex >= 200)
                throw new Refusal(WholeWords);
            draft.Span = clock.Range(words[firstIndex].Start, words[lastIndex].End);
            draft.Words = words.Skip(firstIndex).Take(lastIndex - firstIndex + 1).Select(word => word.Id).ToArray();
        }

        private int? Nearest(double source, int start, int end, Func<int, double> edge) => end <= start ? null :
            Enumerable.Range(start, end - start).MinBy(index => Math.Abs(clock.Round(edge(index)) - source));

        private double DuplicateOffset(IEnumerable<TimelineEntry> items)
        {
            var moving = items.Where(item => item.Footage).Select(item => clock.Range(item.Span.Start, item.Span.End)).ToArray();
            var occupied = (Project.Media.Footage ?? []).Where(value => value.ClipId == clock.Scope).Select(value => clock.Range(value.Start, value.End)).ToArray();
            var delta = 0.0;
            while (true)
            {
                var next = delta;
                foreach (var span in moving)
                {
                    var candidate = clock.Range(span.Start + delta, span.End + delta);
                    foreach (var other in occupied)
                        if (StoryClips.Overlaps(candidate, other)) next = Math.Max(next, clock.Round(other.End - span.Start));
                }
                if (next <= delta) return delta;
                delta = next;
            }
        }

        private void CheckFootageOverlap(TimelineEntry item, TimeRange span)
        {
            if ((Project.Media.Footage ?? []).Any(value => value.ClipId == clock.Scope && value.Id != item.Id.Value &&
                StoryClips.Overlaps(clock.Range(value.Start, value.End), span))) throw new Refusal("Place it where no other recording plays.");
        }

        private void CheckFootageOverlap()
        {
            var spans = (Project.Media.Footage ?? []).Where(value => value.ClipId == clock.Scope).OrderBy(value => value.Start).ToArray();
            if (spans.Zip(spans.Skip(1)).Any(pair => pair.First.End > pair.Second.Start))
                throw new Refusal("Place it where no other recording plays.");
        }

        private IEnumerable<string> AllIds(TimelineItemType type) => type switch
        {
            TimelineItemType.Effect => Project.ClipEffects.Select(value => value.GetProperty("id").GetString()!),
            TimelineItemType.Footage => (Project.Media.Footage ?? []).Select(value => value.Id),
            TimelineItemType.Motion => Project.MotionCues.Select(value => value.Id),
            TimelineItemType.Music => Project.Music.SelectMany(track => track.Segments?.Select(value => value.Id) ?? [track.Id]),
            TimelineItemType.Clip => Project.Edits.Clips.Select(value => value.Id),
            TimelineItemType.Part => Project.Edits.Clips.SelectMany(value => value.PlayParts.Select(part => part.Id)), _ => []
        };

        private static string Fresh(string id, IEnumerable<string> taken)
        {
            var used = taken.ToHashSet(StringComparer.Ordinal);
            for (var index = 2; ; index++)
            {
                var suffix = $"-{index}";
                var candidate = id[..Math.Min(id.Length, 64 - suffix.Length)] + suffix;
                if (!used.Contains(candidate)) return candidate;
            }
        }

        private ProjectMusic Track() => Project.Music.FirstOrDefault(track => track.ClipId == clock.Scope) ?? throw new Refusal(NoItem);
        private MusicSegment? Segment(TimelineEntry item)
        {
            if (item.Id.Type != TimelineItemType.Music) return null;
            var track = Track();
            return track.Segments is { } segments ? segments.FirstOrDefault(value => value.Id == item.Id.Value) : clock.Bed(track);
        }

        private ProjectMusic Materialise(ProjectMusic track) => track.Segments is not null ? track :
            clock.Bed(track) is { LengthSeconds: > 0.1 } bed ? track with { Segments = [bed] } : throw new Refusal(Invalid);

        private void StoreTrack(ProjectMusic track)
        {
            if (Project.Music.Any(value => value == track)) return;
            Project = Project with { Music = Project.Music.Select(value => value.Id == track.Id ? track : value).ToArray() };
        }

        private static IReadOnlyList<Value> Store<Value>(IReadOnlyList<Value> values, Value edited, Func<Value, bool> matches, bool append) =>
            append ? values.Append(edited).ToArray() : values.Select(value => matches(value) ? edited : value).ToArray();

        private JsonElement Effect(string id) => Project.ClipEffects.First(value => value.GetProperty("id").GetString() == id);

        private void Write(TimelineEntry item, Draft draft)
        {
            var original = item.Id.Value;
            var id = draft.NewId ?? original;
            var append = draft.NewId is not null;
            switch (item.Id.Type)
            {
                case TimelineItemType.Effect:
                {
                    var previous = Effect(original);
                    var node = JsonNode.Parse(previous.GetRawText())!.AsObject();
                    node["id"] = id; node["start"] = draft.Span.Start; node["end"] = draft.Span.End;
                    if (draft.FadeIn is { } fadeIn) node["fadeInSeconds"] = fadeIn;
                    if (draft.FadeOut is { } fadeOut) node["fadeOutSeconds"] = fadeOut;
                    if (draft.Gain is { } gain) node["gainDb"] = gain;
                    if (draft.Offset is { } offset) node["mediaOffsetSeconds"] = offset;
                    if (draft.Points is { } points)
                        node["gainPoints"] = new JsonArray(points.Select(point => new JsonObject { ["t"] = point.T, ["db"] = point.Db }).ToArray());
                    if (draft.Words is { } words) node["wordIds"] = new JsonArray(words.Select(word => JsonValue.Create(word)).ToArray());
                    if (draft.TrackShift != 0 && node["track"] is JsonArray samples)
                        foreach (var sample in samples) sample!["t"] = clock.Round(sample["t"]!.GetValue<double>() + draft.TrackShift);
                    using var document = JsonDocument.Parse(node.ToJsonString());
                    var value = document.RootElement.Clone();
                    if (JsonElement.DeepEquals(previous, value)) return;
                    if ((append && Project.ClipEffects.Count >= 500) || !ClipEffects.IsValidEntry(value, Project.Id)) throw new Refusal(Invalid);
                    Project = Project with { ClipEffects = Store(Project.ClipEffects, value, entry => entry.GetProperty("id").GetString() == original, append) };
                    break;
                }
                case TimelineItemType.Footage:
                {
                    var footage = Project.Media.Footage ?? [];
                    var value = footage.First(value => value.Id == original);
                    var edited = value with { Id = id, Start = draft.Span.Start, End = draft.Span.End,
                        Footage = value.Footage with { Start = draft.Offset ?? value.Footage.Start },
                        FadeInSeconds = draft.FadeIn ?? value.FadeInSeconds, FadeOutSeconds = draft.FadeOut ?? value.FadeOutSeconds };
                    if (edited == value) return;
                    Project = Project with { Media = Project.Media with { Footage = Store(footage, edited, value => value.Id == original, append) } };
                    break;
                }
                case TimelineItemType.Motion:
                {
                    var cue = Project.MotionCues.First(cue => cue.Id == original);
                    if (draft.Span.End - draft.Span.Start > 120 + 1e-9 ||
                        (append && Project.MotionCues.Count(value => value.ClipID == cue.ClipID) >= 64)) throw new Refusal(Invalid);
                    var edited = cue with { Id = id, SourceStart = draft.Span.Start, SourceEnd = draft.Span.End, Keyframes = draft.Motion ?? cue.Keyframes };
                    if (edited == cue) return;
                    Project = Project with { MotionCues = Store(Project.MotionCues, edited, value => value.Id == original, append) };
                    break;
                }
                case TimelineItemType.Music:
                {
                    var track = Materialise(Track());
                    var segments = track.Segments!;
                    var segment = segments.First(value => value.Id == original);
                    var edited = segment with { Id = id, AnchorSeconds = draft.Span.Start, LengthSeconds = Length(item, draft.Span),
                        SongFromSeconds = draft.Offset ?? segment.SongFromSeconds, Loop = draft.Loop ?? segment.Loop,
                        GainDb = draft.Gain ?? segment.GainDb, GainPoints = draft.Points,
                        FadeInSeconds = draft.FadeIn ?? segment.FadeInSeconds, FadeOutSeconds = draft.FadeOut ?? segment.FadeOutSeconds };
                    if (append && segments.Count >= 8) throw new Refusal("A track can have up to 8 segments.");
                    StoreTrack(edited == segment ? track : track with { Segments = Store(segments, edited, value => value.Id == original, append) });
                    MusicProject.Validate(Project with { SchemaVersion = TimelineEditFields.Version });
                    break;
                }
                default: throw new Refusal(ReadOnly);
            }
        }

        private void Delete(TimelineEntry item)
        {
            RequireEditable(item);
            var id = item.Id.Value;
            switch (item.Id.Type)
            {
                case TimelineItemType.Effect:
                    Project = Project with { ClipEffects = Project.ClipEffects.Where(value => value.GetProperty("id").GetString() != id).ToArray() }; break;
                case TimelineItemType.Footage:
                    var footage = (Project.Media.Footage ?? []).Where(value => value.Id != id).ToArray();
                    Project = Project with { Media = Project.Media with { Footage = footage.Length == 0 ? null : footage } }; break;
                case TimelineItemType.Motion:
                    Project = Project with { MotionCues = Project.MotionCues.Where(value => value.Id != id).ToArray() }; break;
                case TimelineItemType.Music:
                    var track = Track();
                    var rest = track.Segments?.Where(value => value.Id != id).ToArray() ?? [];
                    if (rest.Length == 0) Project = Project with { Music = Project.Music.Where(value => value.Id != track.Id).ToArray() };
                    else StoreTrack(track with { Segments = rest });
                    break;
                default: throw new Refusal(ReadOnly);
            }
        }

        private void CheckSpeech(ClipRange clip)
        {
            if (!StoryClips.Valid(clip, clock.Words)) throw new Refusal(InsidePart);
            var spans = StoryClips.Times(clip, clock.Words).Select(span => clock.Range(span.Start, span.End)).ToArray();
            if (StoryClips.LipsyncRefusal(spans, StoryClips.LipsyncWindows(Project)) is { } refusal) throw new Refusal(refusal);
        }

        private void ReplaceSpeech(ClipRange clip, Project? snapshot = null)
        {
            var index = Project.Edits.Clips.ToList().FindIndex(value => value.Id == clip.Id);
            var exists = index >= 0;
            if (exists)
            {
                var original = Project.Edits.Clips[index];
                if (original == clip || (original with { Parts = clip.Parts }) == clip && original.PlayParts.SequenceEqual(clip.PlayParts)) return;
                var before = StoryClips.Times(original, clock.Words);
                var after = StoryClips.Times(clip, clock.Words);
                var whole = Project.VoiceLab.WholeClipRevoices?.Any(record => record.ClipId == clip.Id) == true;
                var losesLipsync = StoryClips.LipsyncWindows(Project).Any(window => before.Any(span => StoryClips.Overlaps(span, window)) &&
                    !after.Any(span => StoryClips.Overlaps(span, window)));
                if (clip.Parts is not null && (whole && !before.SequenceEqual(after) || losesLipsync))
                {
                    var title = (original.Title ?? $"Clip {index + 1}") + " story";
                    var copy = clip with { Id = Fresh(clip.Id + "-story", AllIds(TimelineItemType.Clip)), Title = string.Concat(title.EnumerateRunes().Take(120)) };
                    Project = CopyScope(clip.Id, copy, snapshot ?? Project);
                    return;
                }
            }
            if (!exists && Project.Edits.Clips.Count >= 64) throw new Refusal(Invalid);
            Project = Project with { Edits = Project.Edits with { Clips = Store(Project.Edits.Clips, clip, value => value.Id == clip.Id, !exists),
                ActiveClipId = exists ? Project.Edits.ActiveClipId : clip.Id } };
        }

        private ClipRange UpdateHull(ClipRange clip, IReadOnlyList<ClipPart> parts)
        {
            var ranges = StoryClips.Indices(parts.Select(part => (part.StartWordId, part.EndWordId)), clock.Words) ?? throw new Refusal(InsidePart);
            return clip with { Parts = parts, LeadInSeconds = clip.PlayParts[0].StartWordId == parts[0].StartWordId ? clip.LeadInSeconds : null,
                StartWordId = clock.Words[ranges.Min(range => range.Start)].Id,
                EndWordId = clock.Words[ranges.Max(range => range.End)].Id };
        }

        private string TrimSpeech(TimelineEntry item, TimelineEdge edge, double source)
        {
            var clip = clock.Clip ?? throw new Refusal(NoItem);
            var index = clip.PlayParts.ToList().FindIndex(part => part.Id == item.Id.Value);
            if (index < 0 || clip.PlayPartIndices(clock.Words) is not { } ranges ||
                Nearest(source, 0, clock.Words.Count, word => edge == TimelineEdge.Start ? clock.Words[word].Start : clock.Words[word].End) is not { } word)
                throw new Refusal(NoItem);
            var range = ranges[index];
            if (edge == TimelineEdge.Start ? word > range.End : word < range.Start) throw new Refusal(InsidePart);
            var id = clock.Words[word].Id;
            if (clip.Parts is { } parts)
            {
                var changed = parts.ToArray();
                changed[index] = edge == TimelineEdge.Start ? changed[index] with { StartWordId = id } : changed[index] with { EndWordId = id };
                clip = UpdateHull(clip, changed);
            }
            else clip = edge == TimelineEdge.Start ? clip with { StartWordId = id, LeadInSeconds = clip.StartWordId == id ? clip.LeadInSeconds : null } : clip with { EndWordId = id };
            CheckSpeech(clip); ReplaceSpeech(clip);
            return clip.Parts is null ? "Trim clip" : $"Trim part {index + 1}";
        }

        private string MovePart(string id, double source)
        {
            var clip = clock.Clip;
            if (clip?.Parts is not { } original) throw new Refusal(InsidePart);
            var parts = original.ToList();
            var old = parts.FindIndex(part => part.Id == id);
            var destination = clock.PartAt(source) ?? Array.FindIndex(clock.Parts, part => part.Range.End == source);
            if (old < 0 || destination < 0) throw new Refusal(InsidePart);
            var value = parts[old];
            parts.RemoveAt(old); parts.Insert(destination, value);
            clip = UpdateHull(clip, parts);
            CheckSpeech(clip); ReplaceSpeech(clip);
            return "Move part";
        }

        private (ClipRange Clip, double LeftEnd, double RightStart) SplitSpeech(double source)
        {
            var words = clock.Words;
            var clip = clock.Clip ?? throw new Refusal(TooShort);
            if (clock.PartAt(source) is not { } index || clip.PlayPartIndices(words) is not { } ranges || ranges[index].Start >= ranges[index].End)
                throw new Refusal(TooShort);
            var range = ranges[index];
            var parts = clip.PlayParts.ToList();
            if (parts.Count >= 12 || Nearest(source, range.Start + 1, range.End + 1, word => (words[word - 1].End + words[word].Start) / 2) is not { } next)
                throw new Refusal(TooShort);
            var part = parts[index];
            parts[index] = part with { EndWordId = words[next - 1].Id };
            var partId = Fresh(part.Id, AllIds(TimelineItemType.Part).Concat(parts.Select(part => part.Id)));
            parts.Insert(index + 1, new(partId, words[next].Id, part.EndWordId, part.Reframe));
            clip = UpdateHull(clip, parts);
            var spans = StoryClips.Times(clip, words);
            var end = clock.Round(spans[index].End);
            var start = clock.Round(spans[index + 1].Start);
            if (end > start) throw new Refusal(InsidePart);
            return (clip with { Kind = clip.Kind ?? StoryClipKind.Story }, end, start);
        }

        private string SplitFullTake(double source)
        {
            if (clock.Words.Count == 0) throw new Refusal(TooShort);
            var clip = new ClipRange(Fresh("clip", AllIds(TimelineItemType.Clip)), clock.Words[0].Id, clock.Words[^1].Id, null, ClipOrigin.Manual, null, null, true);
            var reducer = new Reducer(CopyScope(null, clip, Project), clock.Plan, clip.Id);
            var name = reducer.Apply(new TimelineEdit.SplitAll(source));
            Project = reducer.Project;
            return name;
        }

        private Project CopyScope(string? source, ClipRange clip, Project basis)
        {
            if (basis.Edits.Clips.Count >= 64) throw new Refusal(Invalid);
            var effects = basis.ClipEffects.ToList();
            var effectIds = effects.Select(value => value.GetProperty("id").GetString()!).ToHashSet(StringComparer.Ordinal);
            foreach (var effect in Project.ClipEffects.Where(effect => effect.GetProperty("clipId").GetString() == source &&
                         !ClipEffects.IsCensor(effect.GetProperty("kind").GetString()!)))
            {
                var node = JsonNode.Parse(effect.GetRawText())!.AsObject();
                var id = Fresh(effect.GetProperty("id").GetString()!, effectIds);
                effectIds.Add(id);
                node["id"] = id; node["clipId"] = clip.Id;
                using var document = JsonDocument.Parse(node.ToJsonString());
                effects.Add(document.RootElement.Clone());
            }
            if (effects.Count > 500) throw new Refusal(Invalid);
            var footage = (basis.Media.Footage ?? []).ToList();
            foreach (var value in (Project.Media.Footage ?? []).Where(value => value.ClipId == source))
                footage.Add(value with { Id = Fresh(value.Id, footage.Select(value => value.Id)), ClipId = clip.Id });
            var cues = basis.MotionCues.ToList();
            foreach (var cue in Project.MotionCues.Where(cue => cue.ClipID == source))
                cues.Add(cue with { Id = Fresh(cue.Id, cues.Select(value => value.Id)), ClipID = clip.Id });
            var music = basis.Music.ToList();
            if (Project.Music.FirstOrDefault(track => track.ClipId == source) is { } track)
                music.Add(track with { Id = Fresh(track.Id, music.Select(value => value.Id)), ClipId = clip.Id });
            return basis with { Edits = basis.Edits with { Clips = basis.Edits.Clips.Append(clip).ToArray(), ActiveClipId = clip.Id },
                ClipEffects = effects, Media = basis.Media with { Footage = footage.Count == 0 ? null : footage }, MotionCues = cues, Music = music };
        }

        private sealed class Draft(TimelineEntry item, TimelineClock clock)
        {
            internal TimeRange Span { get; set; } = clock.Range(item.Span.Start, item.Span.End);
            internal double? Offset { get; set; }
            internal double? FadeIn { get; set; }
            internal double? FadeOut { get; set; }
            internal double? Gain { get; set; }
            internal bool? Loop { get; set; }
            internal IReadOnlyList<GainPoint>? Points { get; set; } = item.Points;
            internal string[]? Words { get; set; }
            internal IReadOnlyList<MotionKeyframe>? Motion { get; set; }
            internal string? NewId { get; set; }
            internal double TrackShift { get; set; }
        }
    }
}
