using VoxClip.Core.Domain.Effects;
using VoxClip.Core.Domain.Frames;

namespace VoxClip.Core.Domain.Clips;

/// <summary>A small frame Auto and the light facts read (looks spec §5.9, §9.3): the framed picture before any grade, 8-bit RGB with
/// rows from the top, and the largest face, normalised from the top left, when there is one. Twin of the Mac
/// <c>ClipFrameSample</c>.</summary>
public sealed class ClipFrameSample
{
    /// <summary>A frame of <paramref name="width"/> × <paramref name="height"/> RGB pixels.</summary>
    public ClipFrameSample(int width, int height, byte[] rgb, ClipEffectRect? face = null)
    {
        if (width <= 0 || height <= 0 || rgb.Length != width * height * 3)
            throw new ArgumentException("A frame sample holds width × height RGB pixels.", nameof(rgb));
        Width = width;
        Height = height;
        Rgb = rgb;
        Face = face;
    }

    /// <summary>Pixels across.</summary>
    public int Width { get; }
    /// <summary>Pixels down.</summary>
    public int Height { get; }
    /// <summary>Three bytes a pixel, rows from the top.</summary>
    public IReadOnlyList<byte> Rgb { get; }
    /// <summary>The largest face, or null.</summary>
    public ClipEffectRect? Face { get; }

    internal double[][] Pixels() =>
        Enumerable.Range(0, Rgb.Count / 3).Select(index => new[] { Rgb[3 * index] / 255.0, Rgb[3 * index + 1] / 255.0, Rgb[3 * index + 2] / 255.0 }).ToArray();

    internal double[][] FacePixels()
    {
        if (Face is not { } face) return [];
        double w = Width, h = Height;
        var (x0, x1, y0, y1) = (face.X * w, (face.X + face.Width) * w, face.Y * h, (face.Y + face.Height) * h);
        return Pixels().Where((_, index) =>
        {
            var cx = index % Width + 0.5;
            var cy = index / Width + 0.5;
            return x0 <= cx && cx < x1 && y0 <= cy && cy < y1;
        }).ToArray();
    }
}

/// <summary>The Auto numbers of clip-looks.json's <c>measure.auto</c> (looks spec §5.9).</summary>
/// <param name="Frames">How many analysed frames Auto reads.</param>
/// <param name="FrameSize">Their long side in pixels.</param>
/// <param name="NeutralChroma">A neutral pixel's chroma (max − min) is under this.</param>
/// <param name="NeutralLumaMin">A neutral pixel's lowest luma.</param>
/// <param name="NeutralLumaMax">A neutral pixel's highest luma.</param>
/// <param name="BalanceScale">Temperature and Tint in points per full white-balance correction.</param>
/// <param name="BalanceLimit">Temperature and Tint stay within ± this.</param>
/// <param name="BalanceDeadZone">Temperature and Tint within ± this become 0.</param>
/// <param name="FaceTarget">The face's median luma Exposure aims for.</param>
/// <param name="FrameTarget">The frame's median luma Exposure aims for without a face.</param>
/// <param name="ExposureStrength">How much of the way Exposure goes.</param>
/// <param name="ExposureLimit">Exposure stays within ± this.</param>
/// <param name="ExposureDeadZone">Exposure within ± this becomes 0.</param>
/// <param name="FaceClipLuma">A face pixel above this luma is bright.</param>
/// <param name="FaceClipShare">Exposure never rises when more of the face than this is bright.</param>
public sealed record ClipAutoMeasure(int Frames, int FrameSize, double NeutralChroma, double NeutralLumaMin, double NeutralLumaMax, double BalanceScale,
    double BalanceLimit, double BalanceDeadZone, double FaceTarget, double FrameTarget, double ExposureStrength, double ExposureLimit,
    double ExposureDeadZone, double FaceClipLuma, double FaceClipShare);

/// <summary>The light-note thresholds of clip-looks.json's <c>measure.light</c> (looks spec §9.3).</summary>
/// <param name="DimFaceLuma">"face a little dark" under this face median luma.</param>
/// <param name="ClippedChannel">A face pixel with a channel at or above this is clipped.</param>
/// <param name="ClippedShare">"highlights clipped" above this share of the face.</param>
/// <param name="WarmCool">A warm or cool cast when the neutral red and blue means differ by more.</param>
/// <param name="GreenMagenta">A green or magenta cast when green and the red-blue mean differ by more.</param>
/// <param name="LowColor">"low color" under this mean chroma.</param>
/// <param name="HighColor">"high color" over this mean chroma.</param>
public sealed record ClipLightMeasure(double DimFaceLuma, double ClippedChannel, double ClippedShare, double WarmCool, double GreenMagenta,
    double LowColor, double HighColor);

