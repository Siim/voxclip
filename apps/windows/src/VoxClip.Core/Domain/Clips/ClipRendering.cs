using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

/// <summary>How a clip's speed maps the 1× edited timeline onto the rendered one (design §6.9; Mac ClipSpeedTiming). Captions,
/// words, cuts and effects keep their 1× edited times; the renderer and the preview clock divide by the speed, and the
/// compositor multiplies a rendered frame time back before it looks anything up.</summary>
public readonly record struct ClipSpeedTiming
{
    /// <summary>An edited span with a specific playback rate.</summary>
    /// <param name="Start">Inclusive edited start.</param>
    /// <param name="End">Exclusive edited end.</param>
    /// <param name="Rate">Effective playback rate.</param>
    public readonly record struct Span(double Start, double End, double Rate);

    /// <summary>A finite positive speed; anything else plays at 1×.</summary>
    public ClipSpeedTiming(double speed, IEnumerable<Span>? overrides = null)
    {
        var baseline = double.IsFinite(speed) && speed > 0 ? speed : 1;
        Speed = baseline;
        var valid = overrides?.Where(span => double.IsFinite(span.Start) && double.IsFinite(span.End) &&
            span.End > span.Start && span.Rate is >= 0.5 and <= 2).ToArray() ?? [];
        var boundaries = valid.SelectMany(span => new[] { span.Start, span.End }).Distinct().Order().ToArray();
        Spans = boundaries.Zip(boundaries.Skip(1), (start, end) => new Span(start, end,
            valid.LastOrDefault(span => span.Start <= start && span.End >= end, new(0, 0, baseline)).Rate))
            .Where(span => span.Rate != baseline).ToArray();
    }
    /// <summary>The playback rate.</summary>
    public double Speed { get; }
    /// <summary>Map source-anchored speed spans onto the kept timeline.</summary>
    public static ClipSpeedTiming ForEffects(double speed, Func<double, double> mapTime, IEnumerable<ClipEffect> effects) =>
        ForEffects(speed, mapTime, effects, mapTime);

    /// <summary>Map speed ranges with the render's half-open end lookup.</summary>
    public static ClipSpeedTiming ForEffects(double speed, Func<double, double> mapTime, IEnumerable<ClipEffect> effects, Func<double, double> mapEndTime) =>
        new(speed, effects.Where(effect => effect.Kind == "speedForPart" && effect.Rate.HasValue)
            .Select(effect => new Span(mapTime(effect.Start), mapEndTime(effect.End), effect.Rate!.Value)));
    /// <summary>Non-overlapping deviations from the default speed.</summary>
    public IReadOnlyList<Span> Spans { get; }

    /// <summary>The consecutive constant-rate segments in an edited range.</summary>
    public IEnumerable<Span> Segments(double from, double through)
    {
        var intervals = Spans;
        var baseline = Speed;
        var boundaries = intervals.SelectMany(span => new[] { span.Start, span.End })
            .Where(time => from < time && time < through).Append(from).Append(through).Distinct().Order().ToArray();
        return boundaries.Zip(boundaries.Skip(1), (start, end) => new Span(start, end,
            intervals.FirstOrDefault(span => span.Start <= start && span.End >= end, new(0, 0, baseline)).Rate));
    }
    /// <summary>Rendered seconds for an edited time.</summary>
    public double Rendered(double edited)
    {
        var time = edited / Speed;
        foreach (var span in Spans) time += Math.Max(0, Math.Min(span.End, edited) - span.Start) * (1 / span.Rate - 1 / Speed);
        return time;
    }
    /// <summary>Edited seconds for a rendered time.</summary>
    public double Edited(double rendered)
    {
        var correction = 0.0;
        foreach (var span in Spans)
        {
            var start = span.Start / Speed + correction;
            if (rendered <= start) break;
            var length = (span.End - span.Start) / span.Rate;
            if (rendered < start + length) return span.Start + (rendered - start) * span.Rate;
            correction += length - (span.End - span.Start) / Speed;
        }
        return (rendered - correction) * Speed;
    }
    /// <summary>The rendered sample count of <paramref name="samples"/> edited samples.</summary>
    public long RenderedSamples(long samples) => Speed == 1 ? samples : (long)Math.Round(samples / Speed, MidpointRounding.AwayFromZero);
}

