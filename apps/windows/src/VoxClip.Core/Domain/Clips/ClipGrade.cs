using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Effects;

namespace VoxClip.Core.Domain.Clips;

/// <summary>A clip's whole colour grade (looks spec 2026-11-28, sections 5 and 6; design §6.9) as per-frame constants in double,
/// with the reference arithmetic both renderers match. Twin of the Mac <c>ClipGradeRecipe</c>; both replay
/// shared/fixtures/clip-render/clip-grade-cases.json.
/// <para>On encoded Rec. 709 values in 0…1: o (the framed picture) → P, the Fix → f → L, the base look (or a timed colourLook) →
/// A, colorAdjustments, with no clamp between L and A → clamp → T1 highlights and shadows → T2 vibrance → T3 preset curves → T4
/// split tone → T5 fade → clamp → g → the mix f + a·(g − f) with a = amount/100. Amount blends the look over the Fix, which
/// always applies in full; at a = 0 L, A and T are skipped. After the motion crop and footage, F1 vignette and F2 grain act on
/// the output frame by pixel position, scaled by a. Without a Fix, at full amount and with no new controls, the chain is
/// exactly today's L → A.</para></summary>
public sealed class ClipGradeRecipe
{
    private static readonly double[] LumaWeights = [0.2126, 0.7152, 0.0722];

    /// <summary>The shoulder above the knee on a channel the Fix brightens: u = (z − 0.8)/0.2 becomes 0.8 + 0.2·u/(1 + α·u),
    /// slope 1 at the knee and the channel's white (z = G) at exactly 1.</summary>
    /// <param name="UMax">u at the channel's white.</param>
    /// <param name="Alpha">1 − 1/UMax.</param>
    public sealed record Shoulder(double UMax, double Alpha);

    /// <summary>Stage P: white balance and exposure as a gain per channel, normalised so a neutral grey keeps its luma, with a
    /// shoulder on every channel the gain brightens, so nothing clips that wasn't clipped.</summary>
    public sealed class PrimaryGains
    {
        /// <summary>Values up to the knee scale linearly.</summary>
        public const double Knee = 0.8;

        /// <summary>The Fix's gains.</summary>
        public PrimaryGains(ClipColorFix fix)
        {
            var t = fix.Temperature / 100.0;
            var k = fix.Tint / 100.0;
            double[] raw = [Math.Pow(2, 0.25 * t + 0.10 * k), Math.Pow(2, -0.20 * k), Math.Pow(2, -0.25 * t + 0.10 * k)];
            var n = Luma(raw);
            var e = Math.Pow(2, 0.009 * fix.Exposure);
            Gains = raw.Select(value => value / n * e).ToArray();
            Shoulders = Gains.Select(gain =>
            {
                if (gain <= 1) return null;
                var uMax = (gain - 0.8) / 0.2;
                return new Shoulder(uMax, 1 - 1 / uMax);
            }).ToArray();
        }

        /// <summary>Red, green and blue.</summary>
        public IReadOnlyList<double> Gains { get; }
        /// <summary>Per channel; null where the gain is 1 or less.</summary>
        public IReadOnlyList<Shoulder?> Shoulders { get; }

        /// <summary>One channel through its gain and shoulder.</summary>
        public double Apply(double value, int channel)
        {
            var z = Gains[channel] * Clamp01(value);
            if (Shoulders[channel] is not { } shoulder || z <= Knee) return z;
            var u = (z - 0.8) / 0.2;
            return 0.8 + 0.2 * u / (1 + shoulder.Alpha * u);
        }

        /// <summary>A colour through the gains.</summary>
        public double[] Apply(IReadOnlyList<double> rgb) => [Apply(rgb[0], 0), Apply(rgb[1], 1), Apply(rgb[2], 2)];
    }

