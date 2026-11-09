using System.Collections.Concurrent;
using VoxClip.Core.Domain.Frames;
using VoxClip.Media.Frames;
using Xunit;

namespace VoxClip.Media.Tests.Frames;

/// <summary>The whole video's sentence-frame pass beside Find Clips (ADR-R48 part 2), twin of the Mac <c>VideoFramePass</c>: the same
/// sampling, the cache, an unreadable source as text only, and cancellation.</summary>
public sealed class VideoFramePassTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    /// <summary>One frame per sentence of the whole video, once; a clip's frames and sheet then come from the pass without decoding,
    /// and its opening scan runs once per start time.</summary>
    [Fact]
    public async Task AClipsFramesComeFromThePassAndItsOpeningRunsOnce()
    {
        var root = FrameFixtures.TempRoot("pass");
        try
        {
            var decoder = new StubFrameDecoder();
            var analyzer = FrameFixtures.Analyzer(decoder, new FrameAnalysisCache(root));
            var pass = new VideoFramePass(analyzer, "in.mp4", FrameFixtures.ContentKey, FrameFixtures.Words);
            Assert.Equal(2, pass.FrameCount);
            Assert.True(await pass.FinishAsync(Ct));
            Assert.Equal((2, 0), (pass.Analyzed, pass.Cached));
            Assert.NotNull(pass.Seconds);
            Assert.Equal([1.25, 2.6], decoder.Reads.Select(read => Math.Round(read.Time, 9)).Order());

            var clip = FrameClip.Make(FrameFixtures.Words, 2, 3, new HashSet<string>())!;
            var frames = await pass.FramesAsync(clip, Ct);
            Assert.NotNull(frames);
            Assert.Equal([2.6], frames.Sentences.Select(frame => Math.Round(frame.Time, 9)));
            Assert.Single(frames.Sheet.Frames);
            Assert.Equal(2, decoder.Reads.Count);
            Assert.All(decoder.Opens, open => Assert.Equal(FrameAnalyzer.AnalysisEdge, open.Edge));

            var opening = await pass.OpeningAsync(clip, Ct);
            var again = await pass.OpeningAsync(clip, Ct);
            Assert.Same(opening, again);
            Assert.Equal(FrameSampling.OpeningTimes(clip.Start).Count, opening!.Count);
            Assert.Equal(2 + opening.Count, decoder.Reads.Count);
            Assert.Equal(StubFrameFaces.Face.Pitch, await pass.PitchBaselineAsync(Ct));

            // A second pass on the same cache decodes nothing.
            var second = new StubFrameDecoder();
            var cached = new VideoFramePass(FrameFixtures.Analyzer(second, new FrameAnalysisCache(root)), "in.mp4", FrameFixtures.ContentKey, FrameFixtures.Words);
            Assert.True(await cached.FinishAsync(Ct));
            Assert.Equal((0, 2), (cached.Analyzed, cached.Cached));
            Assert.Empty(second.Reads);
        }
        finally { Directory.Delete(root, true); }
    }

    /// <summary>A source the analyzer can't read logs one line, and every clip goes on as text only.</summary>
    [Fact]
    public async Task AnUnreadableSourceLogsOneLineAndClipsGoOnAsTextOnly()
    {
        var lines = new ConcurrentQueue<string>();
        var decoder = new StubFrameDecoder { Failure = _ => new InvalidDataException("no video") };
        var pass = new VideoFramePass(FrameFixtures.Analyzer(decoder, null), "in.mp4", FrameFixtures.ContentKey, FrameFixtures.Words, lines.Enqueue);
        Assert.False(await pass.FinishAsync(Ct));
        Assert.Null(pass.Seconds);
        Assert.Null(await pass.FramesAsync(FrameClip.Make(FrameFixtures.Words, 0, 1, new HashSet<string>())!, Ct));
        Assert.Null(await pass.PitchBaselineAsync(Ct));
        Assert.Equal(["frames: the video's frames can't be read, so plans go as text only (InvalidDataException)"], lines);
        Assert.Null(await pass.OpeningAsync(FrameClip.Make(FrameFixtures.Words, 0, 1, new HashSet<string>())!, Ct));
        Assert.Equal("frames: a clip's opening can't be read (InvalidDataException)", lines.Last());
    }

    /// <summary>Cancel stops the pass while it decodes: it ends unread and logs nothing.</summary>
    [Fact]
    public async Task CancelStopsThePass()
    {
        using var hold = new ManualResetEventSlim();
        var lines = new ConcurrentQueue<string>();
        var decoder = new StubFrameDecoder { Hold = hold };
        var pass = new VideoFramePass(FrameFixtures.Analyzer(decoder, null), "in.mp4", FrameFixtures.ContentKey, FrameFixtures.Words, lines.Enqueue);
        pass.Start();
        Assert.True(decoder.Reading.Wait(TimeSpan.FromSeconds(20), Ct));
        pass.Cancel();
        Assert.False(await pass.FinishAsync(Ct));
        Assert.Empty(lines);
        Assert.Null(await pass.OpeningAsync(FrameClip.Make(FrameFixtures.Words, 0, 1, new HashSet<string>())!, Ct));
    }

    /// <summary>Thumbnails are the sheet's small JPEGs of any times.</summary>
    [Fact]
    public async Task ThumbnailsAreSheetSizedJpegs()
    {
        var pass = new VideoFramePass(FrameFixtures.Analyzer(new StubFrameDecoder(), null), "in.mp4", FrameFixtures.ContentKey, FrameFixtures.Words);
        var thumbnails = await pass.ThumbnailsAsync([0.5, 1.5], Ct);
        Assert.Equal(2, thumbnails.Count);
        Assert.All(thumbnails, jpeg => Assert.Equal(new(320, 180), FrameJpeg.Size(jpeg)));
    }
}