/// <summary>The source-audio level of a clip at a rendered time (design §6.9; Mac ClipAudioMix): volume times the linear
/// fades, or silence when the source is muted. It acts on the clip's voice before any music bed measures it.</summary>
public static class ClipAudioMix
{
    /// <summary>The volume as a linear factor; 0 when muted.</summary>
    public static double LinearGain(ProjectClipControls controls) => controls.MuteSource ? 0 : Math.Pow(10, controls.GainDb / 20);

    /// <summary>The level at <paramref name="seconds"/> of a <paramref name="duration"/>-second rendered clip.</summary>
    public static double Gain(double seconds, double duration, ProjectClipControls controls)
        => LinearGain(controls) * FadeFactor(seconds, duration, controls.FadeInSeconds, controls.FadeOutSeconds);

    /// <summary>Linear fade-in and fade-out factor (Mac MusicMix.fadeFactor).</summary>
    public static double FadeFactor(double seconds, double duration, double fadeIn, double fadeOut)
    {
        var factor = 1.0;
        if (fadeIn > 0) factor = Math.Min(factor, Math.Max(0, seconds / fadeIn));
        if (fadeOut > 0) factor = Math.Min(factor, Math.Max(0, (duration - seconds) / fadeOut));
        return Math.Min(1, factor);
    }
}

/// <summary>A look's numbers (design §6.9; Mac ClipLookRecipe): a 3 × 3 colour matrix with a bias, then an optional cubic per
/// channel (a0 + a1·x + a2·x² + a3·x³), on encoded 0…1 values. Mac runs them as CIColorMatrix and CIColorPolynomial; Windows
/// runs the same numbers per pixel.</summary>
public sealed class ClipLookRecipe
{
    private static readonly double[] Luma = [0.2126, 0.7152, 0.0722];

    /// <summary>The recipe of <paramref name="look"/>.</summary>
    public ClipLookRecipe(ClipLook look)
    {
        switch (look)
        {
            case ClipLook.Muted: Matrix = Saturation(0.65, 0.96); Bias = [0.04, 0.04, 0.04]; Curve = null; break;
            case ClipLook.Warm: Matrix = [[1.06, 0, 0], [0, 1.01, 0], [0, 0, 0.9]]; Bias = [0.01, 0.01, 0.01]; Curve = null; break;
            case ClipLook.Bw: Matrix = Saturation(0); Bias = [0, 0, 0]; Curve = [0, 0.7, 0.9, -0.6]; break;
            default: Matrix = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]; Bias = [0, 0, 0]; Curve = null; IsIdentity = true; break;
        }
    }

    /// <summary>The matrix applied after the base look, matching the Mac's encoded RGB grade.</summary>
    public ClipLookRecipe(ClipColorAdjustments adjustments)
    {
        var contrast = 1 + adjustments.Contrast * 0.005;
        var saturation = 1 + adjustments.Saturation * 0.01;
        var warmth = adjustments.Warmth * 0.0018;
        var offset = adjustments.Brightness * 0.0016 + (1 - contrast) * 0.5;
        double[] gains = [1 + warmth, 1, 1 - warmth];
        Matrix = Saturation(saturation, contrast);
        for (var row = 0; row < Matrix.Length; row++)
            for (var column = 0; column < Matrix[row].Length; column++)
                Matrix[row][column] *= gains[row];
        Bias = gains.Select(gain => offset * gain).ToArray();
        IsIdentity = adjustments.IsNeutral;
    }

    /// <summary>Rows of the colour matrix (red, green, blue).</summary>
    public double[][] Matrix { get; }
    /// <summary>Added after the matrix.</summary>
    public double[] Bias { get; }
    /// <summary>The cubic's coefficients, or null.</summary>
    public double[]? Curve { get; }
    /// <summary>Original or neutral: the frame stays untouched.</summary>
    public bool IsIdentity { get; }

    private static double[][] Saturation(double s, double scale = 1)
        => Enumerable.Range(0, 3).Select(row => Enumerable.Range(0, 3).Select(column => scale * ((1 - s) * Luma[column] + (row == column ? s : 0))).ToArray()).ToArray();

    /// <summary>The recipe on one RGB value, clamped to 0…1 as an 8-bit frame stores it.</summary>
    public double[] Apply(ReadOnlySpan<double> rgb)
    {
        var result = new double[3];
        for (var row = 0; row < 3; row++)
        {
            var value = Bias[row];
            for (var column = 0; column < 3; column++) value += Matrix[row][column] * rgb[column];
            value = Math.Clamp(value, 0, 1);
            if (Curve is { } curve)
            {
                var squared = value * value;
                value = curve[0] + curve[1] * value + curve[2] * squared + curve[3] * squared * value;
            }
            result[row] = Math.Clamp(value, 0, 1);
        }
        return result;
    }
}

