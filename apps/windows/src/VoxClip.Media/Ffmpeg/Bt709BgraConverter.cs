using System.Buffers;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.Arm;
using System.Runtime.Intrinsics.X86;
using FFmpeg.AutoGen;

namespace VoxClip.Media.Ffmpeg;

/// <summary>BT.709 YUV to eight-bit BGRA with the same rounding on both Windows architectures.</summary>
internal static unsafe class Bt709BgraConverter
{
    private const double Kr = .2126;
    private const double Kb = .0722;
    private const double Kg = 1 - Kr - Kb;
    private const int FractionBits = 16;
    private const int Round = 1 << (FractionBits + 3);

    internal static bool Supports(AVFrame* frame) =>
        ((AVPixelFormat)frame->format is AVPixelFormat.AV_PIX_FMT_YUV420P or
            AVPixelFormat.AV_PIX_FMT_YUVJ420P or AVPixelFormat.AV_PIX_FMT_NV12 or
            AVPixelFormat.AV_PIX_FMT_YUV420P10LE or AVPixelFormat.AV_PIX_FMT_P010LE) &&
        (frame->colorspace is AVColorSpace.AVCOL_SPC_UNSPECIFIED or AVColorSpace.AVCOL_SPC_BT709) &&
        (frame->chroma_location is AVChromaLocation.AVCHROMA_LOC_UNSPECIFIED or
            AVChromaLocation.AVCHROMA_LOC_CENTER or AVChromaLocation.AVCHROMA_LOC_LEFT or
            AVChromaLocation.AVCHROMA_LOC_TOPLEFT) &&
        (frame->flags & ffmpeg.AV_FRAME_FLAG_INTERLACED) == 0;

    internal static void Convert(AVFrame* frame, byte* destination, int destinationStride) =>
        ConvertCore(frame, destination, destinationStride, false);

    // Retained as an independent fixed-point fallback and for exact accelerated-path comparisons.
    internal static void ConvertScalar(AVFrame* frame, byte* destination, int destinationStride) =>
        ConvertCore(frame, destination, destinationStride, true);

