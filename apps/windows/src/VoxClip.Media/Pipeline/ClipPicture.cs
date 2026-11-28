using System.Buffers;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.ContextDemo;
using VoxClip.Core.Domain.Shared;
using SkiaSharp;

namespace VoxClip.Media.Pipeline;

/// <summary>A clip's picture controls in the shared frame composer (design §6.9; Mac ClipPicture), so preview and export draw the
/// same frame: the flip and quarter turns on the oriented source before the frame's crop, and the grade on the finished frame
/// before effects and captions.</summary>
internal static class ClipPicture
{
    /// <summary>The size of <paramref name="width"/> × <paramref name="height"/> after the controls' quarter turn.</summary>
    internal static (int Width, int Height) OrientedSize(int width, int height, ProjectClipControls? controls)
        => controls?.IsQuarterTurn() == true ? (height, width) : (width, height);

    /// <summary>True when the controls move pixels (a flip or a turn).</summary>
    internal static bool Orients(ProjectClipControls? controls) => controls is not null && (controls.FlipHorizontal || controls.RotationDegrees != 0);

    /// <summary>Mirrors left to right, then turns clockwise, into <paramref name="target"/> (tightly packed, <see cref="OrientedSize"/>).</summary>
    internal static void Orient(PixelBuffer source, Span<byte> target, ProjectClipControls controls, CancellationToken ct)
    {
        var (width, height) = OrientedSize(source.Width, source.Height, controls);
        var output = MemoryMarshal.Cast<byte, uint>(target[..checked(width * height * 4)]);
        var input = source.Pixels.Span;
        var flip = controls.FlipHorizontal;
        var degrees = controls.RotationDegrees;
        for (var row = 0; row < source.Height; row++)
        {
            ct.ThrowIfCancellationRequested();
            var line = MemoryMarshal.Cast<byte, uint>(input.Slice(row * source.Stride, source.Width * 4));
            for (var column = 0; column < source.Width; column++)
            {
                var x = flip ? source.Width - 1 - column : column;
                var (outputColumn, outputRow) = degrees switch
                {
                    90 => (source.Height - 1 - row, x),
                    180 => (source.Width - 1 - x, source.Height - 1 - row),
                    270 => (row, source.Width - 1 - x),
                    _ => (x, row)
                };
                output[outputRow * width + outputColumn] = line[column];
            }
        }
    }

    /// <summary>Rows per parallel block of the grade and the finish.</summary>
    private const int BlockRows = 32;

    /// <summary>Byte to encoded value, v/255 in double rounded once to float.</summary>
    private static readonly float[] Unit = Enumerable.Range(0, 256).Select(value => (float)(value / 255.0)).ToArray();

    /// <summary>Grades <paramref name="frame"/> (BGRA) in place with a clip's whole colour grade (looks spec §5 and §6; design §6.9),
    /// reading 8-bit once and writing 8-bit once. The Fix (stage P) is a function of each input byte, so it folds into the nine
    /// per-byte tables of the first matrix, the base look's (or, without a look, the adjustments'): table[r·3+c][v] =
    /// M[r][c]·P_c(v/255). The adjustments' matrix follows in float with no clamp between, as Core Image runs them. Stage T and
    /// Amount's mix over the Fix's output f then run four pixels at a time on each row. Without a Fix, without T and at full amount
    /// the arithmetic, and so every byte, is exactly that of the look and adjustments alone. A recipe that changes no colour leaves
    /// the frame untouched.</summary>
    internal static void Grade(PixelBuffer frame, ClipGradeRecipe recipe, CancellationToken ct)
    {
        if (!recipe.ChangesColor) return;
        var plan = new GradePlan(recipe);
        var memory = frame.Pixels;
        var stride = frame.Stride;
        var width = frame.Width;
        var height = frame.Height;
        Parallel.For(0, (height + BlockRows - 1) / BlockRows, new ParallelOptions { CancellationToken = ct }, block =>
        {
            var rows = plan.Second ? ArrayPool<float>.Shared.Rent(6 * Padded(width)) : null;
            try
            {
                for (var row = block * BlockRows; row < Math.Min(height, (block + 1) * BlockRows); row++)
                    plan.Row(memory.Span.Slice(row * stride, width * 4), rows);
            }
            finally { if (rows is not null) ArrayPool<float>.Shared.Return(rows); }
        });
    }