    /// <summary>A monotone cubic through five knots at x = 0, ¼, ½, ¾ and 1 (stages T1 and T3): Fritsch–Butland tangents, so flat
    /// runs stay flat and nothing overshoots, and four segments in Horner form.</summary>
    public sealed class Curve
    {
        /// <summary>The curve through <paramref name="knots"/>.</summary>
        public Curve(IReadOnlyList<double> knots)
        {
            if (knots.Count != 5) throw new ArgumentException("A curve has five knots.", nameof(knots));
            const double h = 0.25;
            var slopes = Enumerable.Range(0, 4).Select(i => (knots[i + 1] - knots[i]) / h).ToArray();
            double[] m = [slopes[0], 0, 0, 0, slopes[3]];
            for (var i = 1; i <= 3; i++)
                m[i] = slopes[i - 1] > 0 && slopes[i] > 0 ? 2 * slopes[i - 1] * slopes[i] / (slopes[i - 1] + slopes[i]) : 0;
            Knots = knots.ToArray();
            Tangents = m;
            Segments = Enumerable.Range(0, 4).Select(i => new[]
            {
                knots[i], h * m[i], 3 * (knots[i + 1] - knots[i]) - 2 * h * m[i] - h * m[i + 1],
                2 * (knots[i] - knots[i + 1]) + h * m[i] + h * m[i + 1]
            }).ToArray();
        }

        /// <summary>The five knot values.</summary>
        public IReadOnlyList<double> Knots { get; }
        /// <summary>The tangent at each knot.</summary>
        public IReadOnlyList<double> Tangents { get; }
        /// <summary>Per segment (c0, c1, c2, c3): S = c0 + t·(c1 + t·(c2 + t·c3)) with t = 4v − i.</summary>
        public IReadOnlyList<IReadOnlyList<double>> Segments { get; }

        /// <summary>A preset curve's five values in thousandths.</summary>
        public static Curve FromThousandths(ClipCurveChannel channel) => new(channel.Values.Select(value => value / 1000.0).ToArray());

        /// <summary>Highlights and Shadows (stage T1): the quarter knots move by up to 0.12; the ends stay at 0 and 1.</summary>
        public static Curve Tone(int highlights, int shadows) => new([0, 0.25 + 0.12 * shadows / 100, 0.5, 0.75 + 0.12 * highlights / 100, 1]);

        /// <summary>The curve at <paramref name="value"/>, clamped to 0…1 first.</summary>
        public double Evaluate(double value)
        {
            var v = Clamp01(value);
            var i = Math.Min(3, (int)Math.Floor(4 * v));
            var t = 4 * v - i;
            var c = Segments[i];
            return c[0] + t * (c[1] + t * (c[2] + t * c[3]));
        }
    }

    /// <summary>Stage T4's constants: the shadow and highlight tints as zero-luma vectors already scaled by 0.12·saturation/100,
    /// and the balance's luma offset.</summary>
    public sealed class SplitTone
    {
        /// <summary>The constants of <paramref name="split"/>.</summary>
        public SplitTone(ClipSplitTone split)
        {
            Shadow = HueVector(split.ShadowHue).Select(value => 0.12 * split.ShadowSaturation / 100 * value).ToArray();
            Highlight = HueVector(split.HighlightHue).Select(value => 0.12 * split.HighlightSaturation / 100 * value).ToArray();
            Balance = 0.25 * split.Balance / 100;
        }

        /// <summary>Added in the shadows, weighted by (1 − τ)².</summary>
        public IReadOnlyList<double> Shadow { get; }
        /// <summary>Added in the highlights, weighted by τ².</summary>
        public IReadOnlyList<double> Highlight { get; }
        /// <summary>Added to luma before τ is clamped.</summary>
        public double Balance { get; }

        /// <summary>The fully saturated colour of <paramref name="hue"/> degrees, less its luma.</summary>
        public static double[] HueVector(int hue)
        {
            var hp = ((hue % 360 + 360) % 360) / 60.0;
            var f = hp - Math.Floor(hp);
            double[] rgb = ((int)Math.Floor(hp) % 6) switch
            {
                0 => [1, f, 0],
                1 => [1 - f, 1, 0],
                2 => [0, 1, f],
                3 => [0, 1 - f, 1],
                4 => [f, 0, 1],
                _ => [1, 0, 1 - f]
            };
            var l = Luma(rgb);
            return rgb.Select(value => value - l).ToArray();
        }