    private static void ConvertCore(AVFrame* frame, byte* destination, int destinationStride, bool scalar)
    {
        var format = (AVPixelFormat)frame->format;
        if (!Supports(frame)) throw new ArgumentException("Unsupported YUV pixel format.", nameof(frame));
        var width = frame->width;
        var height = frame->height;
        if (width <= 0 || height <= 0 || destinationStride < checked(width * 4) || destination == null)
            throw new ArgumentException("Invalid BGRA destination.", nameof(destinationStride));
        var semiplanar = format is AVPixelFormat.AV_PIX_FMT_NV12 or AVPixelFormat.AV_PIX_FMT_P010LE;
        var tenBit = format is AVPixelFormat.AV_PIX_FMT_YUV420P10LE or AVPixelFormat.AV_PIX_FMT_P010LE;
        var bytesPerSample = tenBit ? 2 : 1;
        var chromaWidth = (width + 1) / 2;
        var chromaHeight = (height + 1) / 2;
        if (frame->data[0] == null || frame->data[1] == null || (!semiplanar && frame->data[2] == null) ||
            Math.Abs((long)frame->linesize[0]) < (long)width * bytesPerSample ||
            Math.Abs((long)frame->linesize[1]) < (long)chromaWidth * bytesPerSample * (semiplanar ? 2 : 1) ||
            (!semiplanar && Math.Abs((long)frame->linesize[2]) < (long)chromaWidth * bytesPerSample))
            throw new ArgumentException("Invalid YUV planes or strides.", nameof(frame));

        var full = frame->color_range == AVColorRange.AVCOL_RANGE_JPEG || format == AVPixelFormat.AV_PIX_FMT_YUVJ420P;
        var max = tenBit ? 1023 : 255;
        var black = full ? 0 : tenBit ? 64 : 16;
        var neutral = tenBit ? 512 : 128;
        var lumaScale = (int)Math.Round((full ? 255.0 / max : 255.0 / (tenBit ? 876 : 219)) * (1 << FractionBits));
        var chromaScale = 255.0 / (full ? max : tenBit ? 896 : 224);
        var redScale = (int)Math.Round(2 * (1 - Kr) * chromaScale * (1 << FractionBits));
        var blueScale = (int)Math.Round(2 * (1 - Kb) * chromaScale * (1 << FractionBits));
        var greenUScale = (int)Math.Round(-2 * Kb * (1 - Kb) / Kg * chromaScale * (1 << FractionBits));
        var greenVScale = (int)Math.Round(-2 * Kr * (1 - Kr) / Kg * chromaScale * (1 << FractionBits));
        // Left-sited chroma is used by MPEG/H.264; unspecified siting is centered.
        var left = frame->chroma_location is AVChromaLocation.AVCHROMA_LOC_LEFT or AVChromaLocation.AVCHROMA_LOC_TOPLEFT;
        var top = frame->chroma_location == AVChromaLocation.AVCHROMA_LOC_TOPLEFT;
        var scratchLength = checked(chromaWidth * 2);
        int[]? rented = null;
        Span<int> vertical = scratchLength <= 8192 ? stackalloc int[scratchLength] :
            (rented = ArrayPool<int>.Shared.Rent(scratchLength));
        try
        {
            fixed (int* verticalU = vertical)
            {
                var verticalV = verticalU + chromaWidth;
                for (var y = 0; y < height; y++)
                {
                    Axis(y, chromaHeight, top, out var y0, out var y1, out var wy);
                    var uRow0 = frame->data[1] + y0 * frame->linesize[1];
                    var vRow0 = semiplanar ? uRow0 : frame->data[2] + y0 * frame->linesize[2];
                    var uRow1 = frame->data[1] + y1 * frame->linesize[1];
                    var vRow1 = semiplanar ? uRow1 : frame->data[2] + y1 * frame->linesize[2];
                    var inverseWy = 4 - wy;
                    if (semiplanar && !tenBit)
                    {
                        for (var cx = 0; cx < chromaWidth; cx++)
                        {
                            var index = cx * 2;
                            verticalU[cx] = inverseWy * uRow0[index] + wy * uRow1[index];
                            verticalV[cx] = inverseWy * uRow0[index + 1] + wy * uRow1[index + 1];
                        }
                    }
                    else if (!tenBit)
                    {
                        for (var cx = 0; cx < chromaWidth; cx++)
                        {
                            verticalU[cx] = inverseWy * uRow0[cx] + wy * uRow1[cx];
                            verticalV[cx] = inverseWy * vRow0[cx] + wy * vRow1[cx];
                        }
                    }
                    else if (semiplanar)
                    {
                        var uv0 = (ushort*)uRow0;
                        var uv1 = (ushort*)uRow1;
                        for (var cx = 0; cx < chromaWidth; cx++)
                        {
                            var index = cx * 2;
                            verticalU[cx] = inverseWy * (uv0[index] >> 6) + wy * (uv1[index] >> 6);
                            verticalV[cx] = inverseWy * (uv0[index + 1] >> 6) + wy * (uv1[index + 1] >> 6);
                        }
                    }
                    else
                    {
                        var u0 = (ushort*)uRow0;
                        var u1 = (ushort*)uRow1;
                        var v0 = (ushort*)vRow0;
                        var v1 = (ushort*)vRow1;
                        for (var cx = 0; cx < chromaWidth; cx++)
                        {
                            verticalU[cx] = inverseWy * Math.Min(u0[cx], (ushort)1023) +
                                wy * Math.Min(u1[cx], (ushort)1023);
                            verticalV[cx] = inverseWy * Math.Min(v0[cx], (ushort)1023) +
                                wy * Math.Min(v1[cx], (ushort)1023);
                        }
                    }
                    var target = destination + y * destinationStride;
                    var lumaRow = frame->data[0] + y * frame->linesize[0];
                    if (!scalar && Avx2.IsSupported && width >= 8)
                    {
                        Avx2Row(target, lumaRow, verticalU, verticalV, width, chromaWidth,
                            left, tenBit, semiplanar, neutral, black, lumaScale, blueScale, greenUScale,
                            greenVScale, redScale);
                        continue;
                    }
                    if (!scalar && AdvSimd.Arm64.IsSupported && width >= 8)
                    {
                        Arm64Row(target, lumaRow, verticalU, verticalV, width, chromaWidth,
                            left, tenBit, semiplanar, neutral, black, lumaScale, blueScale, greenUScale,
                            greenVScale, redScale);
                        continue;
                    }
                    if (!scalar && Vector.IsHardwareAccelerated && width >= Vector<int>.Count)
                    {
                        VectorRow(target, lumaRow, verticalU, verticalV, width, chromaWidth,
                            left, tenBit, semiplanar, neutral, black, lumaScale,
                            blueScale, greenUScale, greenVScale, redScale);
                        continue;
                    }
                    if (!scalar)
                    {
                        // Adjacent luma samples share a chroma interval. Compute the two
                        // horizontal weights once per pair instead of locating four samples
                        // and clamping both axes for every output pixel.
                        for (var cx = 0; cx < chromaWidth; cx++)
                        {
                            var next = Math.Min(cx + 1, chromaWidth - 1);
                            var previous = Math.Max(cx - 1, 0);
                            var x = cx * 2;
                            var uEven = left ? 4 * verticalU[cx] : verticalU[previous] + 3 * verticalU[cx];
                            var vEven = left ? 4 * verticalV[cx] : verticalV[previous] + 3 * verticalV[cx];
                            WritePixel(target + x * 4, lumaRow, x, uEven - neutral * 16,
                                vEven - neutral * 16, tenBit, semiplanar, black, lumaScale,
                                blueScale, greenUScale, greenVScale, redScale);
                            if (x + 1 >= width) continue;
                            var uOdd = left ? 2 * (verticalU[cx] + verticalU[next]) : 3 * verticalU[cx] + verticalU[next];
                            var vOdd = left ? 2 * (verticalV[cx] + verticalV[next]) : 3 * verticalV[cx] + verticalV[next];
                            WritePixel(target + (x + 1) * 4, lumaRow, x + 1, uOdd - neutral * 16,
                                vOdd - neutral * 16, tenBit, semiplanar, black, lumaScale,
                                blueScale, greenUScale, greenVScale, redScale);
                        }
                        continue;
                    }
                    for (var x = 0; x < width; x++)
                    {
                        Axis(x, chromaWidth, left, out var x0, out var x1, out var wx);
                        var u16 = (4 - wx) * verticalU[x0] + wx * verticalU[x1] - neutral * 16;
                        var v16 = (4 - wx) * verticalV[x0] + wx * verticalV[x1] - neutral * 16;
                        var luma = Read(lumaRow, x, tenBit, tenBit && semiplanar);
                        // Each signed accumulator fits in 32 bits, including out-of-range 10-bit samples.
                        var y16 = (luma - black) * lumaScale * 16;
                        var pixel = target + x * 4;
                        pixel[0] = Byte((y16 + blueScale * u16 + Round) >> (FractionBits + 4));
                        pixel[1] = Byte((y16 + greenUScale * u16 + greenVScale * v16 + Round) >> (FractionBits + 4));
                        pixel[2] = Byte((y16 + redScale * v16 + Round) >> (FractionBits + 4));
                        pixel[3] = 255;
                    }
                }
            }
        }
        finally { if (rented is not null) ArrayPool<int>.Shared.Return(rented); }
    }