    /// <summary>Stage F on the finished frame (looks spec §5.7): the vignette, then grain, in one pass after the motion crop and the
    /// companion footage, so neither zooms and both carry on across a cutaway. The vignette's ellipse is a sum of a column and a row
    /// term; grain is the shared integer field of the rendered frame <paramref name="frameHash"/> (<see cref="ClipGrainField"/>),
    /// left out of the context demo's <paramref name="hole"/>. Tiles ask for no grain. Reads the graded bytes and writes bytes once.</summary>
    internal static void Finish(PixelBuffer frame, ClipGradeRecipe recipe, uint frameHash, ClipGrain.Hole? hole, CancellationToken ct, bool grain = true)
    {
        var vignette = (float)recipe.Vignette;
        var strength = grain ? (float)recipe.Grain : 0;
        if (vignette <= 0 && strength <= 0) return;
        var width = frame.Width;
        var height = frame.Height;
        double w = width, h = height;
        var across = vignette > 0 ? Enumerable.Range(0, width).Select(x => { var n = (2 * x + 1 - w) / w; return (float)(n * n * w / (w + h)); }).ToArray() : null;
        var down = vignette > 0 ? Enumerable.Range(0, height).Select(y => { var n = (2 * y + 1 - h) / h; return (float)(n * n * h / (w + h)); }).ToArray() : null;
        using var field = strength > 0 ? new ClipGrainField(width, height, frameHash, ct) : null;
        // A pixel is in the hole when its centre is: x + 0.5 in [MinX, MaxX).
        static int Edge(double value, int limit) => (int)Math.Clamp(Math.Ceiling(value - 0.5), 0, limit);
        var (left, top, right, bottom) = hole is { } rect
            ? (Edge(rect.MinX, width), Edge(rect.MinY, height), Edge(rect.MaxX, width), Edge(rect.MaxY, height)) : (0, 0, 0, 0);
        var memory = frame.Pixels;
        var stride = frame.Stride;
        Parallel.For(0, (height + BlockRows - 1) / BlockRows, new ParallelOptions { CancellationToken = ct }, block =>
        {
            var totals = field is null ? null : ArrayPool<int>.Shared.Rent(width);
            try
            {
                for (var row = block * BlockRows; row < Math.Min(height, (block + 1) * BlockRows); row++)
                {
                    var line = memory.Span.Slice(row * stride, width * 4);
                    if (totals is not null) field!.Row(row, totals.AsSpan(0, width));
                    var vertical = down?[row] ?? 0;
                    var holed = row >= top && row < bottom;
                    for (var x = 0; x < width; x++)
                    {
                        var offset = x * 4;
                        float red = Unit[line[offset + 2]], green = Unit[line[offset + 1]], blue = Unit[line[offset]];
                        if (across is not null)
                        {
                            var t = Math.Clamp((across[x] + vertical - 0.16f) / 0.84f, 0, 1);
                            var factor = 1 - vignette * (t * t * (3 - 2 * t));
                            red *= factor; green *= factor; blue *= factor;
                        }
                        if (totals is not null && !(holed && x >= left && x < right))
                        {
                            var luma = 0.2126f * red + 0.7152f * green + 0.0722f * blue;
                            var add = strength * (0.25f + 3 * luma * (1 - luma)) * (totals[x] / 1048576f);
                            red += add; green += add; blue += add;
                        }
                        line[offset + 2] = Encode(red);
                        line[offset + 1] = Encode(green);
                        line[offset] = Encode(blue);
                    }
                }
            }
            finally { if (totals is not null) ArrayPool<int>.Shared.Return(totals); }
        });
    }

    /// <summary>The stored byte: round(255·clamp01(v)), halves away from zero.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static byte Encode(float value) => (byte)MathF.Round(Math.Clamp(value, 0, 1) * 255, MidpointRounding.AwayFromZero);

