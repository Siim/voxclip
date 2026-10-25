using VoxClip.Core.Domain.Captions;
using System.Numerics;
using System.Runtime.Intrinsics;
using System.Runtime.InteropServices;

namespace VoxClip.Media.Captions;

internal static class CaptionBlur
{
    internal static double[] Kernel(double sigma)
    {
        var radius = checked((int)Math.Ceiling(3 * sigma));
        var weights = Enumerable.Range(-radius, 2 * radius + 1).Select(offset => Math.Exp(-offset * offset / (2 * sigma * sigma))).ToArray();
        var sum = weights.Sum();
        return weights.Select(weight => weight / sum).ToArray();
    }

    internal static (int Low, int High)[] Boxes(double sigma)
    {
        var diameter = checked((int)Math.Floor(sigma * 3 * Math.Sqrt(2 * Math.PI) / 4 + 0.5));
        return diameter % 2 == 1 ? [(-(diameter - 1) / 2, (diameter - 1) / 2), (-(diameter - 1) / 2, (diameter - 1) / 2), (-(diameter - 1) / 2, (diameter - 1) / 2)]
            : [(-diameter / 2, diameter / 2 - 1), (-diameter / 2 + 1, diameter / 2), (-diameter / 2, diameter / 2)];
    }

    internal static void Apply(byte[] pixels, int width, int height, double sigma, CancellationToken ct, bool horizontalOnly = false)
        => new CaptionBlurBuffers().Apply(pixels, width, height, sigma, ct, horizontalOnly);
}

internal sealed class CaptionBlurBuffers
{
    internal readonly record struct Bounds(int Left, int Top, int Right, int Bottom);
    private byte[] scratch = [];
    private int[] sums = [];
    private readonly double[] kernel = new double[13];
    private double[] gaussianSums = [];
    private double kernelSigma = double.NaN;
    private int kernelLength;
    internal long RetainedBytes => scratch.LongLength + sums.LongLength * sizeof(int) + gaussianSums.LongLength * sizeof(double) + kernel.LongLength * sizeof(double);

    internal void Apply(Span<byte> pixels, int width, int height, double sigma, CancellationToken ct, bool horizontalOnly = false)
    {
        if (sigma == 0) return;
        var length = checked(width * height);
        if (scratch.Length < length) scratch = new byte[length];
        if (sums.Length < width) sums = new int[width];
        var source = pixels[..length];
        var target = scratch.AsSpan(0, length);
        if (sigma < 2)
        {
            if (sigma != kernelSigma)
            {
                var radius = (int)Math.Ceiling(3 * sigma);
                kernelLength = 2 * radius + 1;
                var total = 0.0;
                for (var offset = -radius; offset <= radius; offset++)
                {
                    kernel[offset + radius] = Math.Exp(-offset * offset / (2 * sigma * sigma));
                    total += kernel[offset + radius];
                }
                for (var index = 0; index < kernelLength; index++) kernel[index] /= total;
                kernelSigma = sigma;
            }
            Gaussian(source, target, width, height, false, ct);
            if (horizontalOnly) target.CopyTo(pixels);
            else Gaussian(target, source, width, height, true, ct);
            return;
        }
        var diameter = checked((int)Math.Floor(sigma * 3 * Math.Sqrt(2 * Math.PI) / 4 + 0.5));
        var bounds = InkBounds(source, width, height);
        if (bounds.Right <= bounds.Left) { pixels.Clear(); return; }
        for (var axis = 0; axis < (horizontalOnly ? 1 : 2); axis++)
            for (var pass = 0; pass < 3; pass++)
            {
                var low = diameter % 2 == 1 ? -(diameter - 1) / 2 : -diameter / 2 + (pass == 1 ? 1 : 0);
                var high = diameter % 2 == 1 ? (diameter - 1) / 2 : diameter / 2 - (pass == 0 ? 1 : 0);
                var output = axis == 0
                    ? bounds with { Left = Math.Max(0, bounds.Left - high), Right = Math.Min(width, bounds.Right - low) }
                    : bounds with { Top = Math.Max(0, bounds.Top - high), Bottom = Math.Min(height, bounds.Bottom - low) };
                target.Clear();
                if (axis == 0) Horizontal(source, target, width, height, low, high, output, ct);
                else Vertical(source, target, width, height, low, high, bounds, output, ct);
                bounds = InkBounds(target, width, height);
                if (bounds.Right <= bounds.Left) { pixels.Clear(); return; }
                var previous = source;
                source = target;
                target = previous;
            }
        source.CopyTo(pixels);
    }

    internal static Bounds InkBounds(ReadOnlySpan<byte> source, int width, int height)
    {
        var left = width; var top = height; var right = 0; var bottom = 0;
        for (var row = 0; row < height; row++)
        {
            var line = source.Slice(row * width, width);
            var first = line.IndexOfAnyExcept((byte)0);
            if (first < 0) continue;
            left = Math.Min(left, first); right = Math.Max(right, line.LastIndexOfAnyExcept((byte)0) + 1);
            top = Math.Min(top, row); bottom = row + 1;
        }
        return new(left, top, right, bottom);
    }