    private static void Avx2Row(byte* target, byte* lumaRow, int* verticalU, int* verticalV,
        int width, int chromaWidth, bool left, bool tenBit, bool semiplanar, int neutral, int black, int lumaScale,
        int blueScale, int greenUScale, int greenVScale, int redScale)
    {
        var blackVector = Vector256.Create(black);
        var lumaVector = Vector256.Create(lumaScale * 16);
        var neutralVector = Vector256.Create(neutral * 16);
        var blueVector = Vector256.Create(blueScale);
        var greenUVector = Vector256.Create(greenUScale);
        var greenVVector = Vector256.Create(greenVScale);
        var redVector = Vector256.Create(redScale);
        var roundVector = Vector256.Create(Round);
        var maxVector = Vector256.Create(255);
        var alphaVector = Vector256.Create(unchecked((int)0xff000000));
        var x = 0;
        // Centered chroma needs a previous sample. The first four pixels use
        // the edge-clamped scalar path; all interior groups load four samples.
        var prefix = left ? 0 : Math.Min(4, width);
        for (; x < prefix; x++)
        {
            Axis(x, chromaWidth, left, out var x0, out var x1, out var weight);
            var u = (4 - weight) * verticalU[x0] + weight * verticalU[x1] - neutral * 16;
            var v = (4 - weight) * verticalV[x0] + weight * verticalV[x1] - neutral * 16;
            WritePixel(target + x * 4, lumaRow, x, u, v, tenBit, semiplanar, black,
                lumaScale, blueScale, greenUScale, greenVScale, redScale);
        }
        for (; x + 8 <= width && (x >> 1) + 4 < chromaWidth; x += 8)
        {
            var cx = x >> 1;
            var currentU = Sse2.LoadVector128(verticalU + cx);
            var currentV = Sse2.LoadVector128(verticalV + cx);
            var nextU = Sse2.LoadVector128(verticalU + cx + 1);
            var nextV = Sse2.LoadVector128(verticalV + cx + 1);
            Vector128<int> evenU, evenV, oddU, oddV;
            if (left)
            {
                evenU = Sse2.ShiftLeftLogical(currentU, 2);
                evenV = Sse2.ShiftLeftLogical(currentV, 2);
                oddU = Sse2.ShiftLeftLogical(Sse2.Add(currentU, nextU), 1);
                oddV = Sse2.ShiftLeftLogical(Sse2.Add(currentV, nextV), 1);
            }
            else
            {
                var previousU = Sse2.LoadVector128(verticalU + cx - 1);
                var previousV = Sse2.LoadVector128(verticalV + cx - 1);
                var tripleU = Sse2.Add(currentU, Sse2.ShiftLeftLogical(currentU, 1));
                var tripleV = Sse2.Add(currentV, Sse2.ShiftLeftLogical(currentV, 1));
                evenU = Sse2.Add(previousU, tripleU);
                evenV = Sse2.Add(previousV, tripleV);
                oddU = Sse2.Add(tripleU, nextU);
                oddV = Sse2.Add(tripleV, nextV);
            }
            var u = Avx2.Subtract(Vector256.Create(Sse2.UnpackLow(evenU, oddU),
                Sse2.UnpackHigh(evenU, oddU)), neutralVector);
            var v = Avx2.Subtract(Vector256.Create(Sse2.UnpackLow(evenV, oddV),
                Sse2.UnpackHigh(evenV, oddV)), neutralVector);
            var luma = tenBit ? Avx2.ConvertToVector256Int32((ushort*)(lumaRow + x * 2)) :
                Avx2.ConvertToVector256Int32(lumaRow + x);
            if (tenBit) luma = semiplanar ? Avx2.ShiftRightLogical(luma.AsUInt32(), 6).AsInt32() :
                Avx2.Min(luma, Vector256.Create(1023));
            var y = Avx2.MultiplyLow(Avx2.Subtract(luma, blackVector), lumaVector);
            var b = Avx2.Min(Avx2.Max(Avx2.ShiftRightArithmetic(Avx2.Add(Avx2.Add(y,
                Avx2.MultiplyLow(blueVector, u)), roundVector), FractionBits + 4), Vector256<int>.Zero), maxVector);
            var g = Avx2.Min(Avx2.Max(Avx2.ShiftRightArithmetic(Avx2.Add(Avx2.Add(Avx2.Add(y,
                Avx2.MultiplyLow(greenUVector, u)), Avx2.MultiplyLow(greenVVector, v)), roundVector),
                FractionBits + 4), Vector256<int>.Zero), maxVector);
            var r = Avx2.Min(Avx2.Max(Avx2.ShiftRightArithmetic(Avx2.Add(Avx2.Add(y,
                Avx2.MultiplyLow(redVector, v)), roundVector), FractionBits + 4), Vector256<int>.Zero), maxVector);
            var bgra = Avx2.Or(Avx2.Or(Avx2.Or(b, Avx2.ShiftLeftLogical(g, 8)),
                Avx2.ShiftLeftLogical(r, 16)), alphaVector);
            Avx.Store((int*)(target + x * 4), bgra);
        }
        for (; x < width; x++)
        {
            Axis(x, chromaWidth, left, out var x0, out var x1, out var weight);
            var u = (4 - weight) * verticalU[x0] + weight * verticalU[x1] - neutral * 16;
            var v = (4 - weight) * verticalV[x0] + weight * verticalV[x1] - neutral * 16;
            WritePixel(target + x * 4, lumaRow, x, u, v, tenBit, semiplanar, black,
                lumaScale, blueScale, greenUScale, greenVScale, redScale);
        }
    }