    /// <summary>A row's float scratch length: whole groups of four.</summary>
    private static int Padded(int width) => (width + 3) & ~3;

    /// <summary>A grade's per-frame constants in float: the nine tables with the Fix folded in, the first recipe's bias and B&amp;W
    /// cubic, the adjustments' matrix when both a look and adjustments apply, f's tables for the mix, and stage T.</summary>
    private sealed class GradePlan
    {
        private readonly float[][] tables = new float[9][];
        private readonly float[] bias;
        private readonly float[]? curve;
        private readonly float[][]? after;
        private readonly float[]? afterBias;
        private readonly float[][]? fixedTables;
        private readonly ToneKernel? tone;
        private readonly float amount;

        internal GradePlan(ClipGradeRecipe recipe)
        {
            ClipLookRecipe? first = null, second = null;
            if (recipe.Amount > 0)
            {
                if (!recipe.Look.IsIdentity) (first, second) = (recipe.Look, recipe.Adjustments);
                else first = recipe.Adjustments;
            }
            var primary = recipe.Primary;
            var fixedValues = new double[3][];
            for (var channel = 0; channel < 3; channel++)
                fixedValues[channel] = Enumerable.Range(0, 256).Select(value => primary?.Apply(value / 255.0, channel) ?? value / 255.0).ToArray();
            for (var row = 0; row < 3; row++)
                for (var column = 0; column < 3; column++)
                {
                    var coefficient = first?.Matrix[row][column] ?? (row == column ? 1 : 0);
                    var table = new float[256];
                    // Without a Fix, today's arithmetic: matrix × byte / 255.
                    for (var value = 0; value < 256; value++)
                        table[value] = (float)(primary is null ? coefficient * value / 255.0 : coefficient * fixedValues[column][value]);
                    tables[row * 3 + column] = table;
                }
            bias = (first?.Bias ?? [0, 0, 0]).Select(value => (float)value).ToArray();
            curve = first?.Curve?.Select(value => (float)value).ToArray();
            after = second?.Matrix.Select(row => row.Select(value => (float)value).ToArray()).ToArray();
            afterBias = second?.Bias.Select(value => (float)value).ToArray();
            amount = (float)recipe.Amount;
            Mixes = recipe.Amount is > 0 and < 1;
            if (Mixes) fixedTables = fixedValues.Select(channel => channel.Select(value => (float)value).ToArray()).ToArray();
            if (recipe.Amount > 0 && recipe.Tone is { } steps) tone = new ToneKernel(steps);
        }

        /// <summary>Amount blends the look over f.</summary>
        internal bool Mixes { get; }
        /// <summary>Stage T or the mix runs, on float rows.</summary>
        internal bool Second => tone is not null || Mixes;

        /// <summary>Grades one row in place; <paramref name="rows"/> is six padded float rows when <see cref="Second"/>.</summary>
        internal void Row(Span<byte> line, float[]? rows)
        {
            var width = line.Length / 4;
            if (rows is null)
            {
                for (var x = 0; x < width; x++)
                {
                    var offset = x * 4;
                    First(line[offset + 2], line[offset + 1], line[offset], out var r, out var g, out var b);
                    line[offset + 2] = Encode(r);
                    line[offset + 1] = Encode(g);
                    line[offset] = Encode(b);
                }
                return;
            }
            var padded = Padded(width);
            var red = rows.AsSpan(0, padded);
            var green = rows.AsSpan(padded, padded);
            var blue = rows.AsSpan(2 * padded, padded);
            var fixedRed = rows.AsSpan(3 * padded, padded);
            var fixedGreen = rows.AsSpan(4 * padded, padded);
            var fixedBlue = rows.AsSpan(5 * padded, padded);
            for (var x = 0; x < width; x++)
            {
                var offset = x * 4;
                int r = line[offset + 2], g = line[offset + 1], b = line[offset];
                First(r, g, b, out red[x], out green[x], out blue[x]);
                if (fixedTables is not null)
                {
                    fixedRed[x] = fixedTables[0][r];
                    fixedGreen[x] = fixedTables[1][g];
                    fixedBlue[x] = fixedTables[2][b];
                }
            }
            for (var x = width; x < padded; x++) red[x] = green[x] = blue[x] = fixedRed[x] = fixedGreen[x] = fixedBlue[x] = 0;
            ToneKernel.Run(red, green, blue, fixedRed, fixedGreen, fixedBlue, tone, Mixes ? amount : 1);
            for (var x = 0; x < width; x++)
            {
                var offset = x * 4;
                line[offset + 2] = Encode(red[x]);
                line[offset + 1] = Encode(green[x]);
                line[offset] = Encode(blue[x]);
            }
        }