    private static void Horizontal(ReadOnlySpan<byte> source, Span<byte> target, int width, int height, int low, int high, Bounds bounds, CancellationToken ct)
    {
        var size = high - low + 1;
        var half = Vector128.Create((uint)(size / 2));
        var divisor = Vector128.Create((float)size);
        for (var row = bounds.Top; row < bounds.Bottom; row++)
        {
            if ((row & 31) == 0) ct.ThrowIfCancellationRequested();
            var input = source.Slice(row * width, width);
            var output = target.Slice(row * width, width);
            if (!input.ContainsAnyExcept((byte)0)) { output.Clear(); continue; }
            var sum = 0;
            for (var column = Math.Max(0, bounds.Left + low - 1); column <= Math.Min(width - 1, bounds.Left + high - 1); column++) sum += input[column];
            var cursor = bounds.Left;
            for (; cursor < bounds.Right && cursor + low - 1 < 0; cursor++)
            {
                if ((uint)(cursor + high) < (uint)width) sum += input[cursor + high];
                output[cursor] = (byte)((sum + size / 2) / size);
            }
            if (Vector128.IsHardwareAccelerated && size <= 65535)
                for (; cursor <= bounds.Right - Vector128<byte>.Count && cursor + high <= width - Vector128<byte>.Count; cursor += Vector128<byte>.Count)
                {
                    var entering = Vector128.LoadUnsafe(ref MemoryMarshal.GetReference(input), (nuint)(cursor + high));
                    var leaving = Vector128.LoadUnsafe(ref MemoryMarshal.GetReference(input), (nuint)(cursor + low - 1));
                    var lowDelta = Vector128.WidenLower(entering); var highDelta = Vector128.WidenUpper(entering);
                    var lowLeaving = Vector128.WidenLower(leaving); var highLeaving = Vector128.WidenUpper(leaving);
                    Vector128<int> first, second, third, fourth;
                    if (size <= 128)
                    {
                        var lower = Scan((lowDelta - lowLeaving).AsInt16(), ref sum);
                        var upper = Scan((highDelta - highLeaving).AsInt16(), ref sum);
                        first = Vector128.WidenLower(lower); second = Vector128.WidenUpper(lower);
                        third = Vector128.WidenLower(upper); fourth = Vector128.WidenUpper(upper);
                    }
                    else
                    {
                        first = Scan((Vector128.WidenLower(lowDelta) - Vector128.WidenLower(lowLeaving)).AsInt32(), ref sum);
                        second = Scan((Vector128.WidenUpper(lowDelta) - Vector128.WidenUpper(lowLeaving)).AsInt32(), ref sum);
                        third = Scan((Vector128.WidenLower(highDelta) - Vector128.WidenLower(highLeaving)).AsInt32(), ref sum);
                        fourth = Scan((Vector128.WidenUpper(highDelta) - Vector128.WidenUpper(highLeaving)).AsInt32(), ref sum);
                    }
                    Vector128.Narrow(Vector128.Narrow(Divide(first, half, divisor), Divide(second, half, divisor)), Vector128.Narrow(Divide(third, half, divisor), Divide(fourth, half, divisor)))
                        .StoreUnsafe(ref MemoryMarshal.GetReference(output), (nuint)cursor);
                }
            for (; cursor < bounds.Right; cursor++)
            {
                if ((uint)(cursor + high) < (uint)width) sum += input[cursor + high];
                if ((uint)(cursor + low - 1) < (uint)width) sum -= input[cursor + low - 1];
                output[cursor] = (byte)((sum + size / 2) / size);
            }
        }
    }

    private static Vector128<int> Scan(Vector128<int> delta, ref int sum)
    {
        delta += Vector128.Shuffle(delta, Vector128.Create(-1, 0, 1, 2));
        delta += Vector128.Shuffle(delta, Vector128.Create(-1, -1, 0, 1));
        delta += Vector128.Create(sum);
        sum = delta.GetElement(3);
        return delta;
    }

    private static Vector128<short> Scan(Vector128<short> delta, ref int sum)
    {
        delta += Vector128.Shuffle(delta, Vector128.Create((short)-1, 0, 1, 2, 3, 4, 5, 6));
        delta += Vector128.Shuffle(delta, Vector128.Create((short)-1, -1, 0, 1, 2, 3, 4, 5));
        delta += Vector128.Shuffle(delta, Vector128.Create((short)-1, -1, -1, -1, 0, 1, 2, 3));
        delta += Vector128.Create((short)sum);
        sum = delta.GetElement(7);
        return delta;
    }

    private static Vector128<uint> Divide(Vector128<int> sums, Vector128<uint> half, Vector128<float> divisor)
    {
        var numerator = sums.AsUInt32() + half;
        return Vector128.ConvertToUInt32(Vector128.ConvertToSingle(numerator) / divisor);
    }

