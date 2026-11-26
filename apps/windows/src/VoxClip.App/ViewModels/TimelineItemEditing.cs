using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Music;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal enum TimelineItemGesture { Move, Duplicate, Start, End, FadeIn, FadeOut, Slip, Volume, Keyframe, Dip }

internal sealed record TimelineItemDetails(string Title, double Offset = 0, double Available = 0,
    double FadeIn = 0, double FadeOut = 0, double Gain = 0, double TrackGain = 0, bool Loop = false,
    IReadOnlyList<GainPoint>? Points = null, ProjectMusic? Track = null)
{
    internal double Level => Gain + TrackGain;
    internal double Envelope(double time)
    {
        var points = Points ?? [];
        if (points.Count == 0) return 0;
        for (var index = 1; index < points.Count; index++)
        {
            var previous = points[index - 1]; var next = points[index];
            if (time <= next.T) return previous.Db + (next.Db - previous.Db) * Math.Clamp((time - previous.T) / (next.T - previous.T), 0, 1);
        }
        return points[^1].Db;
    }

    internal static TimelineItemDetails Read(Project project, string? scope, TimelineItem item)
    {
        var title = TimelineItemEditing.Name(item.Kind);
        if (item.Id.Type == TimelineItemType.Effect && ClipEffects.Rendered(project, scope).FirstOrDefault(value => value.Id == item.Id.Value) is { } effect)
            return new(effect.Text ?? title, effect.MediaOffsetSeconds ?? 0, effect.Sound?.DurationSeconds ?? 0,
                effect.FadeInSeconds ?? 0, effect.FadeOutSeconds ?? 0, effect.GainDb ?? 0, Points: effect.GainPoints);
        if (item.Id.Type == TimelineItemType.Footage && project.Media.Footage?.FirstOrDefault(value => value.Id == item.Id.Value) is { } footage)
            return new(title, footage.Footage.Start, project.Media.AdditionalSources?.FirstOrDefault(value => value.FootageKey == footage.Footage.SourceKey)?.DurationSeconds ?? 0,
                footage.FadeInSeconds ?? 0, footage.FadeOutSeconds ?? 0);
        if (item.Id.Type == TimelineItemType.Music && project.Music.FirstOrDefault(value => value.ClipId == scope) is { } track)
        {
            var segment = track.Segments?.FirstOrDefault(value => value.Id == item.Id.Value);
            return new(track.Title, segment?.SongFromSeconds ?? track.StartOffsetSeconds, track.Asset.DurationSeconds,
                segment?.FadeInSeconds ?? track.FadeInSeconds, segment?.FadeOutSeconds ?? track.FadeOutSeconds,
                segment?.GainDb ?? 0, track.GainDb, segment?.Loop ?? true, segment?.GainPoints, track);
        }
        return new(title);
    }
}

internal readonly record struct TimelineGestureEdit(IReadOnlyList<TimelineEdit> Edits, string Readout, double? Guide = null, string? Undo = null, string? Refusal = null);

internal static class TimelineItemEditing
{
    internal const string Help = "Split: B. Duplicate: Ctrl+D. Delete: Delete. Trim to playhead: Ctrl+Shift+[ or ].";
    internal static string Name(string kind) => kind switch
    {
        "lowerThird" => "Lower third", "sticker" => "Emoji", "motionTemplate" => "Template", "bRoll" => "B-roll",
        "videoStack" => "Video stack", "colourLook" => "Look", "speedForPart" => "Speed change", "contextDemo" => "Screen demo",
        "voice" => "AI voice", _ => char.ToUpperInvariant(kind[0]) + kind[1..]
    };
    internal static bool Connected(TimelineItem item) => item.Lane is not (TimelineLane.V1 or TimelineLane.A1);
    internal static bool Editable(TimelineItem item) => !item.Hidden && item.Id.Type is not (TimelineItemType.ContextDemo or TimelineItemType.Voice);
    internal static bool Audio(TimelineItem item) => item.Kind is "sound" or "music";
    internal static bool CanSlip(TimelineItem item) => Audio(item) || item.Id.Type == TimelineItemType.Footage;
    internal static bool CanFade(TimelineItem item) => item.Id.Type == TimelineItemType.Footage || Audio(item) ||
        item.Kind is "title" or "lowerThird" or "sticker" or "illustration" or "motionTemplate";
    internal static string Seconds(double value) => value.ToString("0.0", CultureInfo.InvariantCulture) + " s";
    internal static string Clock(double value)
    {
        var tenths = (long)Math.Round(Math.Abs(value) * 10, MidpointRounding.AwayFromZero);
        return FormattableString.Invariant($"{tenths / 600}:{tenths % 600 / 10:00}.{tenths % 10}");
    }
    internal static string Delta(double value) => (value < 0 ? "−" : "+") + Clock(value);
    internal static string Decibels(double value) => value.ToString("0.0", CultureInfo.InvariantCulture).Replace('-', '−') + " dB";
    internal static double Length(TimelineItem item) => item.EditedIntervals.Count == 0 ? 0 : item.EditedIntervals[^1].End - item.EditedIntervals[0].Start;
    internal static string Word(IReadOnlyList<TimedWord> words, double source) => words.Count == 0 ? "" :
        "on “" + words[TimelineLayout.WordAt(words, source)].Text.Trim() + "”";
    internal static int WordStepValue(IReadOnlyList<TimedWord> words, double source, TimelineEdge? edge) => edge == TimelineEdge.End
        ? Enumerable.Range(0, words.Count).MinBy(index => Math.Abs(words[index].End - source)) : TimelineLayout.WordAt(words, source);
    internal static string Label(TimelineItem item, TimelineItemDetails details, double start, double end, bool selected) =>
        $"{Name(item.Kind)}{(details.Title == Name(item.Kind) ? "" : ", " + details.Title)}, {Clock(start)} to {Clock(end)}" + (selected ? ", selected" : "");