        /// <summary>The tables (the Fix and the first recipe), its cubic, then the adjustments' matrix, unclamped.</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void First(int red, int green, int blue, out float r, out float g, out float b)
        {
            var v0 = Channel(0, red, green, blue);
            var v1 = Channel(1, red, green, blue);
            var v2 = Channel(2, red, green, blue);
            if (after is null || afterBias is null) { r = v0; g = v1; b = v2; return; }
            r = afterBias[0] + after[0][0] * v0 + after[0][1] * v1 + after[0][2] * v2;
            g = afterBias[1] + after[1][0] * v0 + after[1][1] * v1 + after[1][2] * v2;
            b = afterBias[2] + after[2][0] * v0 + after[2][1] * v1 + after[2][2] * v2;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private float Channel(int channel, int red, int green, int blue)
        {
            var value = bias[channel] + tables[channel * 3][red] + tables[channel * 3 + 1][green] + tables[channel * 3 + 2][blue];
            if (curve is null) return value;
            value = Math.Clamp(value, 0, 1);
            var squared = value * value;
            return curve[0] + curve[1] * value + curve[2] * squared + curve[3] * squared * value;
        }
    }

    /// <summary>Stage T and the mix, branch-free on four pixels at a time (<see cref="Vector128{T}"/>, so x64 and ARM64 run the
    /// same float arithmetic): the clamp, Highlights and Shadows as a luma shift, Vibrance with its skin and gamut masks, the
    /// preset curves, split toning, Fade, the clamp to g, then f + a·(g − f). Curves pick their segment's Horner coefficients by
    /// mask rather than by a gather.</summary>
    private sealed class ToneKernel
    {
        private readonly Vector128<float>[]? shadowsHighlights;
        private readonly Vector128<float>[]? master;
        private readonly Vector128<float>[]? red;
        private readonly Vector128<float>[]? green;
        private readonly Vector128<float>[]? blue;
        private readonly float? vibrance;
        private readonly Vector128<float>[]? split;
        private readonly float balance;
        private readonly float? fade;

        internal ToneKernel(ClipGradeRecipe.ToneSteps steps)
        {
            shadowsHighlights = Segments(steps.ShadowsHighlights);
            master = Segments(steps.Master);
            red = Segments(steps.Red);
            green = Segments(steps.Green);
            blue = Segments(steps.Blue);
            vibrance = steps.Vibrance is { } value ? (float)value : null;
            if (steps.SplitTone is { } tones)
            {
                split = tones.Shadow.Concat(tones.Highlight).Select(value => Vector128.Create((float)value)).ToArray();
                balance = (float)tones.Balance;
            }
            fade = steps.Fade is { } amount ? (float)amount : null;
        }

        private static Vector128<float>[]? Segments(ClipGradeRecipe.Curve? curve) =>
            curve?.Segments.SelectMany(segment => segment).Select(value => Vector128.Create((float)value)).ToArray();

