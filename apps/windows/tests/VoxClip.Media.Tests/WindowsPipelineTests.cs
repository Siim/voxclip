using System.Diagnostics;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Media.Audio;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Media.Tests;

[Trait("Category", "RequiresFFmpeg")]
[Trait("Category", "RequiresWindows")]
public sealed class WindowsPipelineTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync(windows: true);
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Theory]
    [InlineData("start-zero.avi")]
    [InlineData("start-zero.flv")]
    public async Task IdentityExportAndPreviewAudioStartSeekFromZero(string fixture)
    {
        NativeTest.RequireInputFormat(fixture.EndsWith(".avi", StringComparison.Ordinal) ? "avi" : "flv");
        var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture(fixture), TestContext.Current.CancellationToken);
        var total = (long)Math.Round(info.DurationSeconds * info.Audio!.SampleRate);
        var snapshot = new ComposeSnapshot(info, TestPlan.FromKept(info.Audio.SampleRate, total, [new(0, total)]),
            null, new(new(160, 90), 10, 1_000_000));
        await MediaThread.Run("vc-test-preview-audio-start", () =>
        {
            using var previewAudio = new EditedAudioReader(snapshot, 48_000, 0);
            var samples = new float[4096 * 2];
            Assert.Equal(4096, previewAudio.Read(samples, 4096, TestContext.Current.CancellationToken));
            Assert.Contains(samples, value => Math.Abs(value) > 0.01f);
            return true;
        }, TestContext.Current.CancellationToken);
        var directory = RunDirectory();
        try
        {
            var output = Path.Combine(directory, "identity.mp4");
            var result = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source,
                ExportQuality.Standard, output, null), null, TestContext.Current.CancellationToken);
            Assert.True(result.Frames > 0);
            Assert.True(result.AudioSamples > 0);
            Assert.True(File.Exists(output));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task ResolutionSwitchExportsAtTheOpeningSize()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture("resolution-switch.mkv"), TestContext.Current.CancellationToken);
        var total = (long)Math.Round(info.DurationSeconds * 48_000);
        var snapshot = new ComposeSnapshot(info, TestPlan.FromKept(48_000, total, [new(0, total)]),
            null, new(new(160, 90), 10, 1_000_000));
        await MediaThread.Run("vc-test-size-switch", () =>
        {
            using var decoder = new VideoDecoder(info.Path, false);
            for (var frame = 0; frame < 10; frame++)
            {
                var image = decoder.ReadAt(frame / 10.0, true, TestContext.Current.CancellationToken);
                Assert.Equal(160, image.Width); Assert.Equal(90, image.Height);
            }
            return true;
        }, TestContext.Current.CancellationToken);
        var directory = RunDirectory();
        try
        {
            var output = Path.Combine(directory, "resized.mp4");
            await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source,
                ExportQuality.Standard, output, null), null, TestContext.Current.CancellationToken);
            var exported = await new FfmpegMediaProbe().ProbeAsync(output, TestContext.Current.CancellationToken);
            Assert.Equal(new PixelSize(160, 90), exported.OrientedSize);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task VideoOnlyStagingReportsTheAudioTargetAndPublishesVideoFirst()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture("bars-4k.mkv"), TestContext.Current.CancellationToken);
        var total = (long)Math.Round(info.DurationSeconds * 48_000);
        var snapshot = new ComposeSnapshot(info, TestPlan.FromKept(48_000, total, [new(0, total)]), null, new(new(1920, 1080), 24, 4_000_000));
        var directory = RunDirectory();
        var path = Path.Combine(directory, "video.mp4");
        var srt = Path.Combine(directory, "captions.srt");
        try
        {
            File.WriteAllText(path, "old video"); File.WriteAllText(srt, "old subtitles");
            File.WriteAllText(path + ".partial", "stale video"); File.WriteAllText(srt + ".partial", "stale subtitles");
            var result = await new Exporter().PrepareAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, path, srt), null, TestContext.Current.CancellationToken);
            Assert.Equal(48_000, result.AudioSampleRate); Assert.Equal(0, result.AudioSamples);
            Assert.Equal("old video", File.ReadAllText(path)); Assert.Equal("old subtitles", File.ReadAllText(srt));
            Assert.True(new FileInfo(path + ".partial").Length > 0);
            Assert.Equal(string.Empty, File.ReadAllText(srt + ".partial"));
            OutputSafety.Publish([path, srt], ct: TestContext.Current.CancellationToken);
            Assert.False(File.Exists(path + ".partial")); Assert.False(File.Exists(srt + ".partial"));
            var exported = await new FfmpegMediaProbe().ProbeAsync(path, TestContext.Current.CancellationToken);
            Assert.Null(exported.Audio);
        }
        finally { Directory.Delete(directory, true); }
    }
    [Fact]
    public async Task HevcMain10WithTwoAudioTracksExportsTheFirstTrack()
    {
        var snapshot = await NativePipelineTests.Snapshot("hevc10-two-audio.mp4");
        var directory = RunDirectory();
        try
        {
            var path = Path.Combine(directory, "hevc.mp4");
            File.WriteAllText(path + ".partial", "interrupted export");
            var result = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, path, null), null, TestContext.Current.CancellationToken);
            Assert.False(File.Exists(path + ".partial"));
            Assert.Equal(120_000, result.AudioSamples);
            var lag = await MediaThread.Run("vc-test-hevc-audio", () =>
            {
                using var expected = new EditedAudioReader(snapshot, 48_000);
                using var actual = new AudioDecoder(path, 2);
                var reference = new float[48_000]; var decoded = new float[48_000];
                expected.Read(reference, 24_000, TestContext.Current.CancellationToken);
                actual.Read(decoded, 24_000, TestContext.Current.CancellationToken);
                return NativePipelineTests.BestLag(reference, decoded, 2048, 6000, 12000);
            }, TestContext.Current.CancellationToken);
            Assert.InRange(lag, -1, 1);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData(ExportAspect.Source, 640, 360)]
    [InlineData(ExportAspect.Portrait, 1080, 1920)]
    [InlineData(ExportAspect.Square, 1080, 1080)]
    [InlineData(ExportAspect.Landscape, 1920, 1080)]
    public async Task CaptionsOffCutsExportPlayableH264AndAlignedAac(ExportAspect aspect, int width, int height)
    {
        var snapshot = await NativePipelineTests.Snapshot();
        var directory = RunDirectory();
        var path = Path.Combine(directory, "cut.mp4");
        try
        {
            var timer = Stopwatch.StartNew();
            var updates = new List<(string Phase, double Time)>();
            var progress = aspect == ExportAspect.Source ? new InlineProgress<ExportProgress>(value => updates.Add((value.Phase, timer.Elapsed.TotalSeconds))) : null;
            var result = await new Exporter(new FrameComposer(new TestRasterizer()), new EncoderProbe()).ExportAsync(
                new(snapshot, new ExportTarget.FullEdit(), aspect, ExportQuality.Standard, path, null), progress, TestContext.Current.CancellationToken);
            if (progress is not null)
            {
                Assert.Equal(new[] { "preparing", "encoding", "finalizing" }, updates.Select(update => update.Phase).Distinct());
                Assert.All(updates.Zip(updates.Skip(1)), pair => Assert.True(pair.Second.Time - pair.First.Time >= 0.09));
            }
            TestContext.Current.TestOutputHelper!.WriteLine($"encoder={result.Encoder}; aspect={aspect}; elapsed={timer.Elapsed.TotalSeconds:F3}; frames={result.Frames}");
            Assert.Contains(result.Encoder, EncoderProbe.Ladder);
            Assert.Equal(75, result.Frames); Assert.Equal(120_000, result.AudioSamples);
            Assert.False(File.Exists(path + ".partial"));
            var info = await new FfmpegMediaProbe().ProbeAsync(path, TestContext.Current.CancellationToken);
            Assert.Equal("h264", info.VideoCodec); Assert.Equal("aac", info.AudioCodec);
            Assert.Equal(new(width, height), info.OrientedSize); Assert.Equal(2, info.Audio!.Channels);
            Assert.InRange(info.DurationSeconds, 2.49, 2.53);
            await MediaThread.Run("vc-test-cfr", () => VerifyVideoTiming(path, 2.5, 30), TestContext.Current.CancellationToken);
            var lag = await MediaThread.Run("vc-test-export-audio", () =>
            {
                using var expected = new EditedAudioReader(snapshot, 48_000);
                using var actual = new AudioDecoder(path, 2);
                var original = new float[48_000]; var decoded = new float[48_000];
                expected.Read(original, 24_000, TestContext.Current.CancellationToken); actual.Read(decoded, 24_000, TestContext.Current.CancellationToken);
                return NativePipelineTests.BestLag(original, decoded, 2048, 6000, 12000);
            }, TestContext.Current.CancellationToken);
            TestContext.Current.TestOutputHelper.WriteLine($"aac-priming-lag-samples={lag}");
            Assert.InRange(lag, -1, 1);
            await File.WriteAllTextAsync(Path.Combine(directory, $"export-{aspect}.txt"),
                $"encoder={result.Encoder}; softwareEncoding={result.SoftwareEncoding}; duration={result.DurationSeconds:F3}; elapsed={result.ElapsedSeconds:F3}; frames={result.Frames}; aacLagSamples={lag}", TestContext.Current.CancellationToken);
            // The decoded RGB limit applies to hardware encoders. The software MF
            // path has its own preencoder RGB and decoded YUV acceptance suite.
            if (aspect == ExportAspect.Source && result.Encoder != EncoderProbe.SoftwareMediaFoundation)
                await VerifyBars(snapshot, path);
        }
        finally { Directory.Delete(directory, true); }
    }

    private static unsafe bool VerifyVideoTiming(string path, double duration, double fps)
    {
        using var input = NativeHandle.Own(Native.Open(path), NativeKind.Input);
        var format = (AVFormatContext*)input.Pointer;
        var stream = format->streams[Native.Stream(format, AVMediaType.AVMEDIA_TYPE_VIDEO)];
        Assert.Equal(duration, Native.Seconds(stream->duration, stream->time_base), 5);
        Assert.Equal(fps, ffmpeg.av_q2d(stream->avg_frame_rate), 5);
        return true;
    }

    [Fact]
    public async Task FourKExportIsCappedAt1080p()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(NativePipelineTests.Fixture("bars-4k.mkv"), TestContext.Current.CancellationToken);
        var total = (long)Math.Round(info.DurationSeconds * 48_000);
        var snapshot = new ComposeSnapshot(info, TestPlan.FromKept(48_000, total, [new(0, total)]), null, new(new(1920, 1080), 24, 8_000_000));
        var directory = RunDirectory();
        try
        {
            var path = Path.Combine(directory, "cap.mp4");
            var result = await new Exporter().ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, path, null), null, TestContext.Current.CancellationToken);
            Assert.Equal(1920, result.Width); Assert.Equal(1080, result.Height);
            Assert.Equal(new(1920, 1080), (await new FfmpegMediaProbe().ProbeAsync(path, TestContext.Current.CancellationToken)).OrientedSize);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task CancellationDuringComposeDeletesPartialAndDoesNotReplaceDestination()
    {
        var snapshot = await NativePipelineTests.Snapshot();
        var directory = RunDirectory(); var path = Path.Combine(directory, "cancel.mp4");
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        try
        {
            await File.WriteAllTextAsync(path, "untouched", TestContext.Current.CancellationToken);
            var exporter = new Exporter(new CancellingComposer(cancellation), new EncoderProbe());
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => exporter.ExportAsync(new(snapshot, new ExportTarget.FullEdit(), ExportAspect.Source, ExportQuality.Standard, path, null), null, cancellation.Token));
            Assert.False(File.Exists(path + ".partial"));
            Assert.Equal("untouched", await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken));
        }
        finally { Directory.Delete(directory, true); }
    }

    private static Task<bool> VerifyBars(ComposeSnapshot snapshot, string path) => MediaThread.Run("vc-test-bars", () =>
    {
        using var source = new VideoDecoder(snapshot.Media.Path, false);
        using var actual = new VideoDecoder(path, false);
        var first = source.ReadAt(0.1, false, TestContext.Current.CancellationToken);
        var second = actual.ReadAt(0.1, false, TestContext.Current.CancellationToken);
        for (var bar = 0; bar < 7; bar++)
        {
            var offset = (first.Height / 4 * first.Stride) + (int)((bar + 0.5) * first.Width / 7) * 4;
            for (var channel = 0; channel < 3; channel++) Assert.InRange(Math.Abs(first.Pixels.Span[offset + channel] - second.Pixels.Span[offset + channel]), 0, 3);
        }
        return true;
    }, TestContext.Current.CancellationToken);

    private static string RunDirectory()
    { var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName; Directory.CreateDirectory(directory); return directory; }

    private sealed class CancellingComposer(CancellationTokenSource cancellation) : IFrameComposer
    {
        private int count;
        public void Compose(PixelBuffer decoded, PixelBuffer output, ComposeSnapshot snapshot, double editedTime, bool forPreview, CancellationToken ct)
        { output.Pixels.Span.Clear(); if (++count == 2) cancellation.Cancel(); ct.ThrowIfCancellationRequested(); }
    }

    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
