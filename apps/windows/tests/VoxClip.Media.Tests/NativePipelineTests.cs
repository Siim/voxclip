using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using VoxClip.Tests.Support;
using FFmpeg.AutoGen;
using Xunit;

namespace VoxClip.Media.Tests;

[Trait("Category", "RequiresFFmpeg")]
public sealed class NativePipelineTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync();
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    internal static string TestRoot
    {
        get
        {
            for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
                if (File.Exists(Path.Combine(directory.FullName, "VoxClip.Media.Tests.csproj"))) return directory.FullName;
            throw new DirectoryNotFoundException("The Media test project could not be found.");
        }
    }
    internal static string Fixture(string file) => NativeTest.Fixture(file);
    private static string RunDirectory()
    { var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName; Directory.CreateDirectory(directory); return directory; }

    [Fact]
    public async Task LoaderAcceptsOnlyMatchingLgplSharedAbi() => await FfmpegLoader.InitializeAsync(TestContext.Current.CancellationToken);

    [Fact]
    public void NegativeSeekRetriesOnlyOnceAtPresentationZero()
    {
        var calls = new List<long>();
        var result = DecodeSession.SeekWithFallback(-0.5, 0, 0.001, target =>
        {
            calls.Add(target);
            return target < 0 ? -1 : 0;
        });
        Assert.Equal(0, result);
        Assert.Equal([-500L, 0L], calls);
        calls.Clear();
        Assert.Equal(-1, DecodeSession.SeekWithFallback(0.5, 0, 0.001, target =>
        {
            calls.Add(target);
            return -1;
        }));
        Assert.Equal([500L], calls);
    }

    [Theory]
    [InlineData("bars-two-audio.mkv")]
    [InlineData("native-rate-44100.mkv")]
    public async Task EditedWaveReplacesStalePartialButWaitsForVideoPublication(string fixture)
    {
        var snapshot = await Snapshot(fixture);
        var directory = RunDirectory();
        var path = Path.Combine(directory, "edited.wav");
        try
        {
            File.WriteAllText(path, "old audio");
            File.WriteAllText(path + ".partial", "stale");
            await EditedAudioReader.WriteWaveAsync(snapshot, path, TestContext.Current.CancellationToken, false);
            Assert.Equal("old audio", File.ReadAllText(path));
            var bytes = File.ReadAllBytes(path + ".partial");
            Assert.Equal((int)snapshot.Plan.SampleRate, BitConverter.ToInt32(bytes, 24));
            Assert.Equal(44 + snapshot.Plan.OutputSamples * 2 * 4, bytes.Length);
            OutputSafety.Publish([path], ct: TestContext.Current.CancellationToken);
            Assert.False(File.Exists(path + ".partial"));
            Assert.Equal(bytes, File.ReadAllBytes(path));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task HdrUsesTheOptionalFilterOrTheShippingFallback()
    {
        await FfmpegLoader.InitializeAsync(TestContext.Current.CancellationToken);
        Assert.True(await MediaThread.Run("vc-test-hdr", ToneMapHdr, TestContext.Current.CancellationToken));
    }

    private static unsafe bool ToneMapHdr()
    {
        if (!ToneMapper.Available)
        {
            using var video = new VideoDecoder(Fixture("hdr-full.mkv"), false);
            Assert.InRange(video.ReadAt(0, true, TestContext.Current.CancellationToken).Pixels.Span[0], (byte)0, (byte)2);
            return true;
        }
        using var input = NativeHandle.Own(Native.Frame(AVPixelFormat.AV_PIX_FMT_P010LE, 64, 64), NativeKind.Frame);
        var frame = (AVFrame*)input.Pointer;
        frame->colorspace = AVColorSpace.AVCOL_SPC_BT2020_NCL;
        frame->color_trc = AVColorTransferCharacteristic.AVCOL_TRC_SMPTE2084;
        frame->color_primaries = AVColorPrimaries.AVCOL_PRI_BT2020;
        frame->color_range = AVColorRange.AVCOL_RANGE_MPEG;
        frame->sample_aspect_ratio = new() { num = 1, den = 1 };
        frame->pts = 0;
        for (var row = 0; row < 64; row++) new Span<ushort>(frame->data[0] + row * frame->linesize[0], 64).Fill(32768);
        for (var row = 0; row < 32; row++) new Span<ushort>(frame->data[1] + row * frame->linesize[1], 64).Fill(32768);
        using var mapper = new ToneMapper(frame, new() { num = 1, den = 30 });
        var converted = mapper.Convert(frame);
        Assert.Equal(AVPixelFormat.AV_PIX_FMT_NV12, (AVPixelFormat)converted->format);
        Assert.Equal(AVColorTransferCharacteristic.AVCOL_TRC_BT709, converted->color_trc);
        Assert.Equal(AVColorSpace.AVCOL_SPC_BT709, converted->colorspace);
        Assert.InRange((int)converted->data[0][0], 16, 235);
        return true;
    }

    [Fact]
    public async Task CenterCropUsesTheMiddleSourcePixels()
    {
        var snapshot = await Snapshot();
        Assert.True(await MediaThread.Run("vc-test-crop", () =>
        {
            var input = new PixelBuffer(new byte[8 * 4 * 4], 8, 4, 8 * 4);
            for (var row = 0; row < 4; row++)
                for (var column = 0; column < 8; column++)
                { input.Pixels.Span[row * input.Stride + column * 4] = (byte)(column * 30); input.Pixels.Span[row * input.Stride + column * 4 + 3] = 255; }
            var output = new PixelBuffer(new byte[2 * 4 * 4], 2, 4, 2 * 4);
            var composer = new FrameComposer(new TestRasterizer());
            try
            {
                composer.Compose(input, output, snapshot, 0, false, TestContext.Current.CancellationToken);
                for (var row = 0; row < 4; row++)
                { Assert.Equal(90, output.Pixels.Span[row * output.Stride]); Assert.Equal(120, output.Pixels.Span[row * output.Stride + 4]); }
            }
            finally { composer.ReleaseThreadResources(); }
            return true;
        }, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task HevcTenBitDecodesWithoutAPlatformCodecExtension()
    {
        await FfmpegLoader.InitializeAsync(TestContext.Current.CancellationToken);
        Assert.True(await MediaThread.Run("vc-test-hevc", () =>
        {
            using var decoder = new VideoDecoder(Fixture("hevc10-two-audio.mp4"));
            var frame = decoder.ReadAt(2, true, TestContext.Current.CancellationToken);
            Assert.Equal(640, frame.Width); Assert.Equal(360, frame.Height);
            Assert.Contains(frame.Pixels.ToArray(), value => value != 0);
            return true;
        }, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task SharedPocket4FixtureDecodesAndExtractsTheFirstAudioTrack()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(Pocket4Fixture, TestContext.Current.CancellationToken);
        Assert.Equal("hevc", info.VideoCodec); Assert.Equal(1, info.AudioTrackIndex);
        Assert.Equal(48_000, info.Audio!.SampleRate); Assert.InRange(info.DurationSeconds, 5.99, 6.07);
        Assert.Equal(new(1280, 720), info.OrientedSize);
        Assert.True(await MediaThread.Run("vc-test-pocket4", () =>
        {
            using var decoder = new VideoDecoder(Pocket4Fixture);
            var frame = decoder.ReadAt(3, true, TestContext.Current.CancellationToken);
            Assert.Equal(1280, frame.Width); Assert.Equal(720, frame.Height);
            Assert.Contains(frame.Pixels.ToArray(), value => value != 0);
            return true;
        }, TestContext.Current.CancellationToken));
        var directory = RunDirectory();
        try
        {
            var result = await new FfmpegAudioExtractor().ExtractAsync(new(info, "pocket4", directory), null, TestContext.Current.CancellationToken);
            var bytes = File.ReadAllBytes(result.Audio.Wav16kPath);
            var samples = new float[(bytes.Length - 44) / 2];
            for (var index = 0; index < samples.Length; index++) samples[index] = BitConverter.ToInt16(bytes, 44 + index * 2) / 32768f;
            Assert.True(samples.Length > 32_000, "The 16 kHz extract is shorter than two seconds.");
            var window = samples.AsSpan(8_000, samples.Length - 16_000);
            var (first, second) = (TonePower(window, 1, 16_000, 1000), TonePower(window, 1, 16_000, 300));
            Assert.True(first > 100 * second, $"1 kHz power {first}, 300 Hz power {second}");
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task MonoAudioIsDuplicatedWithoutAttenuation()
    {
        await FfmpegLoader.InitializeAsync(TestContext.Current.CancellationToken);
        Assert.True(await MediaThread.Run("vc-test-mono", () =>
        {
            using var mono = new AudioDecoder(Fixture("bars-two-audio.mkv"));
            using var stereo = new AudioDecoder(Fixture("bars-two-audio.mkv"), 2);
            var original = new float[4096]; var actual = new float[8192];
            mono.Read(original, 4096, TestContext.Current.CancellationToken); stereo.Read(actual, 4096, TestContext.Current.CancellationToken);
            for (var sample = 0; sample < original.Length; sample++)
            { Assert.Equal(original[sample], actual[sample * 2], 6); Assert.Equal(original[sample], actual[sample * 2 + 1], 6); }
            return true;
        }, TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData("bars-two-audio.mkv", "mpeg4")]
    [InlineData("hevc10-two-audio.mp4", "hevc")]
    public async Task OpensBothContainersAndSelectsFirstAudioTrack(string fixture, string codec)
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(Fixture(fixture), TestContext.Current.CancellationToken);
        Assert.Equal(codec, info.VideoCodec); Assert.Equal(1, info.AudioTrackIndex);
        Assert.Equal(48_000, info.Audio!.SampleRate); Assert.InRange(info.DurationSeconds, 3.999, 4.04);
        Assert.Equal(new(640, 360), info.OrientedSize);
    }

    [Fact]
    public async Task ExtractionIsExactMono16kAndNativeRateEnvelope()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(Fixture("bars-two-audio.mkv"), TestContext.Current.CancellationToken);
        var directory = RunDirectory();
        try
        {
            var result = await new FfmpegAudioExtractor().ExtractAsync(new(info, "synthetic", directory), null, TestContext.Current.CancellationToken);
            Assert.Equal(64_000, result.Audio.SampleCount);
            Assert.Equal(44 + 128_000, new FileInfo(result.Audio.Wav16kPath).Length);
            Assert.Equal(48_000, result.Envelope.SampleRate); Assert.Equal(400, result.Envelope.Rms.Count);
            Assert.InRange(result.Envelope.Rms[20], 0.23f, 0.26f);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task EditedAudioMatchesKeptSamplesAndBothJoinEdgesAreSilent()
    {
        var snapshot = await Snapshot("hevc10-two-audio.mp4");
        var result = await MediaThread.Run("vc-test-audio", () =>
        {
            using var original = new AudioDecoder(snapshot.Media.Path, 2);
            using var edited = new EditedAudioReader(snapshot, 48_000);
            var source = new float[192_000 * 2]; original.Read(source, 192_000, TestContext.Current.CancellationToken);
            var actual = new float[120_000 * 2]; Assert.Equal(120_000, edited.Read(actual, 120_000, TestContext.Current.CancellationToken));
            Assert.Equal(0, actual[24_000 * 2 - 2]); Assert.Equal(0, actual[24_000 * 2]);
            Assert.Equal(0, actual[48_000 * 2 - 2]); Assert.Equal(0, actual[48_000 * 2]);
            foreach (var probe in new[] { (1000, 1000), (30000, 54000), (100000, 148000) })
                Assert.Equal(source[probe.Item2 * 2], actual[probe.Item1 * 2], 5);
            return true;
        }, TestContext.Current.CancellationToken);
        Assert.True(result);
    }

    [Theory]
    [InlineData("stereo-varying.mkv", 48_000)]
    [InlineData("stereo-varying-44100.mkv", 44_100)]
    public async Task EditedAudioPreservesTheSharedJoinGainBitsAtEverySample(string fixture, int rate)
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(Fixture(fixture), TestContext.Current.CancellationToken);
        var plan = TestPlan.FromKept(rate, rate, [new(0, rate / 4), new(rate / 2, rate / 2 + 7), new(rate * 3 / 4, rate - 1000)]);
        var snapshot = new ComposeSnapshot(info, plan, null, new(new(160, 90), 30, 2_000_000));
        var expectedWave = await MediaThread.Run("vc-test-join-bits", () =>
        {
            using var original = new AudioDecoder(info.Path, 2);
            using var edited = new EditedAudioReader(snapshot, rate);
            var source = new float[rate * 2];
            Assert.Equal(rate, original.Read(source, rate, TestContext.Current.CancellationToken));
            var actual = new float[plan.OutputSamples * 2];
            var expectedWave = new float[actual.Length];
            Assert.Equal(plan.OutputSamples, edited.Read(actual, (int)plan.OutputSamples, TestContext.Current.CancellationToken));
            var outputIndex = 0;
            foreach (var range in plan.Kept)
                for (var sourceIndex = range.StartSample; sourceIndex < range.EndSample; sourceIndex++, outputIndex++)
                    for (var channel = 0; channel < 2; channel++)
                    {
                        var expected = source[sourceIndex * 2 + channel] * (float)plan.JoinGain(outputIndex);
                        expectedWave[outputIndex * 2 + channel] = expected;
                        Assert.Equal(BitConverter.SingleToInt32Bits(expected), BitConverter.SingleToInt32Bits(actual[outputIndex * 2 + channel]));
                    }
            return expectedWave;
        }, TestContext.Current.CancellationToken);
        var directory = RunDirectory();
        try
        {
            var path = Path.Combine(directory, "edited.wav");
            await EditedAudioReader.WriteWaveAsync(snapshot, path, TestContext.Current.CancellationToken);
            var bytes = File.ReadAllBytes(path);
            Assert.Equal(44 + expectedWave.Length * 4, bytes.Length);
            for (var index = 0; index < expectedWave.Length; index++)
                Assert.Equal(BitConverter.SingleToInt32Bits(expectedWave[index]), BitConverter.ToInt32(bytes, 44 + index * 4));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task DecoderReconfiguresWhenAudioChannelsChange()
    {
        NativeTest.RequireInputFormat("aac");
        await MediaThread.Run("vc-test-audio-switch", () =>
        {
            using var decoder = new AudioDecoder(Fixture("channels-switch.aac"), 2);
            var samples = new float[48_000 * 2];
            Assert.Equal(48_000, decoder.Read(samples, 48_000, TestContext.Current.CancellationToken));
            Assert.Contains(samples.AsSpan(4_000, 8_000).ToArray(), value => Math.Abs(value) > 0.01f);
            Assert.Contains(samples.AsSpan(70_000, 8_000).ToArray(), value => Math.Abs(value) > 0.01f);
            return true;
        }, TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task AacDecoderHonorsPrimingAndEditList()
    {
        await FfmpegLoader.InitializeAsync(TestContext.Current.CancellationToken);
        var lag = await MediaThread.Run("vc-test-priming", () =>
        {
            using var source = new AudioDecoder(Fixture("bars-two-audio.mkv"), 2);
            using var aac = new AudioDecoder(Fixture("hevc10-two-audio.mp4"), 2);
            var original = new float[24_000 * 2]; var decoded = new float[24_000 * 2];
            source.Read(original, 24_000, TestContext.Current.CancellationToken); aac.Read(decoded, 24_000, TestContext.Current.CancellationToken);
            return BestLag(original, decoded, 2048, 6000, 12000);
        }, TestContext.Current.CancellationToken);
        Assert.InRange(lag, -1, 1);
    }

    [Fact]
    public async Task AacSeeksToZeroPreservePrerollAndAlignment()
    {
        var path = Fixture("hevc10-two-audio.mp4");
        await MediaThread.Run("vc-test-aac-seek-zero", () =>
        {
            using var original = new AudioDecoder(path, 2);
            using var seeking = new AudioDecoder(path, 2);
            var expected = new float[4096 * 2];
            var actual = new float[4096 * 2];
            original.Read(expected, 4096, TestContext.Current.CancellationToken);
            for (var attempt = 0; attempt < 2; attempt++)
            {
                seeking.Seek(0);
                seeking.Read(actual, 4096, TestContext.Current.CancellationToken);
                Assert.Equal(0, BestLag(expected, actual, 1, 64, 3000));
                var meanSquareError = expected.Zip(actual, (reference, sample) => Math.Pow(reference - sample, 2)).Average();
                Assert.InRange(meanSquareError, 0, 1e-6);
                seeking.Seek(2 * 48_000);
                seeking.Read(actual, 4096, TestContext.Current.CancellationToken);
            }
            return true;
        }, TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task PreviewSeeksExactlyAndFramesRemainCallerOwned()
    {
        var snapshot = await Snapshot();
        await using var preview = new PreviewEngine(new FrameComposer(new TestRasterizer()));
        await preview.LoadAsync(snapshot, null, TestContext.Current.CancellationToken);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromSeconds(20));
        await using var reader = preview.ReadFramesAsync(cancellation.Token).GetAsyncEnumerator(TestContext.Current.CancellationToken);
        Assert.True(await reader.MoveNextAsync());
        var initial = reader.Current.Buffer.Pixels.ToArray();
        var original = reader.Current.Buffer;
        await preview.SeekAsync(1, true, cancellation.Token);
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal(2, reader.Current.SourcePts, 4);
        Assert.Equal(initial, original.Pixels.ToArray());
    }

    [Fact]
    public async Task PreviewLeaseSurvivesSeeksAndEngineDisposalUntilReleased()
    {
        var snapshot = await Snapshot();
        await using var preview = new PreviewEngine(new FrameComposer(new TestRasterizer()), true);
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        cancellation.CancelAfter(TimeSpan.FromSeconds(20));
        await preview.LoadAsync(snapshot, null, cancellation.Token);
        await using var reader = preview.ReadFrameLeasesAsync(cancellation.Token).GetAsyncEnumerator(cancellation.Token);
        Assert.True(await reader.MoveNextAsync());
        using var held = reader.Current;
        var saved = held.Frame.Buffer.Pixels.ToArray();
        for (var index = 0; index < 12; index++) await preview.SeekAsync(index % 2, true, cancellation.Token);
        Assert.Equal(saved, held.Frame.Buffer.Pixels.ToArray());
        await preview.DisposeAsync();
        Assert.Equal(saved, held.Frame.Buffer.Pixels.ToArray());
    }

    internal static async Task<ComposeSnapshot> Snapshot(string fixture = "bars-two-audio.mkv")
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(Fixture(fixture), TestContext.Current.CancellationToken);
        var rate = info.Audio!.SampleRate;
        var plan = TestPlan.FromKept(rate, rate * 4, [new(0, rate / 2), new(rate, rate * 3 / 2), new(rate * 2, rate * 7 / 2)]);
        return new(info, plan, null, new(new(640, 360), 30, 2_000_000));
    }

    internal static string Pocket4Fixture => Path.Combine(FixtureLoader.SharedRoot, "fixtures", "ingest", "media", "pocket4-like-2tracks.mov");

    internal static double TonePower(ReadOnlySpan<float> samples, int stride, double rate, double frequency)
    {
        var coefficient = 2 * Math.Cos(2 * Math.PI * frequency / rate);
        double previous = 0, older = 0;
        for (var index = 0; index < samples.Length; index += stride)
        {
            var current = samples[index] + coefficient * previous - older;
            older = previous; previous = current;
        }
        return previous * previous + older * older - coefficient * previous * older;
    }

    internal static int BestLag(float[] source, float[] decoded, int maximum, int start, int count)
    {
        var best = double.NegativeInfinity; var lag = 0;
        for (var candidate = -maximum; candidate <= maximum; candidate++)
        {
            double score = 0;
            for (var index = start; index < start + count; index++) score += source[index * 2] * (double)decoded[(index + candidate) * 2];
            if (score > best) { best = score; lag = candidate; }
        }
        return lag;
    }
}