        internal void Apply(double[] y)
        {
            var t = Clamp01(Luma(y) + Balance);
            var ws = (1 - t) * (1 - t);
            var wh = t * t;
            for (var c = 0; c < 3; c++) y[c] = y[c] + ws * Shadow[c] + wh * Highlight[c];
        }
    }

    /// <summary>Stage T, after the adjustments: each step present only when its control isn't neutral.</summary>
    public sealed class ToneSteps
    {
        private ToneSteps(ClipColorGrade grade)
        {
            ShadowsHighlights = grade.Highlights != 0 || grade.Shadows != 0 ? Curve.Tone(grade.Highlights, grade.Shadows) : null;
            Vibrance = grade.Vibrance != 0 ? grade.Vibrance / 100.0 : null;
            Master = grade.Curve?.Master is { } master ? Curve.FromThousandths(master) : null;
            Red = grade.Curve?.Red is { } red ? Curve.FromThousandths(red) : null;
            Green = grade.Curve?.Green is { } green ? Curve.FromThousandths(green) : null;
            Blue = grade.Curve?.Blue is { } blue ? Curve.FromThousandths(blue) : null;
            SplitTone = grade.SplitTone is { } split ? new SplitTone(split) : null;
            Fade = grade.Fade != 0 ? 0.0015 * grade.Fade : null;
        }

        /// <summary>T1, Highlights and Shadows, applied to luma as a shift that keeps chroma.</summary>
        public Curve? ShadowsHighlights { get; }
        /// <summary>T2, Vibrance as vibrance/100.</summary>
        public double? Vibrance { get; }
        /// <summary>T3, the preset's master curve on every channel.</summary>
        public Curve? Master { get; }
        /// <summary>T3, the red channel's own curve.</summary>
        public Curve? Red { get; }
        /// <summary>T3, the green channel's own curve.</summary>
        public Curve? Green { get; }
        /// <summary>T3, the blue channel's own curve.</summary>
        public Curve? Blue { get; }
        /// <summary>T4.</summary>
        public SplitTone? SplitTone { get; }
        /// <summary>T5, Fade as 0.0015·fade: blacks lift by up to 0.15, white stays.</summary>
        public double? Fade { get; }

        internal static ToneSteps? For(ClipColorGrade grade)
        {
            var steps = new ToneSteps(grade);
            return steps.ShadowsHighlights is null && steps.Vibrance is null && steps.Master is null && steps.Red is null && steps.Green is null &&
                steps.Blue is null && steps.SplitTone is null && steps.Fade is null ? null : steps;
        }

        /// <summary>The clamped picture after the adjustments in, g (clamped) out.</summary>
        internal double[] Apply(double[] input)
        {
            var y = input.ToArray();
            if (ShadowsHighlights is { } tone)
            {
                var l = Luma(y);
                var delta = tone.Evaluate(l) - l;
                for (var c = 0; c < 3; c++) y[c] = y[c] + delta;
            }
            if (Vibrance is { } vibrance) y = Vibrant(y, vibrance);
            if (Master is { } master) for (var c = 0; c < 3; c++) y[c] = master.Evaluate(y[c]);
            if (Red is { } red) y[0] = red.Evaluate(y[0]);
            if (Green is { } green) y[1] = green.Evaluate(y[1]);
            if (Blue is { } blue) y[2] = blue.Evaluate(y[2]);
            SplitTone?.Apply(y);
            if (Fade is { } fade)
                for (var c = 0; c < 3; c++)
                {
                    var value = Clamp01(y[c]);
                    y[c] = value + fade * (1 - value) * (1 - value) * (1 - value);
                }
            for (var c = 0; c < 3; c++) y[c] = Clamp01(y[c]);
            return y;
        }