/// <summary>Render-side rules for a clip's controls (design §6.9; Mac ClipControls.swift).</summary>
public static class ClipControlsRendering
{
    /// <summary>The controls a clip renders with, or null when it has none stored (the defaults render as before).</summary>
    public static ProjectClipControls? Controls(Project project, string? clipId)
        => clipId is null ? null : project.ClipControls.FirstOrDefault(entry => entry.ClipId == clipId);

    /// <summary>Speed, volume, fades or mute change the clip's audio.</summary>
    public static bool ChangesAudio(this ProjectClipControls controls)
        => controls.Speed != 1 || controls.GainDb != 0 || controls.FadeInSeconds > 0 || controls.FadeOutSeconds > 0 || controls.MuteSource;

    /// <summary>A color grade, flip or rotation changes each frame.</summary>
    public static bool ChangesPicture(this ProjectClipControls controls)
        => controls.HasColorGrade() || controls.FlipHorizontal || controls.RotationDegrees != 0;

    /// <summary>A base look other than Original or a stored adjustment grades the picture.</summary>
    public static bool HasColorGrade(this ProjectClipControls controls)
        => controls.Look != ClipLook.Original || controls.ColorAdjustments is not null;

    /// <summary>A quarter turn swaps the picture's width and height.</summary>
    public static bool IsQuarterTurn(this ProjectClipControls controls) => controls.RotationDegrees is 90 or 270;

    /// <summary>Where a framing anchor (x right, y down, 0…1 of the source) lands after the flip and the quarter turns.</summary>
    public static (double X, double Y) MapAnchor(this ProjectClipControls controls, double x, double y)
    {
        var point = (X: controls.FlipHorizontal ? 1 - x : x, Y: y);
        return controls.RotationDegrees switch
        {
            90 => (1 - point.Y, point.X),
            180 => (1 - point.X, 1 - point.Y),
            270 => (point.Y, 1 - point.X),
            _ => point
        };
    }

    /// <summary>Where a region of the source as filmed (top-left normalized) lands after the flip and the quarter turns, so a
    /// blur or a pointer stays on the same content.</summary>
    public static ClipEffectRect MapRect(this ProjectClipControls? controls, ClipEffectRect rect)
    {
        if (controls is null || (!controls.FlipHorizontal && controls.RotationDegrees == 0)) return rect;
        var first = controls.MapAnchor(rect.X, rect.Y);
        var second = controls.MapAnchor(rect.X + rect.Width, rect.Y + rect.Height);
        var x = Math.Min(first.X, second.X);
        var y = Math.Min(first.Y, second.Y);
        return new(x, y, Math.Max(first.X, second.X) - x, Math.Max(first.Y, second.Y) - y);
    }