    internal static TimelineGestureEdit Build(TimelineItemGesture gesture, TimelineItem item, TimelineItemDetails details,
        IReadOnlyList<TimelineItemId> selected, TimelineItemLayout layout, EditPlan plan, TimelineAxis axis,
        IReadOnlyList<TimedWord> words, double delta, double volumeDelta, double destination, double reach, bool snapping,
        GainPoint? keyframe = null, TimeRange? dipRange = null)
    {
        var id = item.Id;
        var length = Length(item);
        if (item.AxisIntervals.Count == 0) return new([], item.Reason ?? "This item is read-only.");
        var start = item.AxisIntervals[0].Start; var end = item.AxisIntervals[^1].End;
        double Source(double target) => TimelineItems.SourceAnchor(target, axis, plan);
        double? Snap(double target, bool wordsOnly) => layout.SnapTargets
            .Where(point => (!wordsOnly || point.Kind == TimelineSnapKind.Word) &&
                (point.Item is null || !selected.Contains(point.Item.Value)) && Math.Abs(point.Time - target) <= (wordsOnly ? double.PositiveInfinity : reach))
            .MinBy(point => Math.Abs(point.Time - target))?.Time;
        double Level(double db, double min, double max) => Math.Clamp(Math.Round(db * 2, MidpointRounding.AwayFromZero) / 2, min, max);
        switch (gesture)
        {
            case TimelineItemGesture.FadeIn or TimelineItemGesture.FadeOut:
                var fadeIn = gesture == TimelineItemGesture.FadeIn;
                var seconds = Math.Clamp(fadeIn ? details.FadeIn + delta : details.FadeOut - delta, 0, length);
                return new([new TimelineEdit.Fade(id, fadeIn ? TimelineEdge.Start : TimelineEdge.End, seconds)],
                    $"Fade {(fadeIn ? "in" : "out")} {Seconds(seconds)}");
            case TimelineItemGesture.Slip:
                var media = item.Kind == "music" ? "song" : "recording";
                return new([new TimelineEdit.Slip(id, delta)], $"Slip {Delta(delta)} · {media} {Clock(details.Offset)} → {Clock(details.Offset + delta)}");
            case TimelineItemGesture.Volume:
                var gain = Level(details.Gain + volumeDelta, item.Kind == "sound" ? -30 : -40, item.Kind == "sound" ? 6 : 12);
                return new([new TimelineEdit.SetGain(id, gain)], Decibels(gain + details.TrackGain));
            case TimelineItemGesture.Keyframe when keyframe is { } point:
                var raw = Math.Clamp(destination, start, end);
                var guide = snapping ? Snap(raw, false) : null;
                var db = Level(point.Db + volumeDelta, -60, 12);
                return new([new TimelineEdit.MoveGainPoint(id, point.T, Source(Math.Clamp(guide ?? raw, start, end)), db)],
                    Decibels(details.Level + db), guide);
            case TimelineItemGesture.Dip when dipRange is { } range:
                var ramp = Math.Min(.05, (range.End - range.Start) / 3);
                var depth = Level(volumeDelta, -60, 0);
                var readout = $"{Clock(range.Start)}–{Clock(range.End)} · {Decibels(depth)}";
                if (ramp * plan.SampleRate < 2) return new([], readout, Refusal: "Select a longer range inside the item.");
                if (depth == 0) return new([], readout);
                var editedStart = item.EditedIntervals[0].Start;
                double Local(double at) => (axis == TimelineAxis.Edited ? at : plan.MapTime(at)) - editedStart;
                var removed = (details.Points ?? []).Where(point => point.T >= Local(range.Start) && point.T <= Local(range.End)).ToArray();
                if ((details.Points?.Count ?? 0) - removed.Length + 4 > ItemShape.MaximumGainPoints)
                    return new([], readout, Refusal: "An item can have up to 64 volume keyframes.");
                double[] positions = [range.Start, range.Start + ramp, range.End - ramp, range.End];
                return new([.. removed.Select(point => new TimelineEdit.RemoveGainPoint(id, point.T)), .. positions.Select((at, index) =>
                    new TimelineEdit.AddGainPoint(id, Source(at), Level(details.Envelope(Local(at)) + (index is 1 or 2 ? depth : 0), -60, 12)))],
                    readout, Undo: "Dip volume");
        }

        var trimming = gesture is TimelineItemGesture.Start or TimelineItemGesture.End;
        var leading = gesture == TimelineItemGesture.Start;
        var origin = gesture == TimelineItemGesture.End ? end : start;
        var target = origin + delta;
        var speech = item.Lane == TimelineLane.V1;
        var locked = item.Kind is "bleep" or "mute";
        var snap = !speech && (locked || snapping) ? Snap(target, locked) : null;
        var shift = (snap ?? target) - origin;
        var source = Source(speech && !trimming ? destination : snap ?? target);
        if (trimming)
        {
            if (!leading && axis == TimelineAxis.Edited && (snap ?? target) > 0)
                source = Source((snap ?? target) - 1 / plan.SampleRate) + 1 / plan.SampleRate;
            var nextLength = Math.Max(0, length + (leading ? -shift : shift));
            var readout = $"{(leading ? "In" : "Out")} {Delta(shift)} · {Seconds(nextLength)}";
            if (!leading && details.Loop && details.Available > 0 && nextLength > details.Available - details.Offset)
            {
                var loops = (int)Math.Ceiling((nextLength - (details.Available - details.Offset)) / details.Available);
                readout = $"∞ {loops} {(loops == 1 ? "loop" : "loops")} · {Seconds(nextLength)}";
            }
            return new([new TimelineEdit.Trim(id, leading ? TimelineEdge.Start : TimelineEdge.End, source)], readout, snap);
        }
        var word = Word(words, source);
        var hint = TimelineItems.DropHint(snap ?? target, axis, plan);
        return new([gesture == TimelineItemGesture.Duplicate ? new TimelineEdit.Duplicate(selected, source) : new TimelineEdit.Move(selected, source)],
            Delta(shift) + (word.Length == 0 ? "" : " · " + word) + (hint is null ? "" : " · " + hint), snap);
    }
}