/// <summary>clip-looks.json's <c>measure</c>: the numbers Auto and the planner's light notes share on both platforms. Twin of the Mac
/// <c>ClipColorMeasure</c>.</summary>
/// <param name="Auto">Auto's numbers.</param>
/// <param name="Light">The light notes' thresholds.</param>
public sealed record ClipColorMeasure(ClipAutoMeasure Auto, ClipLightMeasure Light)
{
    private static readonly string[] AutoKeys = ["frames", "frameSize", "neutralChroma", "neutralLumaMin", "neutralLumaMax", "balanceScale", "balanceLimit",
        "balanceDeadZone", "faceTarget", "frameTarget", "exposureStrength", "exposureLimit", "exposureDeadZone", "faceClipLuma", "faceClipShare"];
    private static readonly string[] LightKeys = ["dimFaceLuma", "clippedChannel", "clippedShare", "warmCool", "greenMagenta", "lowColor", "highColor"];

    /// <summary>The file's groups, which must hold exactly these keys; null otherwise.</summary>
    internal static ClipColorMeasure? Read(IReadOnlyDictionary<string, IReadOnlyDictionary<string, double>> groups)
    {
        if (groups.Count != 2 || !groups.TryGetValue("auto", out var a) || !groups.TryGetValue("light", out var l) ||
            !a.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(AutoKeys) || !l.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(LightKeys)) return null;
        var frames = a["frames"];
        var size = a["frameSize"];
        if (frames < 1 || Math.Floor(frames) != frames || size < 1 || Math.Floor(size) != size || a["neutralLumaMin"] > a["neutralLumaMax"]) return null;
        return new(new((int)frames, (int)size, a["neutralChroma"], a["neutralLumaMin"], a["neutralLumaMax"], a["balanceScale"], a["balanceLimit"],
                a["balanceDeadZone"], a["faceTarget"], a["frameTarget"], a["exposureStrength"], a["exposureLimit"], a["exposureDeadZone"],
                a["faceClipLuma"], a["faceClipShare"]),
            new(l["dimFaceLuma"], l["clippedChannel"], l["clippedShare"], l["warmCool"], l["greenMagenta"], l["lowColor"], l["highColor"]));
    }

    internal static double Chroma(IReadOnlyList<double> c) => Math.Max(Math.Max(c[0], c[1]), c[2]) - Math.Min(Math.Min(c[0], c[1]), c[2]);

    internal static bool IsNeutral(IReadOnlyList<double> c, ClipAutoMeasure auto)
    {
        var l = ClipGradeRecipe.Luma(c);
        return Chroma(c) < auto.NeutralChroma && auto.NeutralLumaMin <= l && l <= auto.NeutralLumaMax;
    }

    /// <summary>The grey-world means of the neutral pixels, or null without any.</summary>
    internal static double[]? NeutralMeans(IEnumerable<double[]> pixels, ClipAutoMeasure auto)
    {
        double[] sums = [0, 0, 0];
        var count = 0;
        foreach (var pixel in pixels.Where(pixel => IsNeutral(pixel, auto)))
        {
            for (var c = 0; c < 3; c++) sums[c] += pixel[c];
            count++;
        }
        return count == 0 ? null : [sums[0] / count, sums[1] / count, sums[2] / count];
    }

    internal static double Median(IEnumerable<double> values)
    {
        var ordered = values.Order().ToArray();
        var n = ordered.Length;
        return n % 2 == 1 ? ordered[n / 2] : (ordered[n / 2 - 1] + ordered[n / 2]) / 2;
    }

    internal static double Sum(IEnumerable<double> values)
    {
        var total = 0.0;
        foreach (var value in values) total += value;
        return total;
    }

    /// <summary>Half away from zero, the rounding every Core uses for points.</summary>
    internal static int Points(double value) => (int)Math.Floor(Math.Abs(value) + 0.5) * (value >= 0 ? 1 : -1);

    /// <summary>Clamped to ±<paramref name="limit"/>, rounded, and 0 within ±<paramref name="zone"/>.</summary>
    internal static int DeadZone(double value, double limit, double zone)
    {
        var point = Points(Math.Min(limit, Math.Max(-limit, value)));
        return Math.Abs(point) <= zone ? 0 : point;
    }
}