    /// <summary>The inverse of <see cref="MapAnchor"/>: the point of the source as filmed that lands at (x, y) of the flipped and turned picture.</summary>
    public static (double X, double Y) UnmapAnchor(this ProjectClipControls controls, double x, double y)
    {
        var point = controls.RotationDegrees switch
        {
            90 => (X: y, Y: 1 - x),
            180 => (X: 1 - x, Y: 1 - y),
            270 => (X: 1 - y, Y: x),
            _ => (X: x, Y: y)
        };
        return controls.FlipHorizontal ? (1 - point.X, point.Y) : point;
    }

    /// <summary>The inverse of <see cref="MapRect"/>: the region of the source as filmed that is shown at <paramref name="rect"/>
    /// (Mac <c>unmapRect</c>), so a box dragged on the viewer is stored as filmed.</summary>
    public static ClipEffectRect UnmapRect(this ProjectClipControls? controls, ClipEffectRect rect)
    {
        if (controls is null || (!controls.FlipHorizontal && controls.RotationDegrees == 0)) return rect;
        var first = controls.UnmapAnchor(rect.X, rect.Y);
        var second = controls.UnmapAnchor(rect.X + rect.Width, rect.Y + rect.Height);
        var x = Math.Min(first.X, second.X);
        var y = Math.Min(first.Y, second.Y);
        return new(x, y, Math.Max(first.X, second.X) - x, Math.Max(first.Y, second.Y) - y);
    }

    /// <summary>The rendered size of a shape: the export presets' 1080-line frames, 1080 × 1350 for 4:5.</summary>
    public static PixelSize Size(this ClipShape shape) => shape switch
    {
        ClipShape.Landscape => new(1920, 1080),
        ClipShape.Portrait => new(1080, 1920),
        ClipShape.Square => new(1080, 1080),
        _ => new(1080, 1350)
    };

    private static double BaseBitrate(ClipShape shape) => shape switch
    {
        ClipShape.Square => 6_000_000,
        ClipShape.PortraitFourFive => 6_500_000,
        _ => 8_000_000
    };

    /// <summary>The frame a clip renders in: its own shape, else the project frame. An Original frame turns with a quarter turn
    /// so the whole picture stays in view; a fixed shape keeps its size and crops the turned picture to fill.</summary>
    public static PixelSize OutputSize(PixelSize source, ExportAspect aspect, ProjectClipControls? controls)
    {
        if (controls?.Shape is { } shape) return shape.Size();
        var turned = controls?.IsQuarterTurn() == true ? new PixelSize(source.Height, source.Width) : source;
        return ExportPresets.OutputSize(turned, aspect);
    }

    /// <summary>The export bitrate for a clip's frame; without a shape, the project frame's rule.</summary>
    public static long VideoBitrate(PixelSize size, ExportAspect aspect, ExportQuality quality, double fps, ProjectClipControls? controls)
    {
        if (controls?.Shape is not { } shape) return ExportPresets.VideoBitrate(size, aspect, quality, fps);
        return (long)Math.Floor(BaseBitrate(shape) * (quality == ExportQuality.High ? 1.5 : 1) * (fps >= 50 ? 1.5 : 1) + 0.5);
    }

    /// <summary>The encoder settings for a clip's render; identical to <see cref="ExportPresets.Output"/> without controls.</summary>
    public static OutputSpec Output(PixelSize source, double sourceRate, ExportAspect aspect, ExportQuality quality, ProjectClipControls? controls, string codec = "h264")
    {
        if (controls is null || (controls.Shape is null && !controls.IsQuarterTurn())) return ExportPresets.Output(source, sourceRate, aspect, quality, codec);
        var size = OutputSize(source, aspect, controls);
        var fps = ExportPresets.OutputFrameRate(sourceRate);
        return new(size, fps, VideoBitrate(size, aspect, quality, fps, controls), 48_000, 2, 160_000, codec)
            { PreserveSource = controls.Shape is null && aspect == ExportAspect.Source };
    }
}