        /// <summary>Runs the kernel over padded rows: the graded values in, g (or the mix) out; f is read only for the mix.</summary>
        internal static void Run(Span<float> redRow, Span<float> greenRow, Span<float> blueRow, ReadOnlySpan<float> fixedRed,
            ReadOnlySpan<float> fixedGreen, ReadOnlySpan<float> fixedBlue, ToneKernel? kernel, float amount)
        {
            ref var r0 = ref MemoryMarshal.GetReference(redRow);
            ref var g0 = ref MemoryMarshal.GetReference(greenRow);
            ref var b0 = ref MemoryMarshal.GetReference(blueRow);
            ref var fr0 = ref MemoryMarshal.GetReference(fixedRed);
            ref var fg0 = ref MemoryMarshal.GetReference(fixedGreen);
            ref var fb0 = ref MemoryMarshal.GetReference(fixedBlue);
            var mixes = amount < 1;
            var a = Vector128.Create(amount);
            for (nuint index = 0; index < (nuint)redRow.Length; index += 4)
            {
                var r = Clamp01(Vector128.LoadUnsafe(ref r0, index));
                var g = Clamp01(Vector128.LoadUnsafe(ref g0, index));
                var b = Clamp01(Vector128.LoadUnsafe(ref b0, index));
                kernel?.Apply(ref r, ref g, ref b);
                if (mixes)
                {
                    var fr = Vector128.LoadUnsafe(ref fr0, index);
                    var fg = Vector128.LoadUnsafe(ref fg0, index);
                    var fb = Vector128.LoadUnsafe(ref fb0, index);
                    r = fr + a * (r - fr);
                    g = fg + a * (g - fg);
                    b = fb + a * (b - fb);
                }
                r.StoreUnsafe(ref r0, index);
                g.StoreUnsafe(ref g0, index);
                b.StoreUnsafe(ref b0, index);
            }
        }

        private void Apply(ref Vector128<float> r, ref Vector128<float> g, ref Vector128<float> b)
        {
            if (shadowsHighlights is not null)
            {
                var luma = Luma(r, g, b);
                var delta = Evaluate(luma, shadowsHighlights) - luma;
                r += delta; g += delta; b += delta;
            }
            if (vibrance is { } amount) Vibrant(ref r, ref g, ref b, amount);
            if (master is not null) { r = Evaluate(r, master); g = Evaluate(g, master); b = Evaluate(b, master); }
            if (red is not null) r = Evaluate(r, red);
            if (green is not null) g = Evaluate(g, green);
            if (blue is not null) b = Evaluate(b, blue);
            if (split is not null)
            {
                var t = Clamp01(Luma(r, g, b) + Vector128.Create(balance));
                var shadows = (Vector128<float>.One - t) * (Vector128<float>.One - t);
                var highlights = t * t;
                r = r + shadows * split[0] + highlights * split[3];
                g = g + shadows * split[1] + highlights * split[4];
                b = b + shadows * split[2] + highlights * split[5];
            }
            if (fade is { } lift)
            {
                var strength = Vector128.Create(lift);
                r = Fade(r, strength); g = Fade(g, strength); b = Fade(b, strength);
            }
            r = Clamp01(r); g = Clamp01(g); b = Clamp01(b);
        }

        private static Vector128<float> Fade(Vector128<float> value, Vector128<float> strength)
        {
            var c = Clamp01(value);
            var rest = Vector128<float>.One - c;
            return c + strength * rest * rest * rest;
        }

        /// <summary>Vibrance: dull colours gain more than saturated ones, skin-like hues (red ≥ green ≥ blue, at a hue between)
        /// 60% less, then the gain is capped so no channel leaves 0…1; luma stays.</summary>
        private static void Vibrant(ref Vector128<float> r, ref Vector128<float> g, ref Vector128<float> b, float amount)
        {
            var one = Vector128<float>.One;
            var zero = Vector128<float>.Zero;
            var luma = Luma(r, g, b);
            var chroma = Vector128.Max(r, Vector128.Max(g, b)) - Vector128.Min(r, Vector128.Min(g, b));
            var ordered = Vector128.GreaterThanOrEqual(r, g) & Vector128.GreaterThanOrEqual(g, b) & Vector128.GreaterThan(chroma, zero);
            var q = ((g - b) / chroma - Vector128.Create(0.45f)) / Vector128.Create(0.35f);
            var ramp = Clamp01((chroma - Vector128.Create(0.02f)) / Vector128.Create(0.08f));
            var skin = Vector128.Max(zero, one - q * q) * (ramp * ramp * (Vector128.Create(3f) - Vector128.Create(2f) * ramp));
            skin = Vector128.ConditionalSelect(ordered, skin, zero);
            var spare = one - Vector128.Create(0.6f) * skin;
            var weight = amount >= 0 ? (one - chroma) * (one - chroma) * spare : (Vector128.Create(0.5f) + Vector128.Create(0.5f) * chroma) * spare;
            var k = one + Vector128.Create(amount) * weight;
            k = Limit(k, r - luma, luma);
            k = Limit(k, g - luma, luma);
            k = Limit(k, b - luma, luma);
            r = luma + k * (r - luma);
            g = luma + k * (g - luma);
            b = luma + k * (b - luma);
        }