public readonly partial record struct ClipColorFix
{
    /// <summary>Auto (looks spec §5.9): a partial white balance from the neutral pixels and an exposure toward a face or frame
    /// target, on up to <see cref="ClipAutoMeasure.Frames"/> frames before any grade. No AI; each platform measures its own decoded
    /// frames, so a value can differ by a point between them. Nothing measurable gives the neutral Fix. Twin of the Mac
    /// <c>ClipColorFix.measure</c>.</summary>
    public static ClipColorFix Measure(IEnumerable<ClipFrameSample> frames, ClipAutoMeasure auto)
    {
        var used = frames.Take(auto.Frames).ToArray();
        var every = used.SelectMany(frame => frame.Pixels()).ToArray();
        if (every.Length == 0) return default;
        int temperature = 0, tint = 0;
        if (ClipColorMeasure.NeutralMeans(every, auto) is { } means)
        {
            var (r, g, b) = (means[0], means[1], means[2]);
            var t = 2 * Math.Log2(b / r);
            var k = Math.Log2(g * g / (r * b)) / 0.6;
            temperature = ClipColorMeasure.DeadZone(auto.BalanceScale * t, auto.BalanceLimit, auto.BalanceDeadZone);
            tint = ClipColorMeasure.DeadZone(auto.BalanceScale * k, auto.BalanceLimit, auto.BalanceDeadZone);
        }
        var faces = used.SelectMany(frame => frame.FacePixels()).ToArray();
        var middle = ClipColorMeasure.Median((faces.Length == 0 ? every : faces).Select(pixel => ClipGradeRecipe.Luma(pixel)));
        var target = faces.Length == 0 ? auto.FrameTarget : auto.FaceTarget;
        var raw = middle > 0 ? auto.ExposureStrength * Math.Log2(target / middle) / 0.009 : double.PositiveInfinity;
        var exposure = ClipColorMeasure.DeadZone(raw, auto.ExposureLimit, auto.ExposureDeadZone);
        var bright = faces.Count(pixel => ClipGradeRecipe.Luma(pixel) > auto.FaceClipLuma);
        if (faces.Length > 0 && (double)bright / faces.Length > auto.FaceClipShare) exposure = Math.Min(exposure, 0);
        return new(exposure, temperature, tint);
    }
}

/// <summary>What a light note says.</summary>
public enum ClipLightNoteKind
{
    /// <summary>"face a little dark".</summary>
    DimFace,
    /// <summary>"highlights clipped N%".</summary>
    Clipped,
    /// <summary>"warm-yellow cast".</summary>
    WarmCast,
    /// <summary>"cool-blue cast".</summary>
    CoolCast,
    /// <summary>"green cast".</summary>
    GreenCast,
    /// <summary>"magenta cast".</summary>
    MagentaCast,
    /// <summary>"low color".</summary>
    LowColor,
    /// <summary>"high color".</summary>
    HighColor
}

/// <summary>One note of a frame's light line.</summary>
/// <param name="Kind">What it says.</param>
/// <param name="Percent">The clipped share, for <see cref="ClipLightNoteKind.Clipped"/>.</param>
public sealed record ClipLightNote(ClipLightNoteKind Kind, int Percent = 0)
{
    /// <summary>The note as the planner reads it.</summary>
    public string Text => Kind switch
    {
        ClipLightNoteKind.DimFace => "face a little dark",
        ClipLightNoteKind.Clipped => $"highlights clipped {Percent}%",
        ClipLightNoteKind.WarmCast => "warm-yellow cast",
        ClipLightNoteKind.CoolCast => "cool-blue cast",
        ClipLightNoteKind.GreenCast => "green cast",
        ClipLightNoteKind.MagentaCast => "magenta cast",
        ClipLightNoteKind.LowColor => "low color",
        _ => "high color"
    };
}

/// <summary>One analysed frame's light (looks spec §9.3), measured on the device and summarised for the planner as one line, such as
/// "light: face a little dark · warm-yellow cast". It never measures or names skin colour. Twin of the Mac <c>ClipLightFacts</c>.</summary>
public sealed class ClipLightFacts
{
    /// <summary>The facts of <paramref name="frame"/> under <paramref name="measure"/>.</summary>
    public ClipLightFacts(ClipFrameSample frame, ClipColorMeasure measure) : this(FrameLight.Measure(frame, measure), measure.Light) { }

    /// <summary>The facts of a frame's measured light, with its notes from <paramref name="light"/>'s thresholds.</summary>
    public ClipLightFacts(FrameLight facts, ClipLightMeasure light)
    {
        ArgumentNullException.ThrowIfNull(facts);
        MedianLuma = facts.MedianLuma;
        P95Luma = facts.P95Luma;
        FaceMeanLuma = facts.FaceMeanLuma;
        FaceMedianLuma = facts.FaceMedianLuma;
        FaceClippedShare = facts.FaceClippedShare;
        NeutralMeans = facts.NeutralMeans;
        MeanChroma = facts.MeanChroma;
        Notes = facts.Notes(light);
    }

    /// <summary>The median luma.</summary>
    public double MedianLuma { get; }
    /// <summary>The nearest-rank 95th percentile of luma.</summary>
    public double P95Luma { get; }
    /// <summary>The face's mean luma, or null without a face.</summary>
    public double? FaceMeanLuma { get; }
    /// <summary>The face's median luma, or null without a face.</summary>
    public double? FaceMedianLuma { get; }
    /// <summary>The share of face pixels with a channel at or above the clipped threshold, or null without a face.</summary>
    public double? FaceClippedShare { get; }
    /// <summary>The neutral pixels' mean red, green and blue, or null without any.</summary>
    public IReadOnlyList<double>? NeutralMeans { get; }
    /// <summary>The mean chroma (max − min).</summary>
    public double MeanChroma { get; }
    /// <summary>The notes, in the order the line lists them.</summary>
    public IReadOnlyList<ClipLightNote> Notes { get; }

    /// <summary>The planner's line: "light: " and the notes, or "light: even".</summary>
    public string Line => "light: " + (Notes.Count == 0 ? "even" : string.Join(" · ", Notes.Select(note => note.Text)));
}
