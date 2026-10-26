using FFmpeg.AutoGen;
using VoxClip.Media.Ffmpeg;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed unsafe class Bt709BgraConverterTests
{
    [Theory]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_NV12)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P10LE)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_P010LE)]
    public void LimitedBt709YellowMatchesIndependentInverseWithPaddedStrides(AVPixelFormat format)
    {
        var frame = stackalloc AVFrame[1];
        frame->width = 4; frame->height = 4; frame->format = (int)format;
        frame->color_range = AVColorRange.AVCOL_RANGE_MPEG;
        frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
        frame->chroma_location = AVChromaLocation.AVCHROMA_LOC_LEFT;
        var tenBit = format is AVPixelFormat.AV_PIX_FMT_YUV420P10LE or AVPixelFormat.AV_PIX_FMT_P010LE;
        var semiplanar = format is AVPixelFormat.AV_PIX_FMT_NV12 or AVPixelFormat.AV_PIX_FMT_P010LE;
        var yPlane = stackalloc byte[64];
        var uPlane = stackalloc byte[32];
        var vPlane = stackalloc byte[32];
        frame->data[0] = yPlane; frame->linesize[0] = 16;
        frame->data[1] = uPlane; frame->linesize[1] = 16;
        if (!semiplanar) { frame->data[2] = vPlane; frame->linesize[2] = 16; }
        for (var y = 0; y < 4; y++)
            for (var x = 0; x < 4; x++)
                Write(yPlane + y * 16, x, 168, tenBit, semiplanar);
        for (var y = 0; y < 2; y++)
            for (var x = 0; x < 2; x++)
            {
                Write(uPlane + y * 16, semiplanar ? x * 2 : x, 44, tenBit, semiplanar);
                Write(semiplanar ? uPlane + y * 16 : vPlane + y * 16,
                    semiplanar ? x * 2 + 1 : x, 136, tenBit, semiplanar);
            }
        var target = stackalloc byte[4 * 20];
        new Span<byte>(target, 4 * 20).Fill(99);
        Bt709BgraConverter.Convert(frame, target, 20);
        for (var y = 0; y < 4; y++)
            for (var x = 0; x < 4; x++)
            {
                var pixel = target + y * 20 + x * 4;
                Assert.Equal((byte)0, pixel[0]);
                Assert.Equal((byte)191, pixel[1]);
                Assert.Equal((byte)191, pixel[2]);
                Assert.Equal((byte)255, pixel[3]);
            }
        Assert.Equal((byte)99, target[16]);
        Assert.Equal((byte)99, target[36]);
    }

    [Fact]
    public void FullRangeAndChromaSitingUseTheDeclaredFrameProperties()
    {
        var frame = stackalloc AVFrame[1];
        frame->width = 4; frame->height = 2; frame->format = (int)AVPixelFormat.AV_PIX_FMT_YUV420P;
        frame->color_range = AVColorRange.AVCOL_RANGE_JPEG;
        frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
        var yPlane = stackalloc byte[8];
        var uPlane = stackalloc byte[2];
        var vPlane = stackalloc byte[2];
        new Span<byte>(yPlane, 8).Fill(128);
        uPlane[0] = 128; uPlane[1] = 192;
        vPlane[0] = vPlane[1] = 128;
        frame->data[0] = yPlane; frame->linesize[0] = 4;
        frame->data[1] = uPlane; frame->linesize[1] = 2;
        frame->data[2] = vPlane; frame->linesize[2] = 2;
        var target = stackalloc byte[32];
        frame->chroma_location = AVChromaLocation.AVCHROMA_LOC_LEFT;
        Bt709BgraConverter.Convert(frame, target, 16);
        Assert.Equal((byte)128, target[0]);
        Assert.Equal((byte)128, target[2]);
        var leftBlue = target[4];
        frame->chroma_location = AVChromaLocation.AVCHROMA_LOC_CENTER;
        Bt709BgraConverter.Convert(frame, target, 16);
        Assert.True(target[4] < leftBlue);
        Assert.Equal((byte)255, target[7]);
    }

    [Fact]
    public void NegativeSourceStridesFollowLogicalRows()
    {
        var frame = stackalloc AVFrame[1];
        frame->width = 2; frame->height = 2; frame->format = (int)AVPixelFormat.AV_PIX_FMT_YUV420P;
        frame->color_range = AVColorRange.AVCOL_RANGE_MPEG;
        frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
        var luma = stackalloc byte[8];
        var chromaU = stackalloc byte[2];
        var chromaV = stackalloc byte[2];
        luma[0] = luma[1] = 16;
        luma[4] = luma[5] = 235;
        chromaU[0] = chromaV[0] = 128;
        frame->data[0] = luma + 4; frame->linesize[0] = -4;
        frame->data[1] = chromaU; frame->linesize[1] = 2;
        frame->data[2] = chromaV; frame->linesize[2] = 2;
        var target = stackalloc byte[16];
        Bt709BgraConverter.Convert(frame, target, 8);
        Assert.Equal((byte)255, target[0]);
        Assert.Equal((byte)0, target[8]);
    }

    [Fact]
    public void PlanarTenBitChromaCodesAbove1023AreClampedBeforeInterpolation()
    {
        var frame = stackalloc AVFrame[1];
        *frame = default;
        frame->width = 8; frame->height = 2; frame->format = (int)AVPixelFormat.AV_PIX_FMT_YUV420P10LE;
        frame->color_range = AVColorRange.AVCOL_RANGE_MPEG;
        frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
        frame->chroma_location = AVChromaLocation.AVCHROMA_LOC_LEFT;
        var luma = stackalloc ushort[16];
        var chromaU = stackalloc ushort[4];
        var chromaV = stackalloc ushort[4];
        for (var i = 0; i < 16; i++) luma[i] = 512;
        for (var i = 0; i < 4; i++) { chromaU[i] = ushort.MaxValue; chromaV[i] = 512; }
        frame->data[0] = (byte*)luma; frame->linesize[0] = 16;
        frame->data[1] = (byte*)chromaU; frame->linesize[1] = 8;
        frame->data[2] = (byte*)chromaV; frame->linesize[2] = 8;
        var actual = stackalloc byte[64];
        var clamped = stackalloc byte[64];
        Bt709BgraConverter.Convert(frame, actual, 32);
        for (var i = 0; i < 4; i++) chromaU[i] = 1023;
        Bt709BgraConverter.Convert(frame, clamped, 32);
        Assert.Equal(new Span<byte>(clamped, 64).ToArray(), new Span<byte>(actual, 64).ToArray());
    }

    [Theory]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P, false, AVChromaLocation.AVCHROMA_LOC_LEFT, false, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P, true, AVChromaLocation.AVCHROMA_LOC_CENTER, true, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUVJ420P, true, AVChromaLocation.AVCHROMA_LOC_TOPLEFT, false, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_NV12, false, AVChromaLocation.AVCHROMA_LOC_CENTER, true, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_NV12, true, AVChromaLocation.AVCHROMA_LOC_LEFT, false, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_NV12, false, AVChromaLocation.AVCHROMA_LOC_UNSPECIFIED, false, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P10LE, false, AVChromaLocation.AVCHROMA_LOC_TOPLEFT, true, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P10LE, true, AVChromaLocation.AVCHROMA_LOC_CENTER, false, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_P010LE, false, AVChromaLocation.AVCHROMA_LOC_LEFT, true, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_P010LE, true, AVChromaLocation.AVCHROMA_LOC_TOPLEFT, false, 19, 9)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P, false, AVChromaLocation.AVCHROMA_LOC_LEFT, false, 32, 6)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_NV12, true, AVChromaLocation.AVCHROMA_LOC_CENTER, false, 32, 6)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_YUV420P10LE, true, AVChromaLocation.AVCHROMA_LOC_LEFT, false, 32, 6)]
    [InlineData(AVPixelFormat.AV_PIX_FMT_P010LE, false, AVChromaLocation.AVCHROMA_LOC_TOPLEFT, true, 32, 6)]
    public void VariedFramesMatchDoubleOracleAndScalarExactly(
        AVPixelFormat format, bool full, AVChromaLocation location, bool negativeStride, int width, int height)
    {
        var chromaWidth = (width + 1) / 2;
        var chromaHeight = (height + 1) / 2;
        var tenBit = format is AVPixelFormat.AV_PIX_FMT_YUV420P10LE or AVPixelFormat.AV_PIX_FMT_P010LE;
        var semiplanar = format is AVPixelFormat.AV_PIX_FMT_NV12 or AVPixelFormat.AV_PIX_FMT_P010LE;
        var max = tenBit ? 1023 : 255;
        var ys = new int[width * height];
        var us = new int[chromaWidth * chromaHeight];
        var vs = new int[us.Length];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
                ys[y * width + x] = (x + y) % 7 == 0 ? 0 : (x * 139 + y * 97 + x * y * 31) % (max + 1);
        for (var y = 0; y < chromaHeight; y++)
            for (var x = 0; x < chromaWidth; x++)
            {
                us[y * chromaWidth + x] = (x + y) % 5 == 0 ? max : (x * 79 + y * 191 + 9) % (max + 1);
                vs[y * chromaWidth + x] = (x + y) % 4 == 0 ? 0 : (x * 149 + y * 71 + 27) % (max + 1);
            }
        var sampleBytes = tenBit ? 2 : 1;
        var yStride = width * sampleBytes + 7;
        var uStride = chromaWidth * sampleBytes * (semiplanar ? 2 : 1) + 9;
        var vStride = chromaWidth * sampleBytes + 5;
        var yPlane = new byte[yStride * height];
        var uPlane = new byte[uStride * chromaHeight];
        var vPlane = new byte[vStride * chromaHeight];
        var targetStride = width * 4 + 11;
        var accelerated = new byte[targetStride * height];
        var scalar = new byte[accelerated.Length];
        accelerated.AsSpan().Fill(77);
        scalar.AsSpan().Fill(77);
        fixed (byte* py = yPlane, pu = uPlane, pv = vPlane, pa = accelerated, ps = scalar)
        {
            var frame = stackalloc AVFrame[1];
            frame->width = width; frame->height = height; frame->format = (int)format;
            frame->color_range = full ? AVColorRange.AVCOL_RANGE_JPEG : AVColorRange.AVCOL_RANGE_MPEG;
            frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
            frame->chroma_location = location;
            frame->linesize[0] = negativeStride ? -yStride : yStride;
            frame->linesize[1] = negativeStride ? -uStride : uStride;
            frame->linesize[2] = negativeStride ? -vStride : vStride;
            frame->data[0] = py + (negativeStride ? (height - 1) * yStride : 0);
            frame->data[1] = pu + (negativeStride ? (chromaHeight - 1) * uStride : 0);
            frame->data[2] = semiplanar ? null : pv + (negativeStride ? (chromaHeight - 1) * vStride : 0);
            for (var y = 0; y < height; y++)
                for (var x = 0; x < width; x++)
                    WriteCode(frame->data[0] + y * frame->linesize[0], x, ys[y * width + x], tenBit, semiplanar);
            for (var y = 0; y < chromaHeight; y++)
                for (var x = 0; x < chromaWidth; x++)
                {
                    WriteCode(frame->data[1] + y * frame->linesize[1], semiplanar ? x * 2 : x,
                        us[y * chromaWidth + x], tenBit, semiplanar);
                    WriteCode((semiplanar ? frame->data[1] : frame->data[2]) +
                        y * (semiplanar ? frame->linesize[1] : frame->linesize[2]),
                        semiplanar ? x * 2 + 1 : x, vs[y * chromaWidth + x], tenBit, semiplanar);
                }
            Bt709BgraConverter.Convert(frame, pa, targetStride);
            Bt709BgraConverter.ConvertScalar(frame, ps, targetStride);
        }
        Assert.Equal(scalar, accelerated);
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var chromaX = location is AVChromaLocation.AVCHROMA_LOC_LEFT or AVChromaLocation.AVCHROMA_LOC_TOPLEFT
                    ? x / 2.0 : (x - .5) / 2;
                var chromaY = location == AVChromaLocation.AVCHROMA_LOC_TOPLEFT ? y / 2.0 : (y - .5) / 2;
                var u = Bilinear(us, chromaWidth, chromaHeight, chromaX, chromaY);
                var v = Bilinear(vs, chromaWidth, chromaHeight, chromaX, chromaY);
                var luma = (ys[y * width + x] - (full ? 0 : tenBit ? 64 : 16)) *
                    255.0 / (full ? max : tenBit ? 876 : 219);
                var chromaScale = 255.0 / (full ? max : tenBit ? 896 : 224);
                var cb = (u - (tenBit ? 512 : 128)) * chromaScale;
                var cr = (v - (tenBit ? 512 : 128)) * chromaScale;
                var expected = new[]
                {
                    Clamp(luma + 2 * (1 - .0722) * cb),
                    Clamp(luma - 2 * .0722 * (1 - .0722) / (1 - .2126 - .0722) * cb -
                        2 * .2126 * (1 - .2126) / (1 - .2126 - .0722) * cr),
                    Clamp(luma + 2 * (1 - .2126) * cr), (byte)255
                };
                for (var channel = 0; channel < 4; channel++)
                    Assert.InRange(Math.Abs(accelerated[y * targetStride + x * 4 + channel] - expected[channel]), 0, 1);
            }
        for (var y = 0; y < height; y++)
            Assert.All(accelerated.AsSpan(y * targetStride + width * 4, 11).ToArray(), b => Assert.Equal((byte)77, b));
    }

    [Fact]
    public void UnsupportedMatrixSitingAndInterlaceUseFallback()
    {
        var frame = stackalloc AVFrame[1];
        frame->format = (int)AVPixelFormat.AV_PIX_FMT_NV12;
        frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
        frame->chroma_location = AVChromaLocation.AVCHROMA_LOC_LEFT;
        Assert.True(Bt709BgraConverter.Supports(frame));
        frame->colorspace = AVColorSpace.AVCOL_SPC_SMPTE170M;
        Assert.False(Bt709BgraConverter.Supports(frame));
        Assert.Equal(ffmpeg.SWS_CS_ITU601, Native.SourceMatrix(frame->colorspace));
        Assert.Equal(ffmpeg.SWS_CS_FCC, Native.SourceMatrix(AVColorSpace.AVCOL_SPC_FCC));
        Assert.Equal(ffmpeg.SWS_CS_BT2020, Native.SourceMatrix(AVColorSpace.AVCOL_SPC_BT2020_NCL));
        frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
        foreach (var location in new[] { AVChromaLocation.AVCHROMA_LOC_TOP,
            AVChromaLocation.AVCHROMA_LOC_BOTTOMLEFT, AVChromaLocation.AVCHROMA_LOC_BOTTOM })
        {
            frame->chroma_location = location;
            Assert.False(Bt709BgraConverter.Supports(frame));
        }
        frame->chroma_location = AVChromaLocation.AVCHROMA_LOC_LEFT;
        frame->flags = ffmpeg.AV_FRAME_FLAG_INTERLACED;
        Assert.False(Bt709BgraConverter.Supports(frame));
    }

    private static double Bilinear(int[] values, int width, int height, double x, double y)
    {
        x = Math.Clamp(x, 0, width - 1); y = Math.Clamp(y, 0, height - 1);
        var x0 = (int)Math.Floor(x); var y0 = (int)Math.Floor(y);
        var x1 = Math.Min(x0 + 1, width - 1); var y1 = Math.Min(y0 + 1, height - 1);
        var top = values[y0 * width + x0] * (1 - (x - x0)) + values[y0 * width + x1] * (x - x0);
        var bottom = values[y1 * width + x0] * (1 - (x - x0)) + values[y1 * width + x1] * (x - x0);
        return top * (1 - (y - y0)) + bottom * (y - y0);
    }

    private static byte Clamp(double value) => (byte)Math.Clamp(Math.Floor(value + .5), 0, 255);

    private static void WriteCode(byte* row, int index, int code, bool tenBit, bool p010)
    {
        if (tenBit) *(ushort*)(row + index * 2) = (ushort)(code << (p010 ? 6 : 0));
        else row[index] = (byte)code;
    }

    private static void Write(byte* row, int index, int eightBitValue, bool tenBit, bool p010)
    {
        if (tenBit) *(ushort*)(row + index * 2) = (ushort)(eightBitValue * 4 << (p010 ? 6 : 0));
        else row[index] = (byte)eightBitValue;
    }
}
