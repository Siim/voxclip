using VoxClip.Core.Domain.Frames;
using VoxClip.Media.Frames;
using Xunit;

namespace VoxClip.Media.Tests.Frames;

/// <summary>The frame analyzer on Windows (ADR-R48 Windows, W5), twin of the Mac <c>FrameAnalyzerTests</c>: lanes, the per-source
/// per-millisecond cache, the frame's own time, opening-scan frames without text or quads, and 320 px sheet JPEGs. Frames come from a
/// stub decoder (FFmpeg is Windows CI's), faces and text from stubs.</summary>
public sealed class FrameAnalyzerTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    /// <summary>A cached time is never decoded or looked at again, by this analyzer or another on the same cache; the file is the
    /// Mac's <c>analysis-v2.json</c> and reads back the same.</summary>
    [Fact]
    public async Task ACachedTimeIsNeverDecodedAgainAndTheCacheFileRoundTrips()
    {
        var root = FrameFixtures.TempRoot("cache");
        try
        {
            var decoder = new StubFrameDecoder();
            var faces = new StubFrameFaces();
            var first = await FrameFixtures.Analyzer(decoder, new FrameAnalysisCache(root), faces)
                .ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [1.0, 2.0, 3.0], FrameScanKind.Sentence, Ct);
            Assert.Equal((0, 3, 3), (first.Cached, first.Analyzed, decoder.Reads.Count));

            var again = new StubFrameDecoder();
            var againFaces = new StubFrameFaces();
            var second = await FrameFixtures.Analyzer(again, new FrameAnalysisCache(root), againFaces)
                .ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [1.0, 2.0, 3.0, 4.0, 2.0004], FrameScanKind.Sentence, Ct);
            // 2.0004 is millisecond 2000, cached; only 4.0 is new.
            Assert.Equal([4.0], again.Reads.Select(read => read.Time));
            Assert.Single(againFaces.Threads);
            Assert.Equal((4, 1), (second.Cached, second.Analyzed));
            Assert.Equal(first.Frames.Select(Text), second.Frames.Take(3).Select(Text));
            Assert.Equal(Text(second.Frames[1]), Text(second.Frames[4]));

            // The file: the Mac's schema and keys, and every observation reads back as written.
            var file = Path.Combine(root, FrameFixtures.ContentKey, "frames", FrameAnalysisFile.FileName);
            var text = await File.ReadAllTextAsync(file, Ct);
            var read = FrameAnalysisFile.Read(text);
            Assert.Equal(["0.250:1000", "0.250:2000", "0.250:3000", "0.250:4000"], read.Keys.Order(StringComparer.Ordinal));
            Assert.Equal(text, FrameAnalysisFile.Write(read));
            Assert.Equal(Text(first.Frames[0]), Text(read["0.250:1000"]));
            // The sheet JPEGs are cached by each frame's own time.
            Assert.True(File.Exists(Path.Combine(root, FrameFixtures.ContentKey, "frames", "sheet-4000.jpg")));

            // The opening pass is its own: a sentence frame is not an opening frame.
            var opening = new StubFrameDecoder();
            await FrameFixtures.Analyzer(opening, new FrameAnalysisCache(root)).ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [1.0], FrameScanKind.Opening, Ct);
            Assert.Single(opening.Reads);
            Assert.Contains("0.033:1000", FrameAnalysisFile.Read(await File.ReadAllTextAsync(file, Ct)).Keys);
        }
        finally { Directory.Delete(root, true); }
    }

    /// <summary>Without a cache, every time is decoded each time.</summary>
    [Fact]
    public async Task WithoutACacheEveryTimeIsLookedAtAgain()
    {
        var decoder = new StubFrameDecoder();
        var analyzer = FrameFixtures.Analyzer(decoder, null);
        await analyzer.ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [1.0, 2.0], FrameScanKind.Sentence, Ct);
        var second = await analyzer.ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [1.0, 2.0], FrameScanKind.Sentence, Ct);
        Assert.Equal((0, 2, 4), (second.Cached, second.Analyzed, decoder.Reads.Count));
    }

    /// <summary>Tolerance: the decoder is opened at 1,280 px with the pass's tolerance, and each observation carries the frame's own time,
    /// while it is cached and returned under the time asked for.</summary>
    [Fact]
    public async Task AnObservationCarriesTheFramesOwnTime()
    {
        var root = FrameFixtures.TempRoot("own-time");
        try
        {
            var decoder = new StubFrameDecoder { Offset = 0.2 };
            var found = await FrameFixtures.Analyzer(decoder, new FrameAnalysisCache(root))
                .ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [3.0, 1.0], FrameScanKind.Sentence, Ct);
            Assert.Equal([3.2, 1.2], found.Frames.Select(frame => frame.Time));
            Assert.Equal([1200L, 3200L], found.Jpegs.Keys.Order());
            Assert.All(decoder.Opens, open => Assert.Equal((FrameAnalyzer.AnalysisEdge, FrameAnalyzer.SentenceTolerance), (open.Edge, open.Tolerance)));
            var cached = new FrameAnalysisCache(root).Observations(FrameFixtures.ContentKey, "0.250");
            Assert.Equal([1000L, 3000L], cached.Keys.Order());
            Assert.Equal(3.2, cached[3000].Time);

            var opening = new StubFrameDecoder { Offset = -0.02 };
            var scan = await FrameFixtures.Analyzer(opening, null).ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [0.5], FrameScanKind.Opening, Ct);
            Assert.Equal(0.48, Assert.Single(scan.Frames).Time, 12);
            Assert.Equal((FrameAnalyzer.AnalysisEdge, 1.0 / 30), (Assert.Single(opening.Opens).Edge, opening.Opens.Single().Tolerance));
            Assert.Equal(("0.250", "0.033"), (FrameAnalysisFile.Pass(FrameAnalyzer.SentenceTolerance), FrameAnalysisFile.Pass(FrameAnalyzer.OpeningTolerance)));
        }
        finally { Directory.Delete(root, true); }
    }

    /// <summary>Four lanes run at once, each on its own thread with its own screen scan (its own QuadFinder, which is not thread-safe), and
    /// each reads a contiguous, ordered run of the times.</summary>
    [Fact]
    public async Task LanesRunConcurrentlyWithOneScreenScanEach()
    {
        using var together = new Barrier(FrameAnalyzer.Lanes);
        var decoder = new StubFrameDecoder { Together = together };
        var text = new StubFrameText();
        var scans = new System.Collections.Concurrent.ConcurrentQueue<int>();
        var analyzer = FrameFixtures.Analyzer(decoder, null, screens: () =>
        {
            scans.Enqueue(Environment.CurrentManagedThreadId);
            return new FrameScreenScan(text, new QuadFinder());
        });
        double[] times = [8, 1, 7, 2, 6, 3, 5, 4];
        var found = await analyzer.ObservationsAsync("in.mp4", FrameFixtures.ContentKey, times, FrameScanKind.Sentence, Ct);
        Assert.False(decoder.TogetherTimedOut, "the lanes did not run at once");
        Assert.Equal(times, found.Frames.Select(frame => frame.Time));
        Assert.Equal(FrameAnalyzer.Lanes, decoder.Opens.Count);
        Assert.Equal(FrameAnalyzer.Lanes, scans.Count);
        Assert.Equal(FrameAnalyzer.Lanes, scans.Distinct().Count());
        Assert.Equal(scans.Order(), decoder.Opens.Select(open => open.Thread).Order());
        Assert.All(text.Threads, thread => Assert.Contains(thread, scans));
        var runs = decoder.Reads.GroupBy(read => read.Thread).Select(lane => lane.Select(read => read.Time).ToArray()).OrderBy(run => run[0]).ToArray();
        Assert.Equal([[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [7.0, 8.0]], runs);
    }

    /// <summary>A lane's failure is the analyzer's, not the cancellation it causes in the other lanes.</summary>
    [Fact]
    public async Task ALanesFailureIsReportedAsItself()
    {
        var decoder = new StubFrameDecoder { Failure = time => time == 5 ? new InvalidDataException("bad frame") : null };
        var error = await Assert.ThrowsAsync<InvalidDataException>(() =>
            FrameFixtures.Analyzer(decoder, null).ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [1, 2, 3, 4, 5, 6, 7, 8], FrameScanKind.Sentence, Ct));
        Assert.Equal("bad frame", error.Message);
    }

    /// <summary>Opening-scan frames get faces but no text or quads (the speed lever), and no sheet JPEG; sentence frames get all three.</summary>
    [Fact]
    public async Task OpeningScanFramesGetNoTextOrQuads()
    {
        var text = new StubFrameText();
        var faces = new StubFrameFaces();
        var analyzer = FrameFixtures.Analyzer(new StubFrameDecoder(), null, faces, text);
        var clip = FrameClip.Make(FrameFixtures.Words, 0, 3, new HashSet<string>())!;
        var result = await analyzer.AnalyzeAsync("in.mp4", FrameFixtures.ContentKey, clip, Ct);
        Assert.Equal(2, result.Analysis.Sentences.Count);
        Assert.Equal(13, result.Analysis.Opening.Count);
        Assert.Equal((0, 15), (result.Analysis.Timings.CachedFrames, result.Analysis.Timings.AnalyzedFrames));
        Assert.Equal(2, text.Threads.Count);
        Assert.Equal(15, faces.Threads.Count);
        Assert.All(result.Analysis.Opening, frame =>
        {
            Assert.Empty(frame.TextRects);
            Assert.Empty(frame.Screens);
            Assert.Equal((1, StubFrameFaces.Face), (frame.FaceCount, frame.Face));
        });
        Assert.All(result.Analysis.Sentences, frame => Assert.Equal(StubFrameText.Lines, frame.TextRects));
        Assert.Equal(2, result.Sheet.Frames.Count);
        var opening = await analyzer.ObservationsAsync("in.mp4", FrameFixtures.ContentKey, [0.5], FrameScanKind.Opening, Ct);
        Assert.Empty(opening.Jpegs);
    }

    /// <summary>Sheet JPEGs are 320 px on the long edge, never scaled up, from the analysis frame or a frame decoded at the sheet's size.</summary>
    [Theory]
    [InlineData(1280, 720, 320, 180)]
    [InlineData(720, 1280, 180, 320)]
    [InlineData(200, 100, 200, 100)]
    [InlineData(320, 240, 320, 240)]
    public async Task SheetJpegsAre320OnTheLongEdgeAndNeverUpscaled(int width, int height, int sheetWidth, int sheetHeight)
    {
        var decoder = new StubFrameDecoder(width, height);
        var analyzer = FrameFixtures.Analyzer(decoder, null);
        var clip = FrameClip.Make(FrameFixtures.Words, 0, 3, new HashSet<string>())!;
        var result = await analyzer.AnalyzeAsync("in.mp4", FrameFixtures.ContentKey, clip, Ct);
        Assert.All(result.Sheet.Frames, frame =>
        {
            Assert.Equal((sheetWidth, sheetHeight), (frame.Image.Width, frame.Image.Height));
            Assert.Equal(new(sheetWidth, sheetHeight), FrameJpeg.Size(frame.Image.Data));
            Assert.Equal("image/jpeg", frame.Image.MediaType);
            Assert.Equal([0xFF, 0xD8, 0xFF], frame.Image.Data.Take(3));
        });
        // A sheet of frames with no JPEG yet decodes them at the sheet's size.
        var sheet = await analyzer.SheetAsync("in.mp4", FrameFixtures.ContentKey, [new FrameObservation(1.5)], null, Ct);
        Assert.Equal((sheetWidth, sheetHeight), (sheet.Frames[0].Image.Width, sheet.Frames[0].Image.Height));
        Assert.Contains(decoder.Opens, open => open.Edge == FrameSheet.FrameEdge);
    }

    [Fact]
    public void FitScalesTheLongSideDownAndNeverUp()
    {
        Assert.Equal(new(1280, 720), FfmpegFrameDecoder.Fit(3840, 2160, 1280));
        Assert.Equal(new(720, 1280), FfmpegFrameDecoder.Fit(2160, 3840, 1280));
        Assert.Equal(new(640, 360), FfmpegFrameDecoder.Fit(640, 360, 1280));
        Assert.Equal(new(320, 213), FfmpegFrameDecoder.Fit(1200, 800, 320));
        Assert.Equal(new(320, 1), FfmpegFrameDecoder.Fit(4000, 2, 320));
    }

    /// <summary>With faces unavailable there is no analyzer, so nothing can report <c>faceCount: 0</c>.</summary>
    [Fact]
    public void WithFacesUnavailableThereIsNoAnalyzer()
    {
        var decoder = new StubFrameDecoder();
        Assert.Throws<FrameFacesUnavailableException>(() => new FrameAnalyzer(null, FrameAnalyzer.ScreensWith(new StubFrameText()), decoder, null));
        Assert.Empty(decoder.Opens);
    }

    private static string Text(FrameObservation frame) => FrameJson.Write(frame).ToJsonString();
}