        /// <summary>Vibrance favours dull colours over saturated ones, spares skin-like hues (red to yellow) by 60%, keeps luma and
        /// never leaves 0…1.</summary>
        private static double[] Vibrant(double[] y, double v)
        {
            var l = Luma(y);
            var chroma = Math.Max(Math.Max(y[0], y[1]), y[2]) - Math.Min(Math.Min(y[0], y[1]), y[2]);
            var (r, g, b) = (y[0], y[1], y[2]);
            var skin = 0.0;
            if (r >= g && g >= b && chroma > 0)
            {
                var q = ((g - b) / chroma - 0.45) / 0.35;
                skin = Math.Max(0, 1 - q * q) * Smoothstep(0.02, 0.10, chroma);
            }
            var weight = v >= 0 ? (1 - chroma) * (1 - chroma) * (1 - 0.6 * skin) : (0.5 + 0.5 * chroma) * (1 - 0.6 * skin);
            var k = 1 + v * weight;
            foreach (var channel in y)
            {
                var d = channel - l;
                if (d > 1e-6) k = Math.Min(k, (1 - l) / d);
                else if (d < -1e-6) k = Math.Min(k, l / -d);
            }
            return [l + k * (y[0] - l), l + k * (y[1] - l), l + k * (y[2] - l)];
        }
    }

    /// <summary>The recipe of a base look, its adjustments and a grade.</summary>
    public ClipGradeRecipe(ClipLook look, ClipColorAdjustments? adjustments, ClipColorGrade? grade)
    {
        var fix = grade?.Fix ?? default;
        var a = (grade?.Amount ?? 100) / 100.0;
        Primary = fix.IsNeutral ? null : new PrimaryGains(fix);
        Look = new ClipLookRecipe(look);
        Adjustments = adjustments is { IsNeutral: false } ? new ClipLookRecipe(adjustments) : null;
        Tone = grade is null ? null : ToneSteps.For(grade);
        Amount = a;
        Vignette = 0.006 * (grade?.Vignette ?? 0) * a;
        Grain = 0.0012 * (grade?.Grain ?? 0) * a;
    }

    /// <summary>The recipe a clip's controls render with; a timed Ask Claude colourLook replaces only the base look.</summary>
    public static ClipGradeRecipe For(ProjectClipControls controls, ClipLook? replacement = null) =>
        new(replacement ?? controls.Look, controls.ColorAdjustments, controls.ColorGrade);

    /// <summary>Stage P, or null without a Fix.</summary>
    public PrimaryGains? Primary { get; }
    /// <summary>Stage L: the base look, or a timed colourLook in its place.</summary>
    public ClipLookRecipe Look { get; }
    /// <summary>Stage A, or null when neutral.</summary>
    public ClipLookRecipe? Adjustments { get; }
    /// <summary>Stage T, or null when every T control is neutral.</summary>
    public ToneSteps? Tone { get; }
    /// <summary>The look's strength, amount/100.</summary>
    public double Amount { get; }
    /// <summary>Stage F1's strength, 0.006·vignette·a: the corners darken by up to 60%.</summary>
    public double Vignette { get; }
    /// <summary>Stage F2's strength, 0.0012·grain·a.</summary>
    public double Grain { get; }

    /// <summary>The picture's colour changes: a Fix at any amount, or a look, an adjustment or a T control above amount 0.</summary>
    public bool ChangesColor => Primary is not null || (Amount > 0 && (!Look.IsIdentity || Adjustments is not null || Tone is not null));

    /// <summary>Stage F runs: vignette or grain above amount 0.</summary>
    public bool HasFinish => Vignette > 0 || Grain > 0;

    /// <summary>f: the Fix's output, or the clamped input without one.</summary>
    public double[] Fixed(IReadOnlyList<double> rgb) => Primary?.Apply(rgb) ?? [Clamp01(rgb[0]), Clamp01(rgb[1]), Clamp01(rgb[2])];

    /// <summary>The graded colour before stage F: P, L, A, T and the mix.</summary>
    public double[] Apply(IReadOnlyList<double> rgb)
    {
        var f = Fixed(rgb);
        if (Amount <= 0) return f;
        var y = Look.IsIdentity ? f.ToArray() : Look.Transform(f);
        if (Adjustments is not null) y = Adjustments.Transform(y);
        for (var c = 0; c < 3; c++) y[c] = Clamp01(y[c]);
        var g = Tone?.Apply(y) ?? y;
        if (Amount == 1) return g;
        return [f[0] + Amount * (g[0] - f[0]), f[1] + Amount * (g[1] - f[1]), f[2] + Amount * (g[2] - f[2])];
    }

