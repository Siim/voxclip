using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text.Json;
using FFmpeg.AutoGen;
using VoxClip.Media.Ffmpeg;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.E2E;

/// <summary>Opt-in comparison of native decode and swscale CPU paths on the unchanged canonical bars.</summary>
[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class ColorPathDiagnostics
{
    [Fact]
    public async Task CompareDecodedYuvAndScalerCpuPaths()
    {
        Assert.SkipUnless(Environment.GetEnvironmentVariable("VOXCLIP_DIAGNOSE_COLOR_PATHS") == "1",
            "Set VOXCLIP_DIAGNOSE_COLOR_PATHS=1 for this isolated native diagnostic.");
        await NativeTest.RequireAsync(windows: true);
        var source = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "bars-1080p.mp4");
        var rows = await MediaThread.Run("vc-x64-colour-paths", () => Measure(source), TestContext.Current.CancellationToken);
        var architecture = RuntimeInformation.ProcessArchitecture.ToString();
        var json = JsonSerializer.Serialize(new { architecture, samples = rows }, new JsonSerializerOptions { WriteIndented = true });
        TestContext.Current.TestOutputHelper!.WriteLine(json);
        var output = Environment.GetEnvironmentVariable("VOXCLIP_E2E_OUT");
        if (!string.IsNullOrWhiteSpace(output))
        {
            Directory.CreateDirectory(output);
            File.WriteAllText(Path.Combine(output, $"color-paths-{architecture.ToLowerInvariant()}.json"), json);
        }
    }

    private static IReadOnlyList<object> Measure(string source)
    {
        var originalFlags = ffmpeg.av_get_cpu_flags();
        try
        {
            var accelerated = Read(source, originalFlags, compareScalarOnSameFrame: true);
            ffmpeg.av_force_cpu_flags(0);
            var scalarDecode = Read(source, 0, compareScalarOnSameFrame: false);
            return accelerated.Zip(scalarDecode, (fast, scalar) => (object)new
            {
                fast.Frame, fast.Bar, fast.RawYuv, fast.Bgra,
                scalarOnSameDecodedFrame = fast.ScalarBgra,
                fullChromaOnSameDecodedFrame = fast.FullChromaBgra,
                rgb48OnSameDecodedFrame = fast.Rgb48Bgra,
                scalarDecodedYuv = scalar.RawYuv,
                scalarDecodedBgra = scalar.Bgra
            }).ToArray();
        }
        finally { ffmpeg.av_force_cpu_flags(originalFlags); }
    }

    private static unsafe List<Sample> Read(string source, int originalFlags, bool compareScalarOnSameFrame)
    {
        using var decoder = new DecodeSession(source, AVMediaType.AVMEDIA_TYPE_VIDEO);
        var rows = new List<Sample>();
        for (var frameIndex = 0; frameIndex <= 30 && decoder.Next(TestContext.Current.CancellationToken); frameIndex++)
        {
            if (frameIndex is not (9 or 15 or 30)) continue;
            var frame = decoder.Frame;
            Assert.Equal(AVPixelFormat.AV_PIX_FMT_YUV420P, (AVPixelFormat)frame->format);
            foreach (var bar in new[] { 1, 3 })
            {
                var x = bar * 240 + 60;
                const int y = 300;
                var raw = new Yuv(frame->data[0][y * frame->linesize[0] + x],
                    frame->data[1][(y / 2) * frame->linesize[1] + x / 2],
                    frame->data[2][(y / 2) * frame->linesize[2] + x / 2]);
                var bgra = Convert(frame, x, y);
                Rgb? scalar = null;
                Rgb? fullChroma = null;
                Rgb? rgb48 = null;
                if (compareScalarOnSameFrame)
                {
                    fullChroma = Convert(frame, x, y, SwsFlags.SWS_BILINEAR | SwsFlags.SWS_FULL_CHR_H_INT);
                    rgb48 = ConvertRgb48(frame, x, y);
                    ffmpeg.av_force_cpu_flags(0);
                    try { scalar = Convert(frame, x, y); }
                    finally { ffmpeg.av_force_cpu_flags(originalFlags); }
                }
                rows.Add(new(frameIndex, bar, raw, bgra, scalar, fullChroma, rgb48));
            }
        }
        Assert.Equal(6, rows.Count);
        return rows;
    }

    private static unsafe Rgb Convert(AVFrame* frame, int x, int y, SwsFlags flags = SwsFlags.SWS_BILINEAR)
    {
        using var scaler = NativeHandle.Own(ffmpeg.sws_getContext(frame->width, frame->height,
            (AVPixelFormat)frame->format, frame->width, frame->height, AVPixelFormat.AV_PIX_FMT_BGRA,
            (int)flags, null, null, null), NativeKind.Scale);
        Native.Colors((SwsContext*)scaler.Pointer, frame->color_range == AVColorRange.AVCOL_RANGE_JPEG);
        var pixels = new byte[checked(frame->width * frame->height * 4)];
        fixed (byte* output = pixels)
        {
            var planes = new byte_ptrArray4(); planes[0] = output;
            var strides = new int_array4(); strides[0] = frame->width * 4;
            Assert.Equal(frame->height, ffmpeg.sws_scale((SwsContext*)scaler.Pointer, frame->data,
                frame->linesize, 0, frame->height, planes, strides));
        }
        var offset = (y * frame->width + x) * 4;
        return new(pixels[offset + 2], pixels[offset + 1], pixels[offset]);
    }

    private static unsafe Rgb ConvertRgb48(AVFrame* frame, int x, int y)
    {
        using var scaler = NativeHandle.Own(ffmpeg.sws_getContext(frame->width, frame->height,
            (AVPixelFormat)frame->format, frame->width, frame->height, AVPixelFormat.AV_PIX_FMT_RGB48LE,
            (int)SwsFlags.SWS_BILINEAR, null, null, null), NativeKind.Scale);
        Native.Colors((SwsContext*)scaler.Pointer, frame->color_range == AVColorRange.AVCOL_RANGE_JPEG);
        var pixels = new byte[checked(frame->width * frame->height * 6)];
        fixed (byte* output = pixels)
        {
            var planes = new byte_ptrArray4(); planes[0] = output;
            var strides = new int_array4(); strides[0] = frame->width * 6;
            Assert.Equal(frame->height, ffmpeg.sws_scale((SwsContext*)scaler.Pointer, frame->data,
                frame->linesize, 0, frame->height, planes, strides));
        }
        var offset = (y * frame->width + x) * 6;
        return new(ToByte(pixels.AsSpan(offset, 2)), ToByte(pixels.AsSpan(offset + 2, 2)),
            ToByte(pixels.AsSpan(offset + 4, 2)));
    }

    private static int ToByte(ReadOnlySpan<byte> channel) =>
        (BinaryPrimitives.ReadUInt16LittleEndian(channel) + 128) / 257;

    private sealed record Sample(int Frame, int Bar, Yuv RawYuv, Rgb Bgra, Rgb? ScalarBgra,
        Rgb? FullChromaBgra, Rgb? Rgb48Bgra);
    private sealed record Yuv(int Y, int U, int V);
    private sealed record Rgb(int R, int G, int B);
}
