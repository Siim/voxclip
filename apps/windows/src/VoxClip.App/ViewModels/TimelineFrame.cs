using VoxClip.Core.Domain.Editing;

namespace VoxClip.App.ViewModels;

internal readonly record struct TimelineBadgeFrame(double Left, bool Visible);

internal sealed class TimelineFrame
{
    internal TimelineBadgeFrame[] Badges { get; } = new TimelineBadgeFrame[TimelineRetainedPool<object>.Badges];
    internal int BadgeCount { get; private set; }
    internal double Scale { get; private set; }
    internal double Translation { get; private set; }
    internal double BracketScale { get; private set; }
    internal double BracketTranslation { get; private set; }
    internal double LeftDim { get; private set; }
    internal double RightDim { get; private set; }
    internal double RightEdge { get; private set; }
    internal double StartLeft { get; private set; }
    internal double EndLeft { get; private set; }
    internal bool HasTrim { get; private set; }
    internal bool TrimEnabled { get; private set; }
    internal int First { get; private set; }
    internal int Last { get; private set; }
    internal int PointerWord { get; private set; }
    internal double PlayheadLeft { get; private set; }
    internal double HeadLeft { get; private set; }
    internal TimelineRange Playhead { get; private set; }
    internal TimelineRange Start { get; private set; }
    internal TimelineRange End { get; private set; }

    internal void Compute(TimelineViewportState viewport, TimelineScene scene, EditPlan plan, TimelineWindow rendered,
        TimelineWindow view, double width, double source, bool edited, bool trimming, bool trimStart, string? trimId,
        int first, int last, bool trimEnabled, double? pointer = null)
    {
        double Display(double time) => edited ? plan.MapTime(time) : time;
        var pointerTime = pointer is { } position ? view.Time(position, width) : source;
        if (pointer is not null && edited) pointerTime = plan.SourceTime(pointerTime);
        PointerWord = viewport.PointerWord(pointerTime);
        var pending = trimming && trimId == viewport.ActiveClip?.Id;
        First = pending ? first : viewport.First;
        Last = pending ? last : viewport.Last;
        if (pending && pointer is not null && PointerWord >= 0)
            (First, Last) = TimelineLayout.Trim(First, Last, PointerWord, viewport.WordCount, trimStart);
        var bounds = viewport.Bounds(First, Last);
        Scale = rendered.Duration / view.Duration;
        Translation = (rendered.Start - view.Start) / view.Duration * width;
        BadgeCount = scene.Clips.Count;
        for (var index = 0; index < BadgeCount; index++)
        {
            var clip = scene.Clips[index];
            var horizontal = view.X(pending && clip.Clip.Id == trimId && bounds is { } trimmed ? Display(trimmed.Start) : clip.Start, width);
            Badges[index] = new(Math.Clamp(horizontal, 0, Math.Max(0, width - 18)), horizontal >= -18 && horizontal <= width);
        }
        LeftDim = RightDim = RightEdge = 0;
        BracketScale = 1;
        BracketTranslation = 0;
        HasTrim = bounds is not null;
        TrimEnabled = trimEnabled;
        if (bounds is { } range)
        {
            var left = Math.Clamp(view.X(Display(range.Start), width), 0, width);
            var right = Math.Clamp(view.X(Display(range.End), width), 0, width);
            if (pending && scene.Layers[12].Count > 0 && scene.Layers[12][0] is { Width: > 0 } original)
            {
                var start = rendered.X(Display(range.Start), width);
                var end = rendered.X(Display(range.End), width);
                BracketScale = Math.Max(0, end - start) / original.Width;
                BracketTranslation = start - original.X * BracketScale;
            }
            LeftDim = left;
            RightDim = width - right;
            RightEdge = right;
            StartLeft = left - 12;
            EndLeft = right - 12;
        }
        Start = viewport.Trim(true, First, Last);
        End = viewport.Trim(false, First, Last);
        Playhead = viewport.Playhead(plan, view, source, edited);
        var playhead = view.X(Display(source), width);
        PlayheadLeft = Math.Clamp(playhead - 1, 0, Math.Max(0, width - 2));
        HeadLeft = Math.Clamp(playhead - 6, 0, Math.Max(0, width - 12));
    }
}