    /// <summary>Stage F on one output pixel (<paramref name="x"/>, <paramref name="y"/>, top-left origin) of a
    /// <paramref name="width"/> × <paramref name="height"/> frame: the vignette, then grain unless the pixel lies in the context
    /// demo's <paramref name="hole"/>. <paramref name="frameHash"/> is <see cref="ClipGrain.FrameHash"/> of the rendered frame
    /// index.</summary>
    public double[] Finish(IReadOnlyList<double> rgb, int x, int y, int width, int height, uint frameHash, ClipGrain.Hole? hole)
    {
        double[] value = [rgb[0], rgb[1], rgb[2]];
        if (Vignette > 0)
        {
            var factor = 1 - Vignette * VignetteWeight(x, y, width, height).S;
            for (var c = 0; c < 3; c++) value[c] = value[c] * factor;
        }
        if (Grain > 0 && hole?.Contains(x, y) != true)
        {
            var l = Luma(value);
            var m = 0.25 + 3 * l * (1 - l);
            var g = ClipGrain.Value(x, y, width, height, frameHash);
            for (var c = 0; c < 3; c++) value[c] = value[c] + Grain * m * g;
        }
        return value;
    }

    /// <summary>Stage F1's weight at a pixel: Q is the squared distance on an ellipse through the corners (half-axes in proportion
    /// to √W and √H), and S its smoothstep from 0.16 to 1.</summary>
    public static (double Q, double S) VignetteWeight(int x, int y, int width, int height)
    {
        double w = width, h = height;
        var nx = (2 * x + 1 - width) / w;
        var ny = (2 * y + 1 - height) / h;
        var q = (nx * nx * w + ny * ny * h) / (w + h);
        var t = Clamp01((q - 0.16) / 0.84);
        return (q, t * t * (3 - 2 * t));
    }

    /// <summary>The stored byte of a value: floor(255·clamp01(v) + 0.5).</summary>
    public static int Byte(double value) => (int)Math.Floor(255 * Clamp01(value) + 0.5);

    internal static double Luma(IReadOnlyList<double> c) => LumaWeights[0] * c[0] + LumaWeights[1] * c[1] + LumaWeights[2] * c[2];

    internal static double Clamp01(double value) => Math.Min(1, Math.Max(0, value));

    private static double Smoothstep(double e0, double e1, double value)
    {
        var t = Clamp01((value - e0) / (e1 - e0));
        return t * t * (3 - 2 * t);
    }
}

/// <summary>Stage F2's grain (looks spec §5.7): one integer field, identical on every platform. Cells of 2 output pixels on frames
/// whose short side is 720 or more (else 1), a PCG hash of each cell and the rendered frame index, and bilinear weights in
/// quarters, so every intermediate value is an integer below 2^24. Twin of the Mac <c>ClipGrain</c>.</summary>
public static class ClipGrain
{
    /// <summary>XORed into the frame index before hashing.</summary>
    public const uint Seed = 0x9E3779B9;

    /// <summary>Where a pixel samples the cell grid: the cell (A, B) up and left of it and the next cells' weights in quarters.</summary>
    /// <param name="A">The cell column.</param>
    /// <param name="B">The cell row.</param>
    /// <param name="Fx4">The next column's weight, in quarters.</param>
    /// <param name="Fy4">The next row's weight, in quarters.</param>
    public readonly record struct Cell(int A, int B, int Fx4, int Fy4);

    /// <summary>The context demo's rendered rectangle in output pixels, where grain is skipped so a screen recording stays legible.
    /// A pixel is inside when its centre is.</summary>
    /// <param name="MinX">Left edge.</param>
    /// <param name="MinY">Top edge.</param>
    /// <param name="MaxX">Right edge, exclusive.</param>
    /// <param name="MaxY">Bottom edge, exclusive.</param>
    public sealed record Hole(double MinX, double MinY, double MaxX, double MaxY)
    {
        /// <summary>Whether pixel (<paramref name="x"/>, <paramref name="y"/>)'s centre lies inside.</summary>
        public bool Contains(int x, int y)
        {
            var cx = x + 0.5;
            var cy = y + 0.5;
            return MinX <= cx && cx < MaxX && MinY <= cy && cy < MaxY;
        }
    }

