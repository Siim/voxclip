using System.Net;
using System.Net.Sockets;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Ffmpeg;
using VoxClip.Media.Pipeline;
using Xunit;

namespace VoxClip.Media.Tests;

[Trait("Category", "RequiresFFmpeg")]
public sealed class NativeMediaConformanceTests : IAsyncLifetime
{
    public async ValueTask InitializeAsync() => await NativeTest.RequireAsync();
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    [Fact]
    public async Task ProbeUsesTheAudioPresentationEndRatherThanLongerVideo()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture("unequal-duration.mp4"), TestContext.Current.CancellationToken);
        Assert.InRange(info.DurationSeconds, 4.009, 4.011);
        var directory = RunDirectory();
        try
        {
            var result = await new FfmpegAudioExtractor().ExtractAsync(new(info, "unequal", directory), null, TestContext.Current.CancellationToken);
            Assert.Equal((long)Math.Floor(info.DurationSeconds * 16_000 + 0.5), result.Audio.SampleCount);
            Assert.Equal(401, result.Envelope.Rms.Count);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task VideoOnlyDurationUsesVideoAndExtractionReportsNoAudio()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture("bars-4k.mkv"), TestContext.Current.CancellationToken);
        Assert.Null(info.Audio);
        Assert.InRange(info.DurationSeconds, 0.249, 0.251);
        var directory = RunDirectory();
        try
        {
            var error = await Assert.ThrowsAsync<VoxClipException>(() => new FfmpegAudioExtractor().ExtractAsync(
                new(info, "no-audio", directory), null, TestContext.Current.CancellationToken));
            Assert.Equal(VoxClipErrorCode.NoAudioTrack, error.Code);
            Assert.Equal("This video has no audio track, so there is nothing to transcribe.", error.Message);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task StereoExtractionIsAnEqualWeightAverageWithoutClipping()
    {
        var info = await new FfmpegMediaProbe().ProbeAsync(NativeTest.Fixture("stereo-average.mkv"), TestContext.Current.CancellationToken);
        var directory = RunDirectory();
        try
        {
            var result = await new FfmpegAudioExtractor().ExtractAsync(new(info, "stereo", directory), null, TestContext.Current.CancellationToken);
            var bytes = await File.ReadAllBytesAsync(result.Audio.Wav16kPath, TestContext.Current.CancellationToken);
            for (var sample = 1000; sample < 2000; sample++) Assert.InRange((int)BitConverter.ToInt16(bytes, 44 + sample * 2), 16383, 16385);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("coarse-clock.mkv")]
    [InlineData("coarse-clock-nocues.mkv")]
    public async Task CoarseClockSeeksDecodeOnlyThePrerollAndPreserveHalfTickAlignment(string file)
    {
        var path = NativeTest.Fixture(file);
        await MediaThread.Run("vc-test-coarse-seek", () =>
        {
            using var original = new AudioDecoder(path);
            var source = new float[60 * 48_000];
            original.Read(source, source.Length, TestContext.Current.CancellationToken);
            foreach (var seconds in new[] { 55, 3, 50 })
            {
                using var seeking = new AudioDecoder(path);
                seeking.Seek(55 * 48_000);
                seeking.Read(new float[4096], 4096, TestContext.Current.CancellationToken);
                var before = seeking.PacketsRead;
                var bytesBefore = seeking.BytesRead;
                seeking.Seek(seconds * 48_000);
                var actual = new float[4096];
                seeking.Read(actual, actual.Length, TestContext.Current.CancellationToken);
                Assert.InRange(seeking.PacketsRead - before, 1, 80);
                Assert.InRange(seeking.BytesRead - bytesBefore, 0, new FileInfo(path).Length / 20 - 1);
                var bestError = double.PositiveInfinity;
                for (var lag = -24; lag <= 24; lag++)
                {
                    double error = 0;
                    for (var sample = 0; sample < actual.Length; sample++)
                        error += Math.Pow(source[seconds * 48_000 + sample + lag] - actual[sample], 2);
                    bestError = Math.Min(bestError, error / actual.Length);
                }
                Assert.InRange(bestError, 0, 1e-10);
            }
            return true;
        }, TestContext.Current.CancellationToken);
    }

    [Theory]
    [InlineData("hdr-limited.mkv")]
    [InlineData("hdr-full.mkv")]
    public async Task HdrBlackPreservesRangeMetadataAndUsesTheAvailableDecodePath(string file)
    {
        var path = NativeTest.Fixture(file);
        await MediaThread.Run("vc-test-hdr-black", () => ToneMapBlack(path), TestContext.Current.CancellationToken);
    }

    private static unsafe bool ToneMapBlack(string path)
    {
        using var decoder = new DecodeSession(path, AVMediaType.AVMEDIA_TYPE_VIDEO);
        Assert.True(decoder.Next(TestContext.Current.CancellationToken));
        var full = Path.GetFileName(path) == "hdr-full.mkv";
        Assert.Equal(full ? AVColorRange.AVCOL_RANGE_JPEG : AVColorRange.AVCOL_RANGE_MPEG, decoder.Frame->color_range);
        Assert.Equal(full ? 0 : 64, *(ushort*)decoder.Frame->data[0]);
        if (!ToneMapper.Available)
        {
            using var video = new VideoDecoder(path, false);
            var pixels = video.ReadAt(0, true, TestContext.Current.CancellationToken);
            Assert.InRange(pixels.Pixels.Span[0], (byte)0, (byte)2);
            return true;
        }
        using var mapper = new ToneMapper(decoder.Frame, decoder.Stream->time_base);
        var frame = mapper.Convert(decoder.Frame);
        Assert.InRange((int)frame->data[0][0], 15, 17);
        return true;
    }

    [Fact]
    public async Task LocalPlaylistCannotFetchNetworkSegments()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var directory = RunDirectory();
        var path = Path.Combine(directory, "network.m3u8");
        try
        {
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            await File.WriteAllTextAsync(path, $"#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nhttp://127.0.0.1:{port}/segment.ts\n#EXT-X-ENDLIST\n", TestContext.Current.CancellationToken);
            await Assert.ThrowsAsync<MediaException>(() => new FfmpegMediaProbe().ProbeAsync(path, TestContext.Current.CancellationToken)
                .WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
            Assert.False(listener.Pending());
        }
        finally { Directory.Delete(directory, true); }
    }

    private static string RunDirectory()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-media-tests-").FullName;
        Directory.CreateDirectory(directory);
        return directory;
    }
}