internal enum TimelineShortcut { None, Select, Next, Previous, EarlierFrame, LaterFrame, EarlierWord, LaterWord,
    TrimStart, TrimEnd, Split, SplitAll, Duplicate, Delete, VolumeUp, VolumeDown, Snapping, ZoomIn, ZoomOut, Fit, Escape }

internal static class TimelineKeys
{
    internal static TimelineShortcut Resolve(int key, bool control, bool shift, bool alt)
    {
        if (alt) return TimelineShortcut.None;
        return (key, control, shift) switch
        {
            (13, false, false) => TimelineShortcut.Select,
            (9, false, false) => TimelineShortcut.Next,
            (9, false, true) => TimelineShortcut.Previous,
            (188, false, false) => TimelineShortcut.EarlierFrame,
            (190, false, false) => TimelineShortcut.LaterFrame,
            (188, false, true) => TimelineShortcut.EarlierWord,
            (190, false, true) => TimelineShortcut.LaterWord,
            (219, true, true) => TimelineShortcut.TrimStart,
            (221, true, true) => TimelineShortcut.TrimEnd,
            ('B', false, false) => TimelineShortcut.Split,
            ('B', true, true) => TimelineShortcut.SplitAll,
            ('D', true, false) => TimelineShortcut.Duplicate,
            (8 or 46, false, false) => TimelineShortcut.Delete,
            (187, true, true) => TimelineShortcut.VolumeUp,
            (189, true, true) => TimelineShortcut.VolumeDown,
            ('N', false, false) => TimelineShortcut.Snapping,
            (187, true, false) => TimelineShortcut.ZoomIn,
            (189, true, false) => TimelineShortcut.ZoomOut,
            ('Z', false, true) => TimelineShortcut.Fit,
            (27, false, false) => TimelineShortcut.Escape,
            _ => TimelineShortcut.None
        };
    }
}