    private static void Arm64Row(byte* target, byte* lumaRow, int* verticalU, int* verticalV,
        int width, int chromaWidth, bool left, bool tenBit, bool semiplanar, int neutral, int black, int lumaScale,
        int blueScale, int greenUScale, int greenVScale, int redScale)
    {
        var blackVector = Vector128.Create(black);
        var lumaVector = Vector128.Create(lumaScale * 16);
        var neutralVector = Vector128.Create(neutral * 16);
        var blueVector = Vector128.Create(blueScale);
        var greenUVector = Vector128.Create(greenUScale);
        var greenVVector = Vector128.Create(greenVScale);
        var redVector = Vector128.Create(redScale);
        var roundVector = Vector128.Create(Round);
        var maxVector = Vector128.Create(255);
        var alphaVector = Vector128.Create(unchecked((int)0xff000000));
        var x = 0;
        var prefix = left ? 0 : Math.Min(4, width);
        for (; x < prefix; x++)
        {
            Axis(x, chromaWidth, left, out var x0, out var x1, out var weight);
            var u = (4 - weight) * verticalU[x0] + weight * verticalU[x1] - neutral * 16;
            var v = (4 - weight) * verticalV[x0] + weight * verticalV[x1] - neutral * 16;
            WritePixel(target + x * 4, lumaRow, x, u, v, tenBit, semiplanar, black,
                lumaScale, blueScale, greenUScale, greenVScale, redScale);
        }
        for (; x + 8 <= width && (x >> 1) + 4 < chromaWidth; x += 8)
        {
            var cx = x >> 1;
            var currentU = AdvSimd.LoadVector128(verticalU + cx);
            var currentV = AdvSimd.LoadVector128(verticalV + cx);
            var nextU = AdvSimd.LoadVector128(verticalU + cx + 1);
            var nextV = AdvSimd.LoadVector128(verticalV + cx + 1);
            Vector128<int> evenU, evenV, oddU, oddV;
            if (left)
            {
                evenU = currentU << 2;
                evenV = currentV << 2;
                oddU = AdvSimd.Add(currentU, nextU) << 1;
                oddV = AdvSimd.Add(currentV, nextV) << 1;
            }
            else
            {
                var previousU = AdvSimd.LoadVector128(verticalU + cx - 1);
                var previousV = AdvSimd.LoadVector128(verticalV + cx - 1);
                var tripleU = AdvSimd.Add(currentU, currentU << 1);
                var tripleV = AdvSimd.Add(currentV, currentV << 1);
                evenU = AdvSimd.Add(previousU, tripleU);
                evenV = AdvSimd.Add(previousV, tripleV);
                oddU = AdvSimd.Add(tripleU, nextU);
                oddV = AdvSimd.Add(tripleV, nextV);
            }
            var u0 = AdvSimd.Subtract(AdvSimd.Arm64.ZipLow(evenU, oddU), neutralVector);
            var u1 = AdvSimd.Subtract(AdvSimd.Arm64.ZipHigh(evenU, oddU), neutralVector);
            var v0 = AdvSimd.Subtract(AdvSimd.Arm64.ZipLow(evenV, oddV), neutralVector);
            var v1 = AdvSimd.Subtract(AdvSimd.Arm64.ZipHigh(evenV, oddV), neutralVector);
            Vector128<ushort> lumaShorts;
            if (tenBit)
            {
                lumaShorts = AdvSimd.LoadVector128((ushort*)(lumaRow + x * 2));
                lumaShorts = semiplanar ? AdvSimd.ShiftRightLogical(lumaShorts, 6) :
                    AdvSimd.Min(lumaShorts, Vector128.Create((ushort)1023));
            }
            else lumaShorts = AdvSimd.ZeroExtendWideningLower(AdvSimd.LoadVector64(lumaRow + x));
            var y0 = AdvSimd.Multiply(AdvSimd.Subtract(
                AdvSimd.ZeroExtendWideningLower(lumaShorts.GetLower()).AsInt32(), blackVector), lumaVector);
            var y1 = AdvSimd.Multiply(AdvSimd.Subtract(
                AdvSimd.ZeroExtendWideningLower(lumaShorts.GetUpper()).AsInt32(), blackVector), lumaVector);
            Arm64Pixels(target + x * 4, y0, u0, v0, blueVector, greenUVector,
                greenVVector, redVector, roundVector, maxVector, alphaVector);
            Arm64Pixels(target + (x + 4) * 4, y1, u1, v1, blueVector, greenUVector,
                greenVVector, redVector, roundVector, maxVector, alphaVector);
        }
        for (; x < width; x++)
        {
            Axis(x, chromaWidth, left, out var x0, out var x1, out var weight);
            var u = (4 - weight) * verticalU[x0] + weight * verticalU[x1] - neutral * 16;
            var v = (4 - weight) * verticalV[x0] + weight * verticalV[x1] - neutral * 16;
            WritePixel(target + x * 4, lumaRow, x, u, v, tenBit, semiplanar, black,
                lumaScale, blueScale, greenUScale, greenVScale, redScale);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void Arm64Pixels(byte* destination, Vector128<int> y, Vector128<int> u,
        Vector128<int> v, Vector128<int> blue, Vector128<int> greenU, Vector128<int> greenV,
        Vector128<int> red, Vector128<int> round, Vector128<int> maximum, Vector128<int> alpha)
    {
        var b = AdvSimd.Min(AdvSimd.Max(AdvSimd.ShiftRightArithmetic(AdvSimd.Add(AdvSimd.Add(y,
            AdvSimd.Multiply(blue, u)), round), FractionBits + 4), Vector128<int>.Zero), maximum);
        var g = AdvSimd.Min(AdvSimd.Max(AdvSimd.ShiftRightArithmetic(AdvSimd.Add(AdvSimd.Add(AdvSimd.Add(y,
            AdvSimd.Multiply(greenU, u)), AdvSimd.Multiply(greenV, v)), round),
            FractionBits + 4), Vector128<int>.Zero), maximum);
        var r = AdvSimd.Min(AdvSimd.Max(AdvSimd.ShiftRightArithmetic(AdvSimd.Add(AdvSimd.Add(y,
            AdvSimd.Multiply(red, v)), round), FractionBits + 4), Vector128<int>.Zero), maximum);
        var bgra = b | (g << 8) | (r << 16) | alpha;
        AdvSimd.Store((int*)destination, bgra);
    }

    private static void VectorRow(byte* target, byte* lumaRow, int* verticalU, int* verticalV,
        int width, int chromaWidth, bool left, bool tenBit, bool semiplanar, int neutral,
        int black, int lumaScale, int blueScale, int greenUScale, int greenVScale, int redScale)
    {
        var lanes = Vector<int>.Count;
        Span<int> work = stackalloc int[lanes * 3];
        var ys = work[..lanes];
        var us = work.Slice(lanes, lanes);
        var vs = work.Slice(lanes * 2, lanes);
        var end = width - lanes;
        var x = 0;
        var blackVector = new Vector<int>(black);
        var lumaVector = new Vector<int>(lumaScale * 16);
        var blueVector = new Vector<int>(blueScale);
        var greenUVector = new Vector<int>(greenUScale);
        var greenVVector = new Vector<int>(greenVScale);
        var redVector = new Vector<int>(redScale);
        var roundVector = new Vector<int>(Round);
        var maxVector = new Vector<int>(255);
        for (; x <= end; x += lanes)
        {
            for (var i = 0; i < lanes; i += 2)
            {
                var cx = (x + i) >> 1;
                var previous = Math.Max(cx - 1, 0);
                var next = Math.Min(cx + 1, chromaWidth - 1);
                us[i] = (left ? 4 * verticalU[cx] : verticalU[previous] + 3 * verticalU[cx]) - neutral * 16;
                vs[i] = (left ? 4 * verticalV[cx] : verticalV[previous] + 3 * verticalV[cx]) - neutral * 16;
                us[i + 1] = (left ? 2 * (verticalU[cx] + verticalU[next]) : 3 * verticalU[cx] + verticalU[next]) - neutral * 16;
                vs[i + 1] = (left ? 2 * (verticalV[cx] + verticalV[next]) : 3 * verticalV[cx] + verticalV[next]) - neutral * 16;
                ys[i] = Read(lumaRow, x + i, tenBit, tenBit && semiplanar);
                ys[i + 1] = Read(lumaRow, x + i + 1, tenBit, tenBit && semiplanar);
            }
            var y = (new Vector<int>(ys) - blackVector) * lumaVector;
            var u = new Vector<int>(us);
            var v = new Vector<int>(vs);
            var b = Vector.Min(Vector.Max((y + blueVector * u + roundVector) >> (FractionBits + 4), Vector<int>.Zero), maxVector);
            var g = Vector.Min(Vector.Max((y + greenUVector * u + greenVVector * v + roundVector) >> (FractionBits + 4), Vector<int>.Zero), maxVector);
            var r = Vector.Min(Vector.Max((y + redVector * v + roundVector) >> (FractionBits + 4), Vector<int>.Zero), maxVector);
            var bgra = b | (g << 8) | (r << 16) | new Vector<int>(unchecked((int)0xff000000));
            Unsafe.WriteUnaligned(target + x * 4, bgra);
        }
        for (; x < width; x++)
        {
            Axis(x, chromaWidth, left, out var x0, out var x1, out var weight);
            var u = (4 - weight) * verticalU[x0] + weight * verticalU[x1] - neutral * 16;
            var v = (4 - weight) * verticalV[x0] + weight * verticalV[x1] - neutral * 16;
            WritePixel(target + x * 4, lumaRow, x, u, v, tenBit, semiplanar, black,
                lumaScale, blueScale, greenUScale, greenVScale, redScale);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void WritePixel(byte* pixel, byte* lumaRow, int x, int u16, int v16,
        bool tenBit, bool semiplanar, int black, int lumaScale, int blueScale,
        int greenUScale, int greenVScale, int redScale)
    {
        var y16 = (Read(lumaRow, x, tenBit, tenBit && semiplanar) - black) * lumaScale * 16;
        pixel[0] = Byte((y16 + blueScale * u16 + Round) >> (FractionBits + 4));
        pixel[1] = Byte((y16 + greenUScale * u16 + greenVScale * v16 + Round) >> (FractionBits + 4));
        pixel[2] = Byte((y16 + redScale * v16 + Round) >> (FractionBits + 4));
        pixel[3] = 255;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void Axis(int coordinate, int count, bool cosited, out int first, out int second, out int weight)
    {
        var quarter = coordinate * 2 - (cosited ? 0 : 1);
        if (quarter <= 0) { first = second = weight = 0; return; }
        first = Math.Min(quarter >> 2, count - 1);
        second = Math.Min(first + 1, count - 1);
        weight = first == second ? 0 : quarter & 3;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int Read(byte* row, int index, bool tenBit, bool p010) =>
        tenBit ? Math.Min(*(ushort*)(row + index * 2) >> (p010 ? 6 : 0), 1023) : row[index];

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static byte Byte(int value) => (byte)Math.Clamp(value, 0, 255);
}