    /// <summary>PCG (Jarzynski and Olano 2020), mod 2^32.</summary>
    public static uint Pcg(uint value)
    {
        unchecked
        {
            var state = value * 747796405u + 2891336453u;
            var word = ((state >> (int)((state >> 28) + 4)) ^ state) * 277803737u;
            return (word >> 22) ^ word;
        }
    }

    /// <summary>The per-frame hash pcg(n ^ seed).</summary>
    public static uint FrameHash(uint index) => Pcg(index ^ Seed);

    /// <summary>The rendered frame index floor(t·fps + 0.5) for <paramref name="renderedSeconds"/> from the clip's start, so
    /// preview, export and the cover agree and a paused frame's grain stands still.</summary>
    public static uint FrameIndex(double renderedSeconds, double fps)
    {
        var index = Math.Floor(renderedSeconds * fps + 0.5);
        if (!double.IsFinite(index) || index < 0) return 0;
        return unchecked((uint)(long)Math.Min(index, long.MaxValue / 2));
    }

    /// <summary>2 pixels when the short side is 720 or more, else 1.</summary>
    public static int CellSize(int width, int height) => Math.Min(width, height) >= 720 ? 2 : 1;

    /// <summary>The cell and weights of pixel (<paramref name="x"/>, <paramref name="y"/>).</summary>
    public static Cell CellAt(int x, int y, int width, int height)
    {
        var s = CellSize(width, height);
        (int Index, int Quarters) Axis(int p)
        {
            var q = 2 * p + 1 - s;
            var span = 2 * s;
            var i = q >= 0 ? q / span : -((span - 1 - q) / span);
            return (i + 1, 4 * (q - span * i) / span);
        }
        var (a, fx4) = Axis(x);
        var (b, fy4) = Axis(y);
        return new(a, b, fx4, fy4);
    }

    /// <summary>The exact bilinear total, within ±2^19.</summary>
    public static int Total(int x, int y, int width, int height, uint frameHash)
    {
        var cell = CellAt(x, y, width, height);
        int Value(int i, int j) => (int)(Pcg(unchecked((uint)i + Pcg(unchecked((uint)j + frameHash)))) >> 16) - 32768;
        var (a, b, fx, fy) = (cell.A, cell.B, cell.Fx4, cell.Fy4);
        return ((4 - fx) * Value(a, b) + fx * Value(a + 1, b)) * (4 - fy) + ((4 - fx) * Value(a, b + 1) + fx * Value(a + 1, b + 1)) * fy;
    }

    /// <summary>The grain at a pixel, total / 2^20, in −0.5…0.5.</summary>
    public static double Value(int x, int y, int width, int height, uint frameHash) => Total(x, y, width, height, frameHash) / 1048576.0;

    /// <summary>The context demo's placement (normalised, top-left; today the whole frame) mapped through the motion crop into a
    /// <paramref name="width"/> × <paramref name="height"/> output frame and clamped to it. Footage drawn over the demo leaves the
    /// hole as it is.</summary>
    public static Hole DemoHole(int width, int height, MotionCropTransform motion, ClipEffectRect placement)
    {
        double w = width, h = height;
        var scale = motion.Scale;
        var cropWidth = w / scale;
        var cropHeight = h / scale;
        var cropX = (w - cropWidth) * motion.AnchorX;
        var cropY = (h - cropHeight) * motion.AnchorY;
        static double Clamp(double value, double limit) => Math.Min(limit, Math.Max(0, value));
        return new(Clamp((placement.X * w - cropX) * scale, w), Clamp((placement.Y * h - cropY) * scale, h),
            Clamp(((placement.X + placement.Width) * w - cropX) * scale, w), Clamp(((placement.Y + placement.Height) * h - cropY) * scale, h));
    }
}
