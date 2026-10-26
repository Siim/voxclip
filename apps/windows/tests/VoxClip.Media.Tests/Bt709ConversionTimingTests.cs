using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using FFmpeg.AutoGen;
using VoxClip.Media.Ffmpeg;
using Xunit;

namespace VoxClip.Media.Tests;

public sealed class Bt709ConversionTimingTests
{
    private unsafe delegate void ConvertFrame(AVFrame* frame, byte* destination, int stride);

    [Fact]
    public async Task ReportIsolatedConversionTimings()
    {
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_CONVERSION_TIMING") == "1",
            "Set VOXCLIP_CONVERSION_TIMING=1 for the isolated conversion timing diagnostic.");
        if (OperatingSystem.IsWindows()) await NativeTest.RequireAsync(windows: true);
        Measure();
    }

    private static unsafe void Measure()
    {
        TestContext.Current.TestOutputHelper!.WriteLine($"Conversion timing: process={RuntimeInformation.ProcessArchitecture}, host={RuntimeInformation.OSArchitecture}, vectorLanes={Vector<int>.Count}, vectorAccelerated={Vector.IsHardwareAccelerated}, avx2={System.Runtime.Intrinsics.X86.Avx2.IsSupported}, advSimdArm64={System.Runtime.Intrinsics.Arm.AdvSimd.Arm64.IsSupported}");
        var frame = stackalloc AVFrame[1];
        foreach (var format in new[] { AVPixelFormat.AV_PIX_FMT_NV12, AVPixelFormat.AV_PIX_FMT_YUV420P,
            AVPixelFormat.AV_PIX_FMT_P010LE, AVPixelFormat.AV_PIX_FMT_YUV420P10LE })
        foreach (var (width, height) in new[] { (1920, 1080), (3840, 2160) })
        {
            var tenBit = format is AVPixelFormat.AV_PIX_FMT_P010LE or AVPixelFormat.AV_PIX_FMT_YUV420P10LE;
            var semiplanar = format is AVPixelFormat.AV_PIX_FMT_NV12 or AVPixelFormat.AV_PIX_FMT_P010LE;
            var sampleBytes = tenBit ? 2 : 1;
            var luma = new byte[width * height * sampleBytes];
            var chroma = new byte[width * height / 2 * sampleBytes];
            var vPlane = new byte[width * height / 4 * sampleBytes];
            var output = new byte[width * height * 4];
            fixed (byte* y = luma, uv = chroma, v = vPlane, bgra = output)
            {
                if (tenBit)
                {
                    var shift = semiplanar ? 6 : 0;
                    for (var i = 0; i < luma.Length / 2; i++) ((ushort*)y)[i] = (ushort)((64 + i * 73 % 877) << shift);
                    for (var i = 0; i < chroma.Length / 2; i++) ((ushort*)uv)[i] = (ushort)((128 + i * 47 % 769) << shift);
                    for (var i = 0; i < vPlane.Length / 2; i++) ((ushort*)v)[i] = (ushort)(128 + i * 67 % 769);
                }
                else
                {
                    for (var i = 0; i < luma.Length; i++) y[i] = (byte)(16 + i * 73 % 220);
                    for (var i = 0; i < chroma.Length; i++) uv[i] = (byte)(32 + i * 47 % 190);
                    for (var i = 0; i < vPlane.Length; i++) v[i] = (byte)(32 + i * 67 % 190);
                }
                *frame = default;
                frame->format = (int)format;
                frame->width = width; frame->height = height;
                frame->color_range = AVColorRange.AVCOL_RANGE_MPEG;
                frame->colorspace = AVColorSpace.AVCOL_SPC_BT709;
                frame->chroma_location = AVChromaLocation.AVCHROMA_LOC_LEFT;
                frame->data[0] = y; frame->data[1] = uv;
                frame->data[2] = semiplanar ? null : v;
                frame->linesize[0] = width * sampleBytes;
                frame->linesize[1] = (semiplanar ? width : width / 2) * sampleBytes;
                frame->linesize[2] = width / 2 * sampleBytes;
                foreach (var (name, convert) in new (string, ConvertFrame)[]
                    { ("scalar", Bt709BgraConverter.ConvertScalar), ("accelerated", Bt709BgraConverter.Convert) })
                {
                    for (var warm = 0; warm < 8; warm++) convert(frame, bgra, width * 4);
                    var samples = new double[12];
                    var before = GC.GetAllocatedBytesForCurrentThread();
                    for (var i = 0; i < samples.Length; i++)
                    {
                        var start = Stopwatch.GetTimestamp();
                        convert(frame, bgra, width * 4);
                        samples[i] = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
                    }
                    var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
                    TestContext.Current.TestOutputHelper!.WriteLine($"BT709 {format} {name} {width}x{height}: {Summary(samples, allocated)}");
                }
                var precise = width == 1920 && Environment.GetEnvironmentVariable("VOXCLIP_NATIVE_CONVERSION_PROBE") == "1"
                    ? output.ToArray() : null;
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows) &&
                    Environment.GetEnvironmentVariable("VOXCLIP_FFMPEG_DIR") is not null)
                {
                    var context = ffmpeg.sws_getContext(width, height, format,
                        width, height, AVPixelFormat.AV_PIX_FMT_BGRA, (int)SwsFlags.SWS_BILINEAR,
                        null, null, null);
                    Assert.NotEqual((nint)0, (nint)context);
                    try
                    {
                        Native.Colors(context);
                        var source = new byte_ptrArray4(); source[0] = y; source[1] = uv; source[2] = frame->data[2];
                        var sourceStrides = new int_array4(); sourceStrides[0] = frame->linesize[0];
                        sourceStrides[1] = frame->linesize[1]; sourceStrides[2] = frame->linesize[2];
                        var destination = new byte_ptrArray4(); destination[0] = bgra;
                        var destinationStrides = new int_array4(); destinationStrides[0] = width * 4;
                        for (var warm = 0; warm < 8; warm++)
                            ffmpeg.sws_scale(context, source, sourceStrides, 0, height, destination, destinationStrides);
                        var samples = new double[12];
                        var before = GC.GetAllocatedBytesForCurrentThread();
                        var rows = 0;
                        for (var i = 0; i < samples.Length; i++)
                        {
                            var start = Stopwatch.GetTimestamp();
                            rows = ffmpeg.sws_scale(context, source, sourceStrides, 0, height,
                                destination, destinationStrides);
                            samples[i] = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
                        }
                        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
                        Assert.Equal(height, rows);
                        TestContext.Current.TestOutputHelper!.WriteLine($"BT709 {format} native swscale {width}x{height}: {Summary(samples, allocated)}");
                        if (precise is not null)
                        {
                            Compare($"{format} bilinear", precise, output);
                            foreach (var flags in new[]
                            {
                                SwsFlags.SWS_BILINEAR | SwsFlags.SWS_ACCURATE_RND,
                                SwsFlags.SWS_BILINEAR | SwsFlags.SWS_BITEXACT,
                                SwsFlags.SWS_BILINEAR | SwsFlags.SWS_ACCURATE_RND | SwsFlags.SWS_BITEXACT,
                                SwsFlags.SWS_BILINEAR | SwsFlags.SWS_FULL_CHR_H_INT | SwsFlags.SWS_ACCURATE_RND
                            })
                            {
                                var candidate = ffmpeg.sws_getContext(width, height, format, width, height,
                                    AVPixelFormat.AV_PIX_FMT_BGRA, (int)flags, null, null, null);
                                Assert.NotEqual((nint)0, (nint)candidate);
                                try
                                {
                                    Native.Colors(candidate);
                                    Assert.Equal(height, ffmpeg.sws_scale(candidate, source, sourceStrides, 0, height,
                                        destination, destinationStrides));
                                    Compare($"{format} {flags}", precise, output);
                                }
                                finally { ffmpeg.sws_freeContext(candidate); }
                            }
                        }
                    }
                    finally { ffmpeg.sws_freeContext(context); }
                }
            }
        }
    }

    private static string Summary(double[] samples, long allocated)
    {
        Array.Sort(samples);
        var median = (samples[5] + samples[6]) / 2;
        return $"n={samples.Length}, min={samples[0]:F2}, median={median:F2}, p95={samples[11]:F2}, " +
            $"max={samples[11]:F2} ms/frame, {allocated / samples.Length} B/frame managed allocation";
    }

    private static void Compare(string name, byte[] precise, byte[] native)
    {
        var different = 0L;
        var max = 0;
        var total = 0L;
        for (var i = 0; i < precise.Length; i++)
        {
            if ((i & 3) == 3) continue;
            var delta = Math.Abs(precise[i] - native[i]);
            if (delta != 0) different++;
            max = Math.Max(max, delta);
            total += delta;
        }
        TestContext.Current.TestOutputHelper!.WriteLine($"Native comparison {name}: {different}/{precise.Length / 4 * 3} RGB channels differ; max={max}, mean={total * 4.0 / (precise.Length * 3):F3}");
    }
}
