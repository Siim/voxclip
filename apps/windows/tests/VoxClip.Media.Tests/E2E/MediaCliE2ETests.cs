using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using FFmpeg.AutoGen;
using VoxClip.Cli;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Media.Tests.E2E;

[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class MediaCliE2ETests
{
    private const string Chirp = "fillers-chirp.mp4";
    private const string ChirpTranscript = "fillers-chirp.transcript.json";
    private const string Tone = "joins-tone.mov";
    private const string ToneTranscript = "joins-tone.transcript.json";
    private static readonly string[] CaseIds =
    [
        "e2e-1-chirp-cut-fillers", "e2e-2-tone-joins", "e2e-3-captions-vox-bold",
        "e2e-3-captions-vox-highlight", "e2e-4-style-off", "e2e-5-everything-cut",
        "e2e-6-big-source", "e2e-7-counter-9x16", "e2e-8-bars", "e2e-9-tiny-webm"
    ];

    [Theory]
    [MemberData(nameof(Cases))]
    public async Task CliExportsMatchDecodedMedia(string caseId)
    {
        var fixtures = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "media");
        if (!File.Exists(Path.Combine(fixtures, "index.json")))
        {
            const string reason = "Canonical media fixtures are absent; archive track/tooling shared/fixtures/media into this run.";
            if (Environment.GetEnvironmentVariable("VOXCLIP_REQUIRE_E2E") == "1") Assert.Fail(reason);
            Assert.Skip(reason);
        }
        VerifyFixtureHashes(fixtures);
        await NativeTest.RequireAsync(windows: true);
        var sourceName = caseId switch
        {
            "e2e-2-tone-joins" => Tone,
            "e2e-6-big-source" => "big-2400x1350.mp4",
            "e2e-7-counter-9x16" => "counter-1080p.mp4",
            "e2e-8-bars" => "bars-1080p.mp4",
            "e2e-9-tiny-webm" => "tiny.webm",
            _ => Chirp
        };
        var source = Path.Combine(fixtures, sourceName);
        var directory = Directory.CreateTempSubdirectory("voxclip-e2e-").FullName;
        try
        {
            var output = Path.Combine(directory, "output.mp4");
            var wave = Path.Combine(directory, "edited.wav");
            var arguments = new List<string> { "--open", source, "--export", output, "--json", "--quiet", "--style", "off" };
            if (caseId is "e2e-1-chirp-cut-fillers" or "e2e-2-tone-joins" or "e2e-4-style-off" or "e2e-5-everything-cut" || caseId.StartsWith("e2e-3-", StringComparison.Ordinal))
            {
                var transcript = caseId == "e2e-2-tone-joins" ? ToneTranscript :
                    caseId == "e2e-5-everything-cut" ? "fillers-only.transcript.json" : ChirpTranscript;
                arguments.AddRange(["--transcript", Path.Combine(fixtures, transcript), "--cut-fillers"]);
            }
            if (caseId is "e2e-1-chirp-cut-fillers" or "e2e-2-tone-joins") arguments.AddRange(["--audio-out", wave]);
            if (caseId is "e2e-6-big-source" or "e2e-7-counter-9x16" or "e2e-9-tiny-webm")
            {
                var transcript = JsonNode.Parse(File.ReadAllText(Path.Combine(fixtures, ChirpTranscript)))!.AsObject();
                transcript["words"] = new JsonArray(transcript["words"]!.AsArray()[0]!.DeepClone());
                var transcriptPath = Path.Combine(directory, "synthetic-transcript.json");
                File.WriteAllText(transcriptPath, transcript.ToJsonString());
                arguments.AddRange(["--transcript", transcriptPath]);
            }
            if (caseId.StartsWith("e2e-3-", StringComparison.Ordinal))
            {
                arguments[arguments.IndexOf("--style") + 1] = caseId["e2e-3-captions-".Length..];
            }
            if (caseId == "e2e-7-counter-9x16") arguments.AddRange(["--aspect", "9:16"]);
            if (caseId == "e2e-6-big-source") arguments.AddRange(["--aspect", "source"]);
            var (exit, result) = await RunCli(arguments, directory, TestContext.Current.CancellationToken);
            WriteReport(caseId, exit, result);
            if (caseId == "e2e-5-everything-cut")
            {
                Assert.Equal(5, exit);
                Assert.Equal("everythingCut", result["error"]?["code"]?.GetValue<string>());
                Assert.False(File.Exists(output));
                return;
            }
            Assert.Equal(0, exit);
            Assert.True(result["ok"]?.GetValue<bool>());
            Assert.True(File.Exists(output));
            var exported = await new FfmpegMediaProbe().ProbeAsync(output, TestContext.Current.CancellationToken);
            Assert.Equal("h264", exported.VideoCodec);
            if (caseId == "e2e-1-chirp-cut-fillers") await CheckChirp(fixtures, source, wave, result);
            if (caseId == "e2e-2-tone-joins") await CheckTone(fixtures, source, wave, result);
            if (caseId.StartsWith("e2e-3-", StringComparison.Ordinal)) await CheckCaptions(fixtures, source, output);
            if (caseId == "e2e-4-style-off") await CheckStyleOff(fixtures, source, result);
            if (caseId == "e2e-6-big-source") Assert.Equal(new PixelSize(1920, 1080), exported.OrientedSize);
            if (caseId == "e2e-7-counter-9x16") await CheckCounter(output, exported);
            if (caseId == "e2e-8-bars") await CheckBars(source, output, result["softwareEncoding"]?.GetValue<bool>() == true,
                result["encoder"]?.GetValue<string>());
            if (caseId == "e2e-9-tiny-webm") Assert.True(result["frames"]?.GetValue<int>() > 0);
        }
        finally { Directory.Delete(directory, true); }
    }

    public static TheoryData<string> Cases
    {
        get { var cases = new TheoryData<string>(); foreach (var id in CaseIds) cases.Add(id); return cases; }
    }

    private static void VerifyFixtureHashes(string directory)
    {
        using var index = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "index.json")));
        var entries = index.RootElement.EnumerateArray().ToArray();
        Assert.Equal(6, entries.Length);
        foreach (var entry in entries)
        {
            var name = entry.GetProperty("file").GetString()!;
            Assert.Equal(name, Path.GetFileName(name));
            var path = Path.Combine(directory, name);
            Assert.True(File.Exists(path), $"Missing indexed media fixture: {name}");
            Assert.Equal(entry.GetProperty("bytes").GetInt64(), new FileInfo(path).Length);
            using var input = File.OpenRead(path);
            Assert.Equal(entry.GetProperty("sha256").GetString(), Convert.ToHexStringLower(SHA256.HashData(input)));
        }
    }

    private static async Task<(int Exit, JsonNode Result)> RunCli(IReadOnlyList<string> arguments, string directory, CancellationToken ct)
    {
        var cli = Environment.GetEnvironmentVariable("VOXCLIP_CLI") ?? Path.Combine(NativePipelineTests.TestRoot,
            "..", "..", "src", "VoxClip.Cli", "bin", "Release", "net10.0", "voxclip-cli.dll");
        cli = Path.GetFullPath(cli);
        Assert.True(File.Exists(cli), $"Built CLI is missing: {cli}");
        var start = new ProcessStartInfo(cli.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ? "dotnet" : cli)
        { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        if (cli.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(cli);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        start.Environment["VOXCLIP_SHARED_DIR"] = FixtureLoader.SharedRoot;
        start.Environment["VOXCLIP_DATA_DIR"] = Path.Combine(directory, "data");
        start.Environment["VOXCLIP_LIVE_TESTS"] = "0";
        start.Environment["VOXCLIP_TEST_DOWNLOAD"] = "0";
        using var process = Process.Start(start)!;
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(TimeSpan.FromMinutes(4));
        try
        {
            var stdout = process.StandardOutput.ReadToEndAsync(limit.Token);
            var stderr = process.StandardError.ReadToEndAsync(limit.Token);
            await process.WaitForExitAsync(limit.Token);
            var body = await stdout; await stderr;
            return (process.ExitCode, JsonNode.Parse(body.Trim()) ?? throw new JsonException("The CLI did not write one JSON object."));
        }
        catch { if (!process.HasExited) process.Kill(entireProcessTree: true); throw; }
    }

    private static void WriteReport(string caseId, int exit, JsonNode result)
    {
        var root = Environment.GetEnvironmentVariable("VOXCLIP_E2E_OUT");
        if (string.IsNullOrWhiteSpace(root)) return;
        Directory.CreateDirectory(root);
        File.WriteAllText(Path.Combine(root, caseId + ".json"), new JsonObject
        {
            ["caseId"] = caseId, ["platform"] = "windows", ["exitCode"] = exit, ["result"] = result.DeepClone()
        }.ToJsonString());
    }

    private static async Task<(EditPlan Plan, IReadOnlyList<CaptionWord> Words)> ExpectedPlan(string source, string transcriptPath)
    {
        var media = await new FfmpegMediaProbe().ProbeAsync(source, TestContext.Current.CancellationToken);
        var transcript = JsonSerializer.Deserialize(File.ReadAllText(transcriptPath), CliDataJson.Default.Transcript)!;
        var project = CliOperations.NewProject(media, transcript, "");
        var state = CliOperations.ApplyExportEdits(EditingEngine.FromProject(project)!, true, false, null, null);
        project = EditingEngine.ApplyToProject(project, state);
        var plan = CliOperations.BuildPlan(project, true);
        return (plan, EditingEngine.CaptionWords(state, plan));
    }

    private static float[] Wave(string path, EditPlan plan)
    {
        var bytes = File.ReadAllBytes(path);
        Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(bytes, 0, 4));
        Assert.Equal("WAVE", System.Text.Encoding.ASCII.GetString(bytes, 8, 4));
        Assert.Equal((int)plan.SampleRate, BitConverter.ToInt32(bytes, 24));
        Assert.Equal(2, BitConverter.ToInt16(bytes, 22));
        Assert.Equal(44 + plan.OutputSamples * 2 * 4, bytes.Length);
        var samples = new float[plan.OutputSamples * 2];
        Buffer.BlockCopy(bytes, 44, samples, 0, samples.Length * 4);
        return samples;
    }

    private static async Task CheckChirp(string fixtures, string source, string wave, JsonNode result)
    {
        var (plan, _) = await ExpectedPlan(source, Path.Combine(fixtures, ChirpTranscript));
        Assert.Equal(plan.OutputSamples, result["audioSamples"]?.GetValue<long>());
        var edited = Wave(wave, plan);
        var lags = await MediaThread.Run("vc-e2e-chirp", () =>
        {
            using var reader = new AudioDecoder(source, 2);
            var original = new float[plan.TotalSamples * 2];
            reader.Read(original, (int)plan.TotalSamples, TestContext.Current.CancellationToken);
            var measured = new List<(double Fraction, int Lag, double Correlation)>();
            foreach (var fraction in new[] { 0.08, 0.50, 0.94 })
            {
                var output = (int)(plan.OutputSamples * fraction);
                var mapped = new int[8192];
                for (var offset = 0; offset < mapped.Length; offset++)
                    mapped[offset] = (int)Math.Round(plan.SourceTime((output + offset - 4096) / plan.SampleRate) * plan.SampleRate);
                var bestLag = 0; var best = double.NegativeInfinity;
                for (var lag = -256; lag <= 256; lag++)
                {
                    double correlation = 0;
                    for (var offset = 0; offset < mapped.Length; offset++)
                    {
                        var a = output + offset - 4096; var b = mapped[offset] + lag;
                        if (a >= 0 && a < plan.OutputSamples && b >= 0 && b < plan.TotalSamples)
                            correlation += edited[a * 2] * original[b * 2];
                    }
                    if (correlation > best) { best = correlation; bestLag = lag; }
                }
                measured.Add((fraction, bestLag, best));
            }
            return measured;
        }, TestContext.Current.CancellationToken);
        foreach (var measured in lags)
        {
            Assert.True(measured.Correlation > 0.1, $"No source chirp correlation at {measured.Fraction:P0}.");
        }
        Assert.True(lags.All(measured => Math.Abs(measured.Lag) < 48),
            "Chirp lags: " + string.Join(", ", lags.Select(measured => $"{measured.Fraction:P0}={measured.Lag}")));
    }

    private static async Task CheckTone(string fixtures, string source, string wave, JsonNode result)
    {
        var (plan, _) = await ExpectedPlan(source, Path.Combine(fixtures, ToneTranscript));
        Assert.Equal(59, plan.Joins.Count);
        Assert.Equal(plan.OutputSamples, result["audioSamples"]?.GetValue<long>());
        var samples = Wave(wave, plan);
        foreach (var join in plan.Joins)
            for (var offset = -3; offset <= 3; offset++)
                for (var channel = 0; channel < 2; channel++)
                    Assert.True(Math.Abs(samples[(join.OutSample + offset) * 2 + channel]) < 0.01f,
                        $"Join {join.OutSample} was not silent at offset {offset}.");
    }

    private static async Task CheckCaptions(string fixtures, string source, string output)
    {
        var (_, words) = await ExpectedPlan(source, Path.Combine(fixtures, ChirpTranscript));
        Assert.NotEmpty(words);
        await MediaThread.Run("vc-e2e-captions", () =>
        {
            using var video = new VideoDecoder(output, false);
            foreach (var word in words)
            {
                Assert.True(BrightCaptionPixels(video.ReadAt(Math.Max(0, word.Start - 0.12), true, TestContext.Current.CancellationToken)) == 0,
                    $"Caption appeared before {word.Id}.");
                Assert.True(BrightCaptionPixels(video.ReadAt((word.Start + word.End) / 2, true, TestContext.Current.CancellationToken)) > 10,
                    $"Caption missing at {word.Id}.");
                Assert.True(BrightCaptionPixels(video.ReadAt(word.End + 0.12, true, TestContext.Current.CancellationToken)) == 0,
                    $"Caption remained after {word.Id}.");
            }
            return true;
        }, TestContext.Current.CancellationToken);
    }

    private static int BrightCaptionPixels(PixelBuffer frame)
    {
        var pixels = frame.Pixels.Span; var count = 0;
        for (var y = frame.Height * 7 / 10; y < frame.Height * 9 / 10; y += 2)
            for (var x = frame.Width / 4; x < frame.Width * 3 / 4; x += 2)
            {
                var offset = y * frame.Stride + x * 4;
                var luma = (pixels[offset] * 11 + pixels[offset + 1] * 59 + pixels[offset + 2] * 30) / 100;
                if (luma >= 200) count++;
            }
        return count;
    }

    private static async Task CheckStyleOff(string fixtures, string source, JsonNode result)
    {
        var (plan, _) = await ExpectedPlan(source, Path.Combine(fixtures, ChirpTranscript));
        Assert.Equal("off", result["captionStyle"]?.GetValue<string>());
        Assert.InRange(Math.Abs(result["durationSeconds"]!.GetValue<double>() - plan.Duration), 0, 0.001);
    }

    private static async Task CheckCounter(string output, MediaInfo info)
    {
        Assert.Equal(new PixelSize(1080, 1920), info.OrientedSize);
        await MediaThread.Run("vc-e2e-counter", () =>
        {
            using var video = new VideoDecoder(output, false);
            for (var frameIndex = 0; frameIndex < 120; frameIndex++)
            {
                var frame = video.ReadAt(frameIndex / 30.0, true, TestContext.Current.CancellationToken);
                foreach (var marker in new[] { 185, 895 })
                    Assert.Contains(Enumerable.Range(marker - 3, 7), x => Bright(frame, x, 500));
                var decoded = 0;
                for (var bit = 0; bit < 12; bit++)
                {
                    var sourceX = 720 + 16 + 40 * bit;
                    var x = (int)Math.Round((sourceX - 656) * 1080 / 608.0);
                    decoded = (decoded << 1) | (Bright(frame, x, 57) ? 1 : 0);
                }
                Assert.Equal(frameIndex, decoded);
            }
            return true;
        }, TestContext.Current.CancellationToken);
    }

    private static bool Bright(PixelBuffer frame, int x, int y)
    {
        var span = frame.Pixels.Span; var offset = y * frame.Stride + x * 4;
        return span[offset] > 150 && span[offset + 1] > 150 && span[offset + 2] > 150;
    }

    private static async Task CheckBars(string source, string output, bool softwareMediaFoundation, string? encoder)
    {
        int[][] expected = [[191, 191, 191], [191, 191, 0], [0, 191, 191], [0, 191, 0],
            [191, 0, 191], [191, 0, 0], [0, 0, 191], [0, 0, 0]];
        Assert.Equal(softwareMediaFoundation, encoder == EncoderProbe.SoftwareMediaFoundation);
        await MediaThread.Run("vc-e2e-bars", () =>
        {
            using var video = new VideoDecoder(output, false);
            using var original = new VideoDecoder(source, false);
            using var raw = new DecodeSession(output, AVMediaType.AVMEDIA_TYPE_VIDEO);
            var composer = new FrameComposer();
            var failures = new List<string>();
            var frameIndex = 0;
            while (raw.Next(TestContext.Current.CancellationToken))
            {
                if (frameIndex is 9 or 15 or 30)
                {
                    var time = frameIndex / 30.0;
                    var frame = video.ReadAt(time, true, TestContext.Current.CancellationToken);
                    var reference = original.ReadAt(time, false, TestContext.Current.CancellationToken);
                    Assert.Equal(1920, frame.Width); Assert.Equal(1080, frame.Height);
                    var (beforeEncode, inputYuv) = RoundTripExportConversion(reference, source, time, composer);
                    if (softwareMediaFoundation)
                        AddSoftwareColorMetadataFailures(raw, frameIndex, failures);
                    if (softwareMediaFoundation && !HasPlanarYuv(raw))
                    {
                        frameIndex++;
                        continue;
                    }
                    for (var bar = 0; bar < 8; bar++)
                        for (var position = 0; position < 3; position++)
                        {
                            var x = bar * 240 + 60 * (position + 1);
                            var y = 300 + 200 * position;
                            var offset = y * frame.Stride + x * 4;
                            var decodedYuv = softwareMediaFoundation ? YuvAt(raw, x, y) : default;
                            var beforeYuv = inputYuv[bar, position];
                            for (var channel = 0; channel < 3; channel++)
                            {
                                var actual = frame.Pixels.Span[offset + 2 - channel];
                                var before = reference.Pixels.Span[offset + 2 - channel];
                                var converted = beforeEncode[offset + 2 - channel];
                                if (Math.Abs(converted - expected[bar][channel]) > 3)
                                    failures.Add($"frame {frameIndex}, bar {bar}, position {position}, RGB channel {channel}: source {before}, preencoder round trip {converted}, expected {expected[bar][channel]}");
                                if (!softwareMediaFoundation && Math.Abs(actual - expected[bar][channel]) > 3)
                                    failures.Add($"frame {frameIndex}, bar {bar}, position {position}, RGB channel {channel}: decoded {actual}, expected {expected[bar][channel]}");
                            }
                            if (softwareMediaFoundation && (Math.Abs(decodedYuv.Y - beforeYuv.Y) > 1 ||
                                Math.Abs(decodedYuv.U - beforeYuv.U) > 1 || Math.Abs(decodedYuv.V - beforeYuv.V) > 1))
                                failures.Add($"frame {frameIndex}, bar {bar}, position {position}: preencoder YUV {beforeYuv}, decoded YUV {decodedYuv}, decoded RGB " +
                                    $"{frame.Pixels.Span[offset + 2]}/{frame.Pixels.Span[offset + 1]}/{frame.Pixels.Span[offset]}");
                        }
                }
                frameIndex++;
            }
            Assert.True(frameIndex > 30, "The exported bars are missing a representative frame.");
            Assert.True(failures.Count == 0, $"Bar colour checks failed in {failures.Count} channels/positions:\n{string.Join("\n", failures)}");
            composer.ReleaseThreadResources();
            return true;
        }, TestContext.Current.CancellationToken);
    }

    private static unsafe void AddSoftwareColorMetadataFailures(DecodeSession decoder, int frame, List<string> failures)
    {
        if (decoder.Codec->profile != ffmpeg.AV_PROFILE_H264_HIGH) failures.Add($"frame {frame}: profile {decoder.Codec->profile}, expected High (100)");
        if ((AVPixelFormat)decoder.Frame->format != AVPixelFormat.AV_PIX_FMT_YUV420P) failures.Add($"frame {frame}: pixel format {(AVPixelFormat)decoder.Frame->format}, expected yuv420p");
        if (decoder.Frame->color_primaries != AVColorPrimaries.AVCOL_PRI_BT709) failures.Add($"frame {frame}: primaries {decoder.Frame->color_primaries}, expected BT.709");
        if (decoder.Frame->color_trc != AVColorTransferCharacteristic.AVCOL_TRC_BT709) failures.Add($"frame {frame}: transfer {decoder.Frame->color_trc}, expected BT.709");
        if (decoder.Frame->colorspace != AVColorSpace.AVCOL_SPC_BT709) failures.Add($"frame {frame}: matrix {decoder.Frame->colorspace}, expected BT.709");
        if (decoder.Frame->color_range != AVColorRange.AVCOL_RANGE_MPEG) failures.Add($"frame {frame}: range {decoder.Frame->color_range}, expected MPEG limited");
    }

    private static unsafe bool HasPlanarYuv(DecodeSession decoder) =>
        (AVPixelFormat)decoder.Frame->format is AVPixelFormat.AV_PIX_FMT_YUV420P or AVPixelFormat.AV_PIX_FMT_NV12;

    private static unsafe (byte[] Bgra, (int Y, int U, int V)[,] Yuv) RoundTripExportConversion(PixelBuffer source, string sourcePath, double time, FrameComposer composer)
    {
        var composed = new PixelBuffer(new byte[source.Width * source.Height * 4], source.Width, source.Height, source.Width * 4);
        var media = new MediaInfo(sourcePath, 2, new(source.Width, source.Height, 30, 0), null,
            new(source.Width, source.Height), "h264", null, false, 0, -1, 0);
        var plan = TestPlan.FromKept(48_000, 96_000, [new(0, 96_000)]);
        var snapshot = new ComposeSnapshot(media, plan, null, new(new(source.Width, source.Height), 30, 8_000_000));
        composer.Compose(source, composed, snapshot, time, false, TestContext.Current.CancellationToken);
        using var nv12Handle = NativeHandle.Own(Native.Frame(AVPixelFormat.AV_PIX_FMT_NV12, source.Width, source.Height), NativeKind.Frame);
        using var forward = NativeHandle.Own(ffmpeg.sws_getContext(source.Width, source.Height, AVPixelFormat.AV_PIX_FMT_BGRA,
            source.Width, source.Height, AVPixelFormat.AV_PIX_FMT_NV12, (int)SwsFlags.SWS_BILINEAR, null, null, null), NativeKind.Scale);
        using var reverse = NativeHandle.Own(ffmpeg.sws_getContext(source.Width, source.Height, AVPixelFormat.AV_PIX_FMT_NV12,
            source.Width, source.Height, AVPixelFormat.AV_PIX_FMT_BGRA, (int)SwsFlags.SWS_BILINEAR, null, null, null), NativeKind.Scale);
        Native.Colors((SwsContext*)forward.Pointer, true);
        Native.Colors((SwsContext*)reverse.Pointer);
        var nv12 = (AVFrame*)nv12Handle.Pointer;
        using (var pinned = composed.Pixels.Pin())
        {
            var input = new byte_ptrArray4(); input[0] = (byte*)pinned.Pointer;
            var strides = new int_array4(); strides[0] = composed.Stride;
            Assert.Equal(source.Height, ffmpeg.sws_scale((SwsContext*)forward.Pointer, input, strides, 0, source.Height,
                nv12->data, nv12->linesize));
        }
        var inputYuv = new (int Y, int U, int V)[8, 3];
        for (var bar = 0; bar < 8; bar++)
            for (var position = 0; position < 3; position++)
                inputYuv[bar, position] = YuvAt(nv12, bar * 240 + 60 * (position + 1), 300 + 200 * position);
        var result = new byte[source.Width * source.Height * 4];
        fixed (byte* pixels = result)
        {
            var output = new byte_ptrArray4(); output[0] = pixels;
            var strides = new int_array4(); strides[0] = source.Width * 4;
            Assert.Equal(source.Height, ffmpeg.sws_scale((SwsContext*)reverse.Pointer, nv12->data, nv12->linesize,
                0, source.Height, output, strides));
        }
        return (result, inputYuv);
    }

    private static unsafe (int Y, int U, int V) YuvAt(AVFrame* frame, int x, int y)
    {
        var format = (AVPixelFormat)frame->format;
        var luma = frame->data[0][y * frame->linesize[0] + x];
        var u = format == AVPixelFormat.AV_PIX_FMT_NV12
            ? frame->data[1][(y / 2) * frame->linesize[1] + x]
            : frame->data[1][(y / 2) * frame->linesize[1] + x / 2];
        var v = format == AVPixelFormat.AV_PIX_FMT_NV12
            ? frame->data[1][(y / 2) * frame->linesize[1] + x + 1]
            : frame->data[2][(y / 2) * frame->linesize[2] + x / 2];
        return (luma, u, v);
    }

    private static unsafe (int Y, int U, int V) YuvAt(DecodeSession decoder, int x, int y) => YuvAt(decoder.Frame, x, y);
}