    private void Vertical(ReadOnlySpan<byte> source, Span<byte> target, int width, int height, int low, int high, Bounds inputBounds, Bounds bounds, CancellationToken ct)
    {
        var span = bounds.Right - bounds.Left;
        var columns = sums.AsSpan(0, span);
        columns.Clear();
        for (var row = Math.Max(inputBounds.Top, bounds.Top + low); row <= Math.Min(inputBounds.Bottom - 1, bounds.Top + high); row++)
        {
            var input = source.Slice(row * width + bounds.Left, span);
            Accumulate(columns, input, true);
        }
        for (var row = bounds.Top; row < bounds.Bottom; row++)
        {
            if ((row & 31) == 0) ct.ThrowIfCancellationRequested();
            var output = target.Slice(row * width + bounds.Left, span);
            Quantize(columns, output, high - low + 1);
            var leaving = row + low;
            var entering = row + high + 1;
            if (leaving >= inputBounds.Top && leaving < inputBounds.Bottom)
            {
                var input = source.Slice(leaving * width + bounds.Left, span);
                Accumulate(columns, input, false);
            }
            if (entering >= inputBounds.Top && entering < inputBounds.Bottom)
            {
                var input = source.Slice(entering * width + bounds.Left, span);
                Accumulate(columns, input, true);
            }
        }
    }

    internal static void Quantize(ReadOnlySpan<int> sums, Span<byte> output, int size)
    {
        var column = 0;
        var half = new Vector<uint>((uint)(size / 2));
        var divisor = new Vector<float>(size);
        if (Vector.IsHardwareAccelerated && size <= 65535)
            for (; column <= output.Length - Vector<byte>.Count; column += Vector<byte>.Count)
            {
                var first = Divide(sums[column..], half, divisor);
                var second = Divide(sums[(column + Vector<int>.Count)..], half, divisor);
                var third = Divide(sums[(column + 2 * Vector<int>.Count)..], half, divisor);
                var fourth = Divide(sums[(column + 3 * Vector<int>.Count)..], half, divisor);
                Vector.Narrow(Vector.Narrow(first, second), Vector.Narrow(third, fourth)).CopyTo(output[column..]);
            }
        for (; column < output.Length; column++) output[column] = (byte)((sums[column] + size / 2) / size);
    }

    private static Vector<uint> Divide(ReadOnlySpan<int> sums, Vector<uint> half, Vector<float> divisor)
    {
        var numerator = Vector.AsVectorUInt32(new Vector<int>(sums)) + half;
        return Vector.ConvertToUInt32(Vector.ConvertToSingle(numerator) / divisor);
    }

    private static void Accumulate(Span<int> sums, ReadOnlySpan<byte> input, bool add)
    {
        var column = 0;
        if (Vector.IsHardwareAccelerated)
            for (; column <= input.Length - Vector<byte>.Count; column += Vector<byte>.Count)
            {
                Vector.Widen(new Vector<byte>(input[column..]), out Vector<ushort> low, out Vector<ushort> high);
                Vector.Widen(low, out Vector<uint> first, out Vector<uint> second);
                Vector.Widen(high, out Vector<uint> third, out Vector<uint> fourth);
                Update(sums[column..], Vector.AsVectorInt32(first), add);
                Update(sums[(column + Vector<int>.Count)..], Vector.AsVectorInt32(second), add);
                Update(sums[(column + 2 * Vector<int>.Count)..], Vector.AsVectorInt32(third), add);
                Update(sums[(column + 3 * Vector<int>.Count)..], Vector.AsVectorInt32(fourth), add);
            }
        for (; column < input.Length; column++) sums[column] += add ? input[column] : -input[column];
    }

    private static void Update(Span<int> sums, Vector<int> values, bool add)
    {
        var current = new Vector<int>(sums);
        (add ? current + values : current - values).CopyTo(sums);
    }

    private void Gaussian(ReadOnlySpan<byte> source, Span<byte> target, int width, int height, bool vertical, CancellationToken ct)
    {
        var radius = kernelLength / 2;
        if (vertical && gaussianSums.Length < width) gaussianSums = new double[width];
        for (var row = 0; row < height; row++)
        {
            if ((row & 31) == 0) ct.ThrowIfCancellationRequested();
            var output = target.Slice(row * width, width);
            if (vertical)
            {
                var weighted = gaussianSums.AsSpan(0, width);
                weighted.Clear();
                for (var offset = -radius; offset <= radius; offset++)
                {
                    var inputRow = row + offset;
                    if ((uint)inputRow >= (uint)height) continue;
                    var input = source.Slice(inputRow * width, width);
                    var weight = kernel[offset + radius];
                    for (var column = 0; column < width; column++) weighted[column] += weight * input[column];
                }
                for (var column = 0; column < width; column++) output[column] = (byte)Math.Clamp(CaptionMath.RoundHalfUp(weighted[column]), 0, 255);
                continue;
            }
            for (var column = 0; column < width; column++)
            {
                var sum = 0.0;
                for (var offset = -radius; offset <= radius; offset++)
                {
                    var inputRow = vertical ? row + offset : row;
                    var inputColumn = vertical ? column : column + offset;
                    if ((uint)inputRow < (uint)height && (uint)inputColumn < (uint)width) sum += kernel[offset + radius] * source[inputRow * width + inputColumn];
                }
                output[column] = (byte)Math.Clamp(CaptionMath.RoundHalfUp(sum), 0, 255);
            }
        }
    }
}
