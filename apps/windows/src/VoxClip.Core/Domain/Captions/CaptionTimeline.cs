using System.Globalization;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Captions;

internal readonly record struct CaptionColor(byte R, byte G, byte B, byte A)
{
    internal static CaptionColor Parse(string value, CaptionStyle style)
    {
        var accent = value.StartsWith("$accent", StringComparison.Ordinal);
        var rgb = accent ? (style.Accent ?? throw new InvalidDataException("Missing caption accent.")).AsSpan(1, 6) : value.AsSpan(1, 6);
        var color = uint.Parse(rgb, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        var alpha = accent ? value.Length > 7 ? byte.Parse(value.AsSpan(8), NumberStyles.HexNumber, CultureInfo.InvariantCulture) : (byte)255
            : value.Length > 7 ? byte.Parse(value.AsSpan(7), NumberStyles.HexNumber, CultureInfo.InvariantCulture) : (byte)255;
        return new((byte)(color >> 16), (byte)(color >> 8), (byte)color, alpha);
    }
    public override string ToString() => $"#{R:X2}{G:X2}{B:X2}{A:X2}";
}

internal readonly record struct CaptionTransform(double Scale, double Alpha, double Dy)
{
    internal static CaptionTransform Identity => new(1, 1, 0);
}

/// <summary>Evaluated appearance of one word at an edited timeline time.</summary>
public readonly record struct CaptionWordFrame(int Word, string State, bool Visible, double Opacity, double Scale, double Dy,
    CaptionPaint Fill, string FillSource, double? Wipe, CaptionPaint? WipeFrom, int? VisibleClusters, CaptionWordState? Appearance);
/// <summary>Evaluated typewriter cursor geometry.</summary>
public readonly record struct CaptionCursorFrame(bool Visible, int Word, double X, double Y, double W, double H);
/// <summary>Evaluated page, word and cursor state for one frame.</summary>
public sealed record CaptionFrame(CaptionPage Page, int ActiveWord, double Progress, double PageAlpha, double PageScale,
    double PageDy, PointD Jitter, CaptionWordFrame[] Words, CaptionCursorFrame? Cursor)
{
    /// <summary>The visible page.</summary>
    public CaptionPage Page { get; internal set; } = Page;
    /// <summary>The active word's track index.</summary>
    public int ActiveWord { get; internal set; } = ActiveWord;
    /// <summary>Progress through the active word.</summary>
    public double Progress { get; internal set; } = Progress;
    /// <summary>Page opacity after entrance and exit animation.</summary>
    public double PageAlpha { get; internal set; } = PageAlpha;
    /// <summary>Page scale after entrance and exit animation.</summary>
    public double PageScale { get; internal set; } = PageScale;
    /// <summary>Vertical page displacement in export pixels.</summary>
    public double PageDy { get; internal set; } = PageDy;
    /// <summary>Deterministic page jitter in export pixels.</summary>
    public PointD Jitter { get; internal set; } = Jitter;
    /// <summary>Evaluated word states; the optional buffer may be reused on the next evaluation.</summary>
    public CaptionWordFrame[] Words { get; internal set; } = Words;
    /// <summary>Optional typewriter cursor.</summary>
    public CaptionCursorFrame? Cursor { get; internal set; } = Cursor;
}

/// <summary>Pure caption timeline lookup and frame evaluation for native renderers.</summary>
public static class CaptionEvaluator
{
    /// <summary>Find the page visible at the edited time, or null outside page intervals.</summary>
    public static CaptionPage? PageAt(CaptionTrack track, double time) => CaptionTimeline.PageAt(track, time);

    /// <summary>Evaluate a frame, optionally reusing caller-owned word and frame storage.</summary>
    public static CaptionFrame? Evaluate(CaptionTrack track, double time, bool reduceMotion = false,
        CaptionWordFrame[]? wordBuffer = null, CaptionFrame? reusable = null)
        => CaptionTimeline.Evaluate(track, time, reduceMotion, wordBuffer, reusable);
}

internal struct Mulberry32(uint seed)
{
    private uint state = seed;
    internal double Next()
    {
        unchecked
        {
            state += 0x6D2B79F5;
            var value = state;
            value = (value ^ (value >> 15)) * (value | 1);
            value = (value + ((value ^ (value >> 7)) * (value | 61))) ^ value;
            return (value ^ (value >> 14)) / 4294967296.0;
        }
    }
}

internal static class CaptionTimeline
{
    private static readonly CaptionReveal DefaultReveal = new();
    internal static double Progress(double time, double start, double duration) => duration <= 0 ? 1 : Math.Clamp((time - start) / duration, 0, 1);
    internal static CaptionTransform Entrance(CaptionAnimationSpec? animation, double time, double start, double fontSize, double target = 1, bool reduced = false)
    {
        if (animation is null || animation.Type == CaptionAnimationSpecTypeValue.None) return new(target, 1, 0);
        var eased = CaptionMath.Ease(Easing(animation.Easing), reduced ? 1 : Progress(time, start, animation.DurationSec), animation.Overshoot);
        return animation.Type switch
        {
            CaptionAnimationSpecTypeValue.Fade => new(target, Math.Clamp(eased, 0, 1), 0),
            CaptionAnimationSpecTypeValue.Pop => new(animation.FromScale + (target - animation.FromScale) * eased, 1, 0),
            CaptionAnimationSpecTypeValue.Zoom => new(animation.FromScale + (target - animation.FromScale) * eased, Math.Clamp(eased, 0, 1), 0),
            CaptionAnimationSpecTypeValue.SlideUp => new(target, Math.Clamp(eased, 0, 1), animation.FromOffsetEm * fontSize * (1 - eased)),
            _ => new(target, 1, 0)
        };
    }

    internal static CaptionTransform Exit(CaptionAnimationSpec? animation, double time, double end, double fontSize, bool reduced)
    {
        if (animation is null || reduced || animation.Type == CaptionAnimationSpecTypeValue.None) return CaptionTransform.Identity;
        var eased = CaptionMath.Ease(Easing(animation.Easing), Progress(time, end - animation.DurationSec, animation.DurationSec), animation.Overshoot);
        return animation.Type switch
        {
            CaptionAnimationSpecTypeValue.Fade => new(1, Math.Clamp(1 - eased, 0, 1), 0),
            CaptionAnimationSpecTypeValue.Pop => new(1 + (animation.FromScale - 1) * eased, 1, 0),
            CaptionAnimationSpecTypeValue.Zoom => new(1 + (animation.FromScale - 1) * eased, Math.Clamp(1 - eased, 0, 1), 0),
            CaptionAnimationSpecTypeValue.SlideUp => new(1, Math.Clamp(1 - eased, 0, 1), -animation.FromOffsetEm * fontSize * eased),
            _ => CaptionTransform.Identity
        };
    }

    internal static string Easing(CaptionAnimationSpecEasingValue easing) => easing switch
    {
        CaptionAnimationSpecEasingValue.Linear => "linear",
        CaptionAnimationSpecEasingValue.EaseInOutCubic => "easeInOutCubic",
        CaptionAnimationSpecEasingValue.EaseOutBack => "easeOutBack",
        _ => "easeOutCubic"
    };

    internal static (CaptionPaint Paint, string Source) Paint(CaptionStyle style, string state, CaptionEmphasisedWord? emphasised)
    {
        var appearance = State(style, state);
        var paint = appearance?.Fill ?? style.Fill;
        var source = appearance?.Fill is null ? "base" : state;
        if (emphasised?.PalettePaint is { } color) return (color, "emphasis");
        if (emphasised is not null && style.Emphasis?.Fill is { } emphasisPaint) return (emphasisPaint, "emphasis");
        return (paint, source);
    }

    internal static CaptionWordState? State(CaptionStyle style, string state) => state switch { "past" => style.Words?.Past, "active" => style.Words?.Active, _ => style.Words?.Future };

    internal static CaptionPage? PageAt(CaptionTrack track, double time)
    {
        var low = 0;
        var high = track.Pages.Count;
        while (low < high)
        {
            var middle = low + (high - low) / 2;
            if (track.Pages[middle].Start <= time) low = middle + 1;
            else high = middle;
        }
        return low > 0 && track.Pages[low - 1] is { } page && time >= page.Start && time < page.End ? page : null;
    }

    internal static CaptionFrame? Evaluate(CaptionTrack track, double time, bool reduced = false, CaptionWordFrame[]? buffer = null, CaptionFrame? reusable = null)
    {
        if (!double.IsFinite(time)) return null;
        var page = PageAt(track, time);
        if (page is null) return null;
        var style = track.Style;
        var activeLocal = 0;
        for (var index = 0; index < page.Words.Count; index++) if (track.Words[page.Words[index]].Start <= time) activeLocal = index;
        var active = page.Words[activeLocal];
        var entrance = Entrance(style.Animation?.PageIn, time, page.Start, page.FontPx, reduced: reduced);
        var exit = Exit(style.Animation?.PageOut, time, page.End, page.FontPx, reduced);
        var jitter = new PointD(0, 0);
        if (!reduced && style.Effects?.Jitter is { } effect)
        {
            var key = checked((long)Math.Floor(time * effect.RateHz + 1e-6));
            var random = new Mulberry32(unchecked((uint)(effect.Seed ^ key)));
            jitter = new((random.Next() * 2 - 1) * effect.AmplitudeEm * page.FontPx, (random.Next() * 2 - 1) * effect.AmplitudeEm * page.FontPx);
        }
        var reveal = style.Reveal ?? DefaultReveal;
        var frames = buffer is { } wordBuffer && wordBuffer.Length == page.Words.Count ? wordBuffer : new CaptionWordFrame[page.Words.Count];
        CaptionCursorFrame? cursor = null;
        for (var local = 0; local < page.Words.Count; local++)
        {
            var index = page.Words[local];
            var word = track.Words[index];
            var state = local < activeLocal ? "past" : local == activeLocal ? "active" : "future";
            var appearance = State(style, state);
            var wordIn = state == "future" ? CaptionTransform.Identity : Entrance(style.Animation?.WordIn, time, word.Start, page.FontPx, reduced: reduced);
            var activeIn = state == "active" ? Entrance(style.Animation?.ActiveIn, time, word.Start, page.FontPx, appearance?.Scale ?? 1, reduced) : new CaptionTransform(appearance?.Scale ?? 1, 1, 0);
            CaptionEmphasisedWord? emphasised = null;
            for (var choice = 0; choice < page.Emphasised.Count; choice++) if (page.Emphasised[choice].Word == index) { emphasised = page.Emphasised[choice]; break; }
            var paint = Paint(style, state, emphasised);
            var visible = !(reveal.Unit is CaptionRevealUnitValue.Word or CaptionRevealUnitValue.Char && state == "future");
            double? wipe = reveal.Unit == CaptionRevealUnitValue.Wipe && state == "active" ? Progress(time, word.Start, Math.Max(0.001, word.End - word.Start)) : null;
            int? clusters = null;
            if (reveal.Unit == CaptionRevealUnitValue.Char)
            {
                var duration = Math.Min(word.End - word.Start, word.Clusters / reveal.MaxCharsPerSec);
                clusters = state == "past" ? word.Clusters : 0;
                if (state == "active")
                {
                    for (var cluster = 0; cluster < word.Clusters; cluster++) if (time >= word.Start + (cluster / (double)word.Clusters) * duration) clusters = cluster + 1;
                    if (reveal.Cursor is { } options)
                    {
                        var typingEnd = word.Start + duration;
                        var shown = reduced || time < typingEnd || options.BlinkHz == 0 || Math.Floor((time - typingEnd) * options.BlinkHz * 2) % 2 == 0;
                        var rectIndex = 0;
                        while (page.WordRects[rectIndex].Word != index) rectIndex++;
                        var rect = page.WordRects[rectIndex];
                        var cap = 2 * (rect.Baseline - rect.Cy);
                        var runs = emphasised is null ? word.Runs : word.EmphasisRuns ?? word.Runs;
                        var spacing = page.LetterSpacingPx;
                        var pen = 0.0;
                        var found = false;
                        for (var runIndex = 0; runIndex < runs.Count; runIndex++)
                        {
                            var run = runs[runIndex];
                            for (var glyph = 0; glyph < run.Glyphs.Count; glyph++)
                                if (run.Clusters[glyph] < clusters)
                                {
                                    if (found) pen += spacing;
                                    pen += run.Advances[glyph] * page.FontPx / run.UnitsPerEm;
                                    found = true;
                                }
                        }
                        pen *= emphasised is null ? 1 : style.Emphasis?.Scale ?? 1;
                        cursor = new(shown, index, rect.X + pen + 0.05 * page.FontPx, rect.Baseline - cap - 0.1 * page.FontPx, options.WidthEm * page.FontPx, cap + 0.2 * page.FontPx);
                    }
                }
            }
            frames[local] = new(index, state, visible, (appearance?.Opacity ?? 1) * wordIn.Alpha * activeIn.Alpha, activeIn.Scale * wordIn.Scale,
                wordIn.Dy + activeIn.Dy, paint.Paint, paint.Source, wipe, wipe is null ? null : Paint(style, "future", emphasised).Paint, clusters, appearance);
        }
        var activeWord = track.Words[active];
        var progress = Progress(time, activeWord.Start, Math.Max(0.001, activeWord.End - activeWord.Start));
        if (reusable is null) return new(page, active, progress, entrance.Alpha * exit.Alpha, entrance.Scale * exit.Scale, entrance.Dy + exit.Dy, jitter, frames, cursor);
        reusable.Page = page; reusable.ActiveWord = active; reusable.Progress = progress;
        reusable.PageAlpha = entrance.Alpha * exit.Alpha; reusable.PageScale = entrance.Scale * exit.Scale;
        reusable.PageDy = entrance.Dy + exit.Dy; reusable.Jitter = jitter; reusable.Words = frames; reusable.Cursor = cursor;
        return reusable;
    }
}
