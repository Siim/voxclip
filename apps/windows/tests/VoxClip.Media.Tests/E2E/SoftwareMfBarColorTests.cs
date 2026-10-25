using System.Text;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.E2E;

[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class SoftwareMfBarColorTests
{
    private static readonly int[] Frames = [9, 15, 30];
    private static readonly (int X, int Y)[] Positions = [(60, 300), (120, 500), (180, 700)];
    private static readonly Rgb[] Expected = [new(191, 191, 191), new(191, 191, 0), new(0, 191, 191),
        new(0, 191, 0), new(191, 0, 191), new(191, 0, 0), new(0, 0, 191), new(0, 0, 0)];

    [Fact]
    public async Task MeasureProductionComposeAndSoftwareEncoderAcrossAllBars()
    {
        await NativeTest.RequireAsync(windows: true);
        var source = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media", "bars-1080p.mp4");
        Assert.True(File.Exists(source));
        var media = await new FfmpegMediaProbe().ProbeAsync(source, TestContext.Current.CancellationToken);
        var samples = checked((long)Math.Round(media.DurationSeconds * 48_000));
        var plan = TestPlan.FromKept(48_000, samples, [new(0, samples)]);
        var snapshot = new ComposeSnapshot(media, plan, null, new(new(1920, 1080), 30, 8_000_000));
        var directory = Directory.CreateTempSubdirectory("voxclip-bars-").FullName;
        var output = Path.Combine(directory, "bars.mp4");
        var captured = new Dictionary<(int Frame, int Bar, int Position), Sample>();
        try
        {
            var exporter = CreateExporter(captured);
            var result = await exporter.ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source,
                ExportQuality.Standard, output, null), null, TestContext.Current.CancellationToken);
            Assert.Equal(EncoderProbe.SoftwareMediaFoundation, result.Encoder);
            Assert.Equal(72, captured.Count);

            var (report, failures) = BuildReport(output, captured);
            var path = Path.Combine(Environment.GetEnvironmentVariable("VOXCLIP_E2E_OUT") ?? directory, "e2e-8-bars-measurements.csv");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, report);
            Assert.Equal(72, report.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length - 1);
            Assert.True(failures.Count == 0, $"Software MF bar colour contract failed in {failures.Count} checks. Full measurements: {path}\n{string.Join("\n", failures)}");
        }
        finally { Directory.Delete(directory, true); }
    }

    private static unsafe Exporter CreateExporter(Dictionary<(int Frame, int Bar, int Position), Sample> captured)
        => new(new FrameComposer(), new SoftwareOnlyProbe(), frameObserver: (index, decoded, composed, nv12) =>
        {
            if (!Frames.Contains((int)index)) return;
            var roundtrip = RoundTrip(nv12);
            for (var bar = 0; bar < 8; bar++)
                for (var position = 0; position < Positions.Length; position++)
                {
                    var (withinBar, y) = Positions[position];
                    var x = bar * 240 + withinBar;
                    captured[((int)index, bar, position)] = new(
                        RgbAt(decoded, x, y), RgbAt(composed, x, y), RgbAt(roundtrip, x, y),
                        YuvAt(nv12, x, y));
                }
        });

    private static unsafe (string Report, List<string> Failures) BuildReport(string output, Dictionary<(int Frame, int Bar, int Position), Sample> captured)
    {
            var report = new StringBuilder("frame,time,bar,position,x,y,expectedRGB,sourceRGB,composedRGB,preEncodeRGB,preEncodeYUV,decodedYUV,decodedRGB,profile,pixelFormat,primaries,transfer,matrix,range\n");
            var failures = new List<string>();
            using var raw = new DecodeSession(output, AVMediaType.AVMEDIA_TYPE_VIDEO);
            using var rgb = new VideoDecoder(output, false);
            var frameIndex = 0;
            while (raw.Next(TestContext.Current.CancellationToken))
            {
                if (Frames.Contains(frameIndex))
                {
                    var image = rgb.ReadAt(frameIndex / 30.0, true, TestContext.Current.CancellationToken);
                    for (var bar = 0; bar < 8; bar++)
                        for (var position = 0; position < Positions.Length; position++)
                        {
                            var (withinBar, y) = Positions[position];
                            var x = bar * 240 + withinBar;
                            var sample = captured[(frameIndex, bar, position)];
                            var decodedYuv = YuvAt(raw.Frame, x, y);
                            var decodedRgb = RgbAt(image, x, y);
                            var metadata = new Metadata(raw.Codec->profile, (AVPixelFormat)raw.Frame->format,
                                raw.Frame->color_primaries, raw.Frame->color_trc, raw.Frame->colorspace, raw.Frame->color_range);
                            foreach (var failure in CheckSample(Expected[bar], sample.PreEncodeRgb, sample.PreEncodeYuv,
                                decodedYuv, decodedRgb, metadata))
                                failures.Add($"frame {frameIndex}, bar {bar}, position {position} ({x},{y}): {failure}");
                            report.Append(frameIndex).Append(',').Append(frameIndex / 30.0).Append(',')
                                .Append(bar).Append(',').Append(position).Append(',').Append(x).Append(',').Append(y).Append(',')
                                .Append(Expected[bar]).Append(',').Append(sample.Source).Append(',').Append(sample.Composed).Append(',')
                                .Append(sample.PreEncodeRgb).Append(',').Append(sample.PreEncodeYuv).Append(',')
                                .Append(decodedYuv).Append(',').Append(decodedRgb).Append(',')
                                .Append(raw.Codec->profile).Append(',').Append((AVPixelFormat)raw.Frame->format).Append(',')
                                .Append(raw.Frame->color_primaries).Append(',').Append(raw.Frame->color_trc).Append(',')
                                .Append(raw.Frame->colorspace).Append(',').Append(raw.Frame->color_range).AppendLine();
                        }
                }
                frameIndex++;
            }
            return (report.ToString(), failures);
    }

    [Fact]
    public void IndependentCoefficientAndRangeMutantsFailTheSoftwareContract()
    {
        var metadata = new Metadata(100, AVPixelFormat.AV_PIX_FMT_YUV420P, AVColorPrimaries.AVCOL_PRI_BT709,
            AVColorTransferCharacteristic.AVCOL_TRC_BT709, AVColorSpace.AVCOL_SPC_BT709, AVColorRange.AVCOL_RANGE_MPEG);
        var green = Expected[3];
        var before = new Yuv(133, 64, 52);
        Assert.Empty(CheckSample(green, new(0, 190, 1), before, new(134, 65, 52), new(1, 191, 4), metadata));
        var bt601 = PredictLimited(green, .299, .587, .114);
        Assert.Contains(CheckSample(green, new(0, 190, 1), bt601, bt601, new(0, 190, 1), metadata),
            failure => failure.Contains("BT.709 coefficients", StringComparison.Ordinal));
        Assert.Contains(CheckSample(Expected[7], new(0, 0, 0), new(0, 128, 128), new(0, 128, 128),
            new(0, 0, 0), metadata), failure => failure.Contains("BT.709 coefficients", StringComparison.Ordinal));
        Assert.Contains(CheckSample(green, new(0, 190, 1), before, new(135, 65, 52), new(2, 192, 5), metadata),
            failure => failure.Contains("YUV delta", StringComparison.Ordinal));
        Assert.Contains(CheckSample(green, new(0, 190, 1), before, new(134, 65, 52), new(1, 191, 4),
            metadata with { Matrix = AVColorSpace.AVCOL_SPC_BT470BG }), failure => failure.Contains("metadata", StringComparison.Ordinal));
        Assert.Contains(CheckSample(green, new(0, 190, 1), before, new(134, 65, 52), new(1, 191, 4),
            metadata with { Range = AVColorRange.AVCOL_RANGE_JPEG }), failure => failure.Contains("metadata", StringComparison.Ordinal));
    }

    private static List<string> CheckSample(Rgb expected, Rgb preRgb, Yuv before, Yuv after, Rgb decodedRgb, Metadata metadata)
    {
        var failures = new List<string>();
        if (MaxDelta(expected, preRgb) > 3) failures.Add($"preencoder RGB delta >3: expected {expected}, actual {preRgb}");
        var independent = PredictLimited(expected, .2126, .7152, .0722);
        if (MaxDelta(independent, before) > 3) failures.Add($"preencoder YUV differs from independent BT.709 coefficients: expected approximately {independent}, actual {before}");
        if (MaxDelta(before, after) > 1) failures.Add($"postcodec YUV delta >1: before {before}, after {after}");
        if (metadata != new Metadata(100, AVPixelFormat.AV_PIX_FMT_YUV420P, AVColorPrimaries.AVCOL_PRI_BT709,
            AVColorTransferCharacteristic.AVCOL_TRC_BT709, AVColorSpace.AVCOL_SPC_BT709, AVColorRange.AVCOL_RANGE_MPEG))
            failures.Add($"H.264 colour metadata mismatch: {metadata}");
        var inverse = InverseBt709(after);
        if (!double.IsFinite(inverse.R) || !double.IsFinite(inverse.G) || !double.IsFinite(inverse.B) ||
            Math.Abs(inverse.R - decodedRgb.R) > 2 || Math.Abs(inverse.G - decodedRgb.G) > 2 || Math.Abs(inverse.B - decodedRgb.B) > 2)
            failures.Add($"decoded RGB diagnostic differs from finite BT.709 inverse: YUV {after}, RGB {decodedRgb}, inverse {inverse}");
        return failures;
    }

    private static Yuv PredictLimited(Rgb rgb, double kr, double kg, double kb)
    {
        var luma = kr * rgb.R + kg * rgb.G + kb * rgb.B;
        return new((int)Math.Round(16 + 219 * luma / 255),
            (int)Math.Round(128 + 112 * (rgb.B - luma) / ((1 - kb) * 255)),
            (int)Math.Round(128 + 112 * (rgb.R - luma) / ((1 - kr) * 255)));
    }

    private static (double R, double G, double B) InverseBt709(Yuv yuv)
    {
        var y = yuv.Y - 16;
        var u = yuv.U - 128;
        var v = yuv.V - 128;
        return (Math.Clamp(1.164383 * y + 1.792741 * v, 0, 255),
            Math.Clamp(1.164383 * y - .213249 * u - .532909 * v, 0, 255),
            Math.Clamp(1.164383 * y + 2.112402 * u, 0, 255));
    }

    private static int MaxDelta(Rgb left, Rgb right) => Math.Max(Math.Abs(left.R - right.R), Math.Max(Math.Abs(left.G - right.G), Math.Abs(left.B - right.B)));
    private static int MaxDelta(Yuv left, Yuv right) => Math.Max(Math.Abs(left.Y - right.Y), Math.Max(Math.Abs(left.U - right.U), Math.Abs(left.V - right.V)));

    private static unsafe byte[] RoundTrip(AVFrame* nv12)
    {
        using var reverse = NativeHandle.Own(ffmpeg.sws_getContext(nv12->width, nv12->height, AVPixelFormat.AV_PIX_FMT_NV12,
            nv12->width, nv12->height, AVPixelFormat.AV_PIX_FMT_BGRA, (int)SwsFlags.SWS_BILINEAR, null, null, null), NativeKind.Scale);
        Native.Colors((SwsContext*)reverse.Pointer);
        var result = new byte[checked(nv12->width * nv12->height * 4)];
        fixed (byte* pixels = result)
        {
            var target = new byte_ptrArray4(); target[0] = pixels;
            var strides = new int_array4(); strides[0] = nv12->width * 4;
            Assert.Equal(nv12->height, ffmpeg.sws_scale((SwsContext*)reverse.Pointer, nv12->data, nv12->linesize,
                0, nv12->height, target, strides));
        }
        return result;
    }

    private static Rgb RgbAt(PixelBuffer buffer, int x, int y)
    {
        var pixel = buffer.Pixels.Span.Slice(y * buffer.Stride + x * 4, 4);
        return new(pixel[2], pixel[1], pixel[0]);
    }

    private static Rgb RgbAt(byte[] buffer, int x, int y)
    {
        var offset = (y * 1920 + x) * 4;
        return new(buffer[offset + 2], buffer[offset + 1], buffer[offset]);
    }

    private static unsafe Yuv YuvAt(AVFrame* frame, int x, int y)
    {
        var format = (AVPixelFormat)frame->format;
        var luma = frame->data[0][y * frame->linesize[0] + x];
        var u = format == AVPixelFormat.AV_PIX_FMT_NV12
            ? frame->data[1][(y / 2) * frame->linesize[1] + x]
            : frame->data[1][(y / 2) * frame->linesize[1] + x / 2];
        var v = format == AVPixelFormat.AV_PIX_FMT_NV12
            ? frame->data[1][(y / 2) * frame->linesize[1] + x + 1]
            : frame->data[2][(y / 2) * frame->linesize[2] + x / 2];
        return new(luma, u, v);
    }

    private readonly record struct Rgb(int R, int G, int B)
    {
        public override string ToString() => $"{R}/{G}/{B}";
    }

    private readonly record struct Yuv(int Y, int U, int V)
    {
        public override string ToString() => $"{Y}/{U}/{V}";
    }

    private readonly record struct Sample(Rgb Source, Rgb Composed, Rgb PreEncodeRgb, Yuv PreEncodeYuv);
    private readonly record struct Metadata(int Profile, AVPixelFormat Format, AVColorPrimaries Primaries,
        AVColorTransferCharacteristic Transfer, AVColorSpace Matrix, AVColorRange Range);

    private sealed class SoftwareOnlyProbe : IEncoderProbe
    {
        public Task<IReadOnlyList<EncoderInfo>> ProbeAsync(EncoderCacheKey key, IProgress<MediaProgress>? progress, CancellationToken ct)
            => Task.FromResult<IReadOnlyList<EncoderInfo>>([new EncoderInfo(EncoderProbe.SoftwareMediaFoundation, true, null)]);
    }
}