        private static Vector128<float> Limit(Vector128<float> k, Vector128<float> d, Vector128<float> luma)
        {
            var up = Vector128.GreaterThan(d, Vector128.Create(1e-6f));
            var down = Vector128.LessThan(d, Vector128.Create(-1e-6f));
            k = Vector128.ConditionalSelect(up, Vector128.Min(k, (Vector128<float>.One - luma) / d), k);
            return Vector128.ConditionalSelect(down, Vector128.Min(k, luma / -d), k);
        }

        /// <summary>A five-knot curve at <paramref name="value"/> (clamped): segment i = min(3, ⌊4v⌋), t = 4v − i, Horner.</summary>
        private static Vector128<float> Evaluate(Vector128<float> value, Vector128<float>[] c)
        {
            var x = Clamp01(value) * Vector128.Create(4f);
            var segment = Vector128.Min(Vector128.Floor(x), Vector128.Create(3f));
            var t = x - segment;
            var second = Vector128.GreaterThanOrEqual(segment, Vector128<float>.One);
            var third = Vector128.GreaterThanOrEqual(segment, Vector128.Create(2f));
            var fourth = Vector128.GreaterThanOrEqual(segment, Vector128.Create(3f));
            Vector128<float> Pick(int k) => Vector128.ConditionalSelect(fourth, c[12 + k],
                Vector128.ConditionalSelect(third, c[8 + k], Vector128.ConditionalSelect(second, c[4 + k], c[k])));
            return Pick(0) + t * (Pick(1) + t * (Pick(2) + t * Pick(3)));
        }

        private static Vector128<float> Luma(Vector128<float> r, Vector128<float> g, Vector128<float> b) =>
            Vector128.Create(0.2126f) * r + Vector128.Create(0.7152f) * g + Vector128.Create(0.0722f) * b;

        private static Vector128<float> Clamp01(Vector128<float> value) =>
            Vector128.Min(Vector128<float>.One, Vector128.Max(Vector128<float>.Zero, value));
    }

    /// <summary>A motion cue's crop of the finished frame, scaled back to fill it (Mac CompositionFrameGeometry.fill with Lanczos;
    /// Mitchell cubic here, bilinear in preview). The identity leaves the frame untouched.</summary>
    internal static void Motion(PixelBuffer frame, MotionCropTransform motion, bool forPreview, CancellationToken ct)
    {
        if (motion.Scale <= 1) return;
        ct.ThrowIfCancellationRequested();
        var crop = motion.Crop(frame.Width, frame.Height);
        var info = new SKImageInfo(frame.Width, frame.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var copy = SKImage.FromPixelCopy(info, frame.Pixels.Span[..(frame.Stride * frame.Height)], frame.Stride)
            ?? throw new InvalidOperationException("Could not copy the frame for its motion.");
        using var pin = frame.Pixels.Pin();
        unsafe
        {
            using var surface = SKSurface.Create(info, (IntPtr)pin.Pointer, frame.Stride) ?? throw new InvalidOperationException("Could not wrap the frame for its motion.");
            var sampling = forPreview ? new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.None) : new SKSamplingOptions(SKCubicResampler.Mitchell);
            surface.Canvas.DrawImage(copy, new SKRect((float)crop.X, (float)crop.Y, (float)(crop.X + crop.Width), (float)(crop.Y + crop.Height)),
                new SKRect(0, 0, frame.Width, frame.Height), sampling, null);
            surface.Canvas.Flush();
        }
    }
}
