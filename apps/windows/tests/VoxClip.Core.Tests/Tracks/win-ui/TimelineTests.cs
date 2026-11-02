#if WIN_UI_TESTS
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class TimelineTests
{
    [Theory]
    [InlineData(100, 20, 30, 18.5, 31.5)]
    [InlineData(100, 20, 60, 17, 63)]
    [InlineData(100, 0, 10, 0, 11.5)]
    [InlineData(100, 95, 100, 93.5, 100)]
    public void ScopeZoomPadsAndClamps(double duration, double start, double end, double expectedStart, double expectedEnd)
    {
        var window = TimelineLayout.Window(duration, start, end);
        Assert.Equal(expectedStart, window.Start);
        Assert.Equal(expectedEnd, window.End);
        Assert.Equal(start, window.Time(window.X(start, 800), 800), 8);
    }

    [Fact]
    public void HatchSpacingAndOpacityDistinguishCuts()
    {
        Assert.Equal(6, TimelineLayout.HatchPeriod(false));
        Assert.Equal(9, TimelineLayout.HatchPeriod(true));
        Assert.Equal(0.16, TimelineLayout.CutOpacity(false));
        Assert.Equal(0.1, TimelineLayout.CutOpacity(true));
        Assert.Equal("22 seconds of 2 minutes 10 after cuts, 8 cuts", TimelineLayout.ValueText(22, 130, 8, true));
    }
    [Fact]
    public void ClipBracketsSitFifteenPixelsAboveTheTrackWithCenteredBadges()
    {
        Assert.Equal(15, TimelineLayout.TrackTop - TimelineLayout.BracketTop);
        Assert.Equal(TimelineLayout.BracketTop, TimelineLayout.BadgeTop + 18 / 2.0);
        Assert.True(TimelineLayout.BracketTop + 6 < TimelineLayout.TrackTop);
    }

    [Fact]
    public void KeyboardStepsWordsAndSentences()
    {
        var words = new[] { Word(0, "One"), Word(1, "two."), Word(2, "Three"), Word(3, "four!"), Word(4, "Five") };
        Assert.Equal(1, TimelineLayout.Step(words, 0, 1, false));
        Assert.Equal(2, TimelineLayout.Step(words, 0, 1, true));
        Assert.Equal(2, TimelineLayout.Step(words, 3, -1, true));
        Assert.Equal(0, TimelineLayout.Step(words, 2, -1, true));
        Assert.Equal(4, TimelineLayout.Step(words, 4, 1, true));
        Assert.Equal(-1, TimelineLayout.Step([], 0, 1, false));
    }

    [Fact]
    public void TrimDragCommitsOnlyItsFinalRangeAndUndoesOnce()
    {
        var project = Fixture();
        var model = new EditorViewModel(project with { Edits = project.Edits with { Clips = [], ActiveClipId = null } });
        model.Select(3); model.Select(8, true);
        var id = model.MakeClip()!;
        var before = model.Clips.Single().Clip;
        var range = TimelineLayout.Trim(3, 8, 9, model.Words.Count, false);
        range = TimelineLayout.Trim(range.First, range.Last, 11, model.Words.Count, false);
        Assert.Equal(before, model.Clips.Single().Clip);
        Assert.True(TimelineLayout.CommitTrim(model, id, range.First, range.Last));
        Assert.Equal(model.Words[11].Id, model.Clips.Single().Clip.EndWordId);
        Assert.False(TimelineLayout.CommitTrim(model, id, range.First, range.Last));
        model.Undo();
        Assert.Equal(before, model.Clips.Single().Clip);
        model.Undo();
        Assert.Empty(model.Clips);
    }

    [Fact]
    public void TrimHandlesStepOneWordAndNeverInvert()
    {
        Assert.Equal((3, 9), TimelineLayout.Trim(3, 8, 9, 20, false));
        Assert.Equal((8, 8), TimelineLayout.Trim(3, 8, 19, 20, true));
        Assert.Equal((3, 3), TimelineLayout.Trim(3, 8, -20, 20, false));
    }

    [Fact]
    public void WaveformCombinesFiveNativeBucketsAsRms()
    {
        var result = Waveform.Rms50(new(48000, 0.01, [0, 0, 0, 0, 1, 0.5f, 0.5f]));
        Assert.Equal(2, result.Count);
        Assert.Equal(Math.Sqrt(0.2), result[0], 6);
        Assert.Equal(0.5, result[1]);
        Assert.Empty(Waveform.Rms50(new(48000, 0.01, [])));
        Assert.Throws<ArgumentException>(() => Waveform.Rms50(new(48000, 0.05, [1])));
    }

    [Fact]
    public async Task WaveformReusesNativeCacheAcrossInstancesWithoutDecodingAgain()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-waveform-" + Guid.NewGuid().ToString("N"));
        var extractor = new Extractor();
        var media = new MediaInfo("source.mp4", 1, null, new(48000, 2), new(1920, 1080), null, null, false, 0, 0, 0);
        var key = new string('a', 64);
        try
        {
            var service = new Waveform(extractor, root);
            var levels = await service.GetAsync(media, key, CancellationToken.None);
            Assert.Same(levels, await service.GetAsync(media, key, CancellationToken.None));
            Assert.Equal(levels, await new Waveform(extractor, root).GetAsync(media, key, CancellationToken.None));
            var envelope = Assert.IsType<AudioEnvelope>(await service.GetEnvelopeAsync(media, key, CancellationToken.None));
            Assert.Equal(0.01, envelope.FrameSeconds);
            Assert.Equal(48000, envelope.SampleRate);
            Assert.Equal(10, envelope.Rms.Count);
            Assert.Equal(levels, Waveform.Rms50(envelope));
            Assert.Same(envelope, await service.GetEnvelopeAsync(media, key, CancellationToken.None));
            Assert.Equal(1, extractor.Calls);
            Assert.Empty(await service.GetAsync(media with { Audio = null }, key, CancellationToken.None));
            Assert.Null(await service.GetEnvelopeAsync(media with { Audio = null }, key, CancellationToken.None));
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.GetAsync(media, key, cancelled.Token));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Theory]
    [InlineData(0, 28, 32, 20, 20)]
    [InlineData(1, 36, 44, 24, 24)]
    [InlineData(2, 52, 64, 28, 28)]
    public void V2TracksHaveTheSpecifiedGeometry(int size, double video, double audio, double caption, double effects)
    {
        var geometry = TimelineLayout.Tracks(size, true, true, true);
        Assert.Equal(video, geometry.VideoHeight); Assert.Equal(audio, geometry.AudioHeight);
        Assert.Equal(caption, geometry.CaptionHeight); Assert.Equal(effects, geometry.EffectsHeight);
        Assert.Equal(47, geometry.VideoTop);
        Assert.Equal(geometry.VideoTop + video + 1, geometry.AudioTop);
        Assert.Equal(geometry.AudioTop + audio + 1, geometry.CaptionTop);
        Assert.Equal(geometry.CaptionTop + caption + 1, geometry.EffectsTop);
        var audioOnly = TimelineLayout.Tracks(size, false, false, false);
        Assert.Equal(0, audioOnly.VideoHeight); Assert.Equal(47, audioOnly.AudioTop);
        Assert.Equal(0, audioOnly.CaptionHeight); Assert.Equal(0, audioOnly.EffectsHeight);
    }

    [Fact]
    public void ZoomPreservesThePointerTimeAndPanNeverEscapesTheTake()
    {
        var original = new TimelineWindow(10, 30);
        var zoomed = TimelineLayout.Zoom(original, 100, 2, .25);
        Assert.Equal(10, zoomed.Duration);
        Assert.Equal(original.Time(25, 100), zoomed.Time(25, 100), 10);
        Assert.Equal(new TimelineWindow(0, 10), TimelineLayout.Clamp(new(-20, -10), 100));
        Assert.Equal(new TimelineWindow(90, 100), TimelineLayout.Clamp(new(110, 120), 100));
        Assert.Equal(new TimelineWindow(0, 100), TimelineLayout.Clamp(new(0, 1000), 100));
        Assert.True(double.IsFinite(TimelineLayout.Clamp(new(double.NaN, double.PositiveInfinity), double.NaN).Duration));
    }

    [Fact]
    public void WaveformQueriesRetainPeaksRmsAndRealSilence()
    {
        var waveform = TimelineWaveform.Create([0, .3f, .4f, 0], .01, TestContext.Current.CancellationToken);
        var amplitude = waveform.Query(.01, .03);
        Assert.Equal(.4, amplitude.Peak, 6);
        Assert.Equal(Math.Sqrt((.09 + .16) / 2), amplitude.Rms, 6);
        Assert.Equal(default, waveform.Query(0, .01));
        Assert.Equal(default, waveform.Query(5, 6));
        Assert.Equal(default, waveform.Query(double.NaN, 1));
        Assert.Equal(default, TimelineWaveform.Create([float.NaN, float.PositiveInfinity, -1, .001f], ct: TestContext.Current.CancellationToken).Query(0, 1));
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => TimelineWaveform.Create([], .05, cancelled.Token));
        Assert.Throws<ArgumentOutOfRangeException>(() => TimelineWaveform.Create([], 0, TestContext.Current.CancellationToken));
    }

    [Fact]
    public void MediaTilesRippleCutsAndGhostOnlyTheExactRemovedSourceRange()
    {
        var cache = new TimelineTileCache();
        var waveform = TimelineWaveform.Create(Enumerable.Repeat(.4f, 200).ToArray(), ct: TestContext.Current.CancellationToken);
        var plan = TilePlan();
        var source = cache.Get(plan, waveform, new(0, 10), 1000, false);
        var edited = cache.Get(plan, waveform, new(0, 8), 1000, true);
        Assert.Equal(new TimelineMark(200, 0, 200, 30), Assert.Single(source.Gaps));
        Assert.NotEmpty(source.GhostPeaks);
        Assert.All(source.GhostPeaks, mark => Assert.True(mark.X >= 200 && mark.X + mark.Width <= 400));
        Assert.Empty(edited.Gaps); Assert.Empty(edited.GhostPeaks);
        Assert.Equal(250, Assert.Single(edited.Seams).X);
        Assert.Equal(2, edited.Video.Length);
        Assert.Equal(edited.Video[0].X + edited.Video[0].Width, edited.Video[1].X);
        Assert.NotEmpty(edited.Core);
        var silence = cache.Get(plan, TimelineWaveform.Create(new float[200], ct: TestContext.Current.CancellationToken), new(0, 8), 1000, true);
        Assert.Empty(silence.Peaks); Assert.Empty(silence.Core);
    }

    [Fact]
    public void RetainedMediaIncludesRoomToneBetweenWordsAndCachesOnlyEightViewports()
    {
        var cache = new TimelineTileCache();
        var plan = new EditPlan(1000, 10000, [], [new(0, 10000)], 10000, []);
        var waveform = TimelineWaveform.Create(Enumerable.Repeat(.4f, 200).ToArray(), ct: TestContext.Current.CancellationToken);
        var first = cache.Get(plan, waveform, new(0, 10), 800, true);
        Assert.Equal(800, Assert.Single(first.Video).Width);
        Assert.NotEmpty(first.Peaks);
        for (var index = 0; index < 32; index++) Assert.Same(first, cache.Get(plan, waveform, new(0, 10), 800, true));
        Assert.Equal(1, cache.Builds);
        for (var index = 0; index < 32; index++) cache.Get(plan, waveform, new(index / 10.0, index / 10.0 + 1), 800, true);
        Assert.Equal(TimelineTileCache.Capacity, cache.Count);
        var changed = plan with { };
        Assert.NotSame(first, cache.Get(changed, waveform, new(0, 10), 800, true));
        Assert.Equal(1, cache.Count);
    }

    [Fact]
    public void FilmstripIsBoundedAndNeverSamplesACutOrBeyondAPiece()
    {
        var pieces = new TimelinePieces(new RenderTimeline.Legacy(TilePlan()));
        var slots = new TimelineThumbnailSlot[TimelineFilmstrip.Limit];
        foreach (var axis in new[] { TimelineAxis.Edited, TimelineAxis.Source })
        {
            var count = TimelineFilmstrip.Fill(slots, pieces, new(0, axis == TimelineAxis.Edited ? 8 : 10), 4000, axis);
            Assert.InRange(count, 1, TimelineFilmstrip.Limit);
            Assert.All(slots.Take(count), slot =>
            {
                Assert.True(slot.Width > 0 && slot.X >= 0 && slot.X + slot.Width <= 4000);
                Assert.True(slot.SourceTime >= 0 && slot.SourceTime < 10 && (slot.SourceTime < 2 || slot.SourceTime >= 4));
            });
        }
        var thin = new TimelinePieces([new(new(4.021, 4.022), new(0, .001))]);
        var thinCount = TimelineFilmstrip.Fill(slots, thin, new(0, .001), 100, TimelineAxis.Edited);
        Assert.InRange(thinCount, 1, TimelineFilmstrip.Limit);
        Assert.All(slots.Take(thinCount), slot => Assert.True(slot.SourceTime >= 4.021 && slot.SourceTime < 4.022));
        var synthetic = new TimelinePieces([new(new(0, 2), new(0, 2), TimelinePieceKind.Ai), new(new(5, 7), new(2, 4))]);
        var syntheticCount = TimelineFilmstrip.Fill(slots, synthetic, new(0, 4), 1000, TimelineAxis.Edited);
        Assert.True(syntheticCount > 0);
        Assert.All(slots.Take(syntheticCount), slot => Assert.True(slot.SourceTime >= 5 && slot.SourceTime < 7));
    }

    [Theory]
    [InlineData("one two three", 23, "")]
    [InlineData("one two three", 24, "one")]
    [InlineData("one two three", 40, "one …")]
    [InlineData("one two three", 100, "one two three")]
    [InlineData("unbreakable words", 24, "")]
    public void CaptionLabelsFitWholeWordsRatherThanClipping(string text, double width, string expected)
        => Assert.Equal(expected, TimelineLayout.FitWords(text, width, candidate => candidate.Length * 5));

    [Fact]
    public void TrimRefusesUnavailableMediaBusyStateAndInvalidIndices()
    {
        var project = Fixture();
        var model = new EditorViewModel(project with { Edits = project.Edits with { Clips = [], ActiveClipId = null, CutWordIds = [], CutPauseIds = [] } });
        model.Select(0); model.Select(3, true); var id = model.MakeClip()!;
        var before = model.Clips.Single(clip => clip.Id == id).Clip;
        Assert.False(TimelineLayout.CommitTrim(model, id, -1, 3));
        Assert.False(TimelineLayout.CommitTrim(model, id, 0, model.Words.Count));
        model.Busy = true; Assert.False(TimelineLayout.CommitTrim(model, id, 0, 4)); model.Busy = false;
        model.SetMediaUnavailable(true); Assert.False(TimelineLayout.CommitTrim(model, id, 0, 4));
        Assert.Equal(before, model.Clips.Single(clip => clip.Id == id).Clip);
    }

    [Fact]
    public void ClocksReuseSharedSmpteStringsWithoutPerTickFormatting()
    {
        var model = new EditorViewModel(Fixture());
        var viewport = new TimelineViewportState(); viewport.Reset(model);
        var plan = TimelineLayout.Plan(model); viewport.Prepare(plan);
        var second = Math.Min(2, (int)Math.Floor(plan.Duration));
        var expected = SMPTETimecode.String(second + .5, viewport.FrameRate);
        Assert.Equal(expected, viewport.DimClock(second + .5) + viewport.Clock(second + .5) + viewport.Frames(second + .5));
        var boundary = .999999999;
        Assert.Equal(SMPTETimecode.String(boundary, viewport.FrameRate), viewport.DimClock(boundary) + viewport.Clock(boundary) + viewport.Frames(boundary));
        var clock = viewport.Clock(second + .1);
        for (var index = 0; index < 64; index++)
        { viewport.Prepare(plan); Assert.Same(clock, viewport.Clock(second + .9)); }
    }

    [Fact]
    public async Task TimelineFrameCacheRetainsItsLeaseUntilTheImageRetires()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-timeline-cache-" + Guid.NewGuid().ToString("N"));
        var key = new string('b', 64); var reads = 0;
        var service = new Thumbnails(root, timelineRead: (_, _, _, _) => { reads++; return Task.FromResult(new byte[] { 1, 2, 3 }); });
        try
        {
            var first = Assert.IsType<Thumbnails.FrameLease>(await service.GetTimelineAsync(key, "unused.mp4", 4.021, 90, CancellationToken.None));
            Assert.True(CacheKeyRegistry.Shared(root).IsLeased(key));
            var second = Assert.IsType<Thumbnails.FrameLease>(await service.GetTimelineAsync(key, "unused.mp4", 4.021, 450, CancellationToken.None));
            Assert.Equal(first.Path, second.Path); Assert.Equal(1, reads);
            first.Dispose(); Assert.True(CacheKeyRegistry.Shared(root).IsLeased(key));
            second.Dispose(); second.Dispose(); Assert.False(CacheKeyRegistry.Shared(root).IsLeased(key));
            Assert.Null(service.TimelinePathFor("../escape", 1, 0));
            Assert.Null(service.TimelinePathFor(key, double.NaN, 0));
            Assert.Null(service.TimelinePathFor(key, -1, 0));
            Assert.Empty(Directory.EnumerateFiles(root, "*.tmp", SearchOption.AllDirectories));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public async Task TimelineFrameCancellationDiscardsALateDecoderWithoutPublishingOrLeakingALease()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-timeline-cancel-" + Guid.NewGuid().ToString("N"));
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var key = new string('c', 64);
        var service = new Thumbnails(root, timelineRead: (_, _, _, _) => { entered.SetResult(); return resume.Task; });
        using var cancelled = new CancellationTokenSource();
        try
        {
            var pending = service.GetTimelineAsync(key, "unused.mp4", 1, 0, cancelled.Token);
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
            Assert.True(CacheKeyRegistry.Shared(root).IsLeased(key));
            cancelled.Cancel(); resume.SetResult([1, 2, 3]);
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
            Assert.False(CacheKeyRegistry.Shared(root).IsLeased(key));
            Assert.False(File.Exists(service.TimelinePathFor(key, 1, 0)));
            Assert.Empty(Directory.EnumerateFiles(root, "*.tmp", SearchOption.AllDirectories));
        }
        finally { resume.TrySetResult([]); if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public async Task TimelineDecodesNeverExceedTwoAndQueuedRequestsHoldNoLease()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-timeline-bound-" + Guid.NewGuid().ToString("N"));
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var active = 0; var maximum = 0; var reads = 0;
        var service = new Thumbnails(root, timelineRead: async (_, _, _, _) =>
        {
            var current = Interlocked.Increment(ref active);
            int observed;
            do { observed = Volatile.Read(ref maximum); }
            while (current > observed && Interlocked.CompareExchange(ref maximum, current, observed) != observed);
            if (Interlocked.Increment(ref reads) == 2) entered.TrySetResult();
            try { await release.Task; return new byte[] { 1, 2, 3 }; }
            finally { Interlocked.Decrement(ref active); }
        });
        var keys = Enumerable.Range(0, 6).Select(index => new string((char)('a' + index), 64)).ToArray();
        var tasks = keys.Select((key, index) => service.GetTimelineAsync(key, "unused.mp4", index, 0, CancellationToken.None)).ToArray();
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
            Assert.Equal(2, Volatile.Read(ref reads));
            Assert.Equal(2, CacheKeyRegistry.Shared(root).LeasedKeys.Count);
            release.TrySetResult();
            var leases = await Task.WhenAll(tasks);
            Assert.Equal(2, maximum);
            foreach (var lease in leases) Assert.IsType<Thumbnails.FrameLease>(lease).Dispose();
            Assert.Empty(CacheKeyRegistry.Shared(root).LeasedKeys);
        }
        finally
        {
            release.TrySetResult();
            foreach (var task in tasks)
                try { (await task)?.Dispose(); } catch (Exception) { }
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static EditPlan TilePlan() => new(1000, 10000, [new(2000, 4000)], [new(0, 2000), new(4000, 10000)], 8000, []);
    private static TimedWord Word(int index, string text) => new($"w{index}", text, WordKind.Word, index, index + 0.8, null, null, null, null, TimingSource.Native);
    private static Project Fixture()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var file = Path.Combine(directory.FullName, "shared", "fixtures", "projects", "clip-from-long-take.voxclip");
            if (File.Exists(file)) return ProjectSerialization.Deserialize(File.ReadAllText(file));
        }
        throw new FileNotFoundException("Shared project fixture not found.");
    }

    private sealed class Extractor : IAudioExtractor
    {
        internal int Calls;
        public async Task<AudioExtractionResult> ExtractAsync(AudioExtractionRequest request, IProgress<MediaProgress>? progress, CancellationToken ct)
        {
            Calls++;
            Directory.CreateDirectory(request.CacheDirectory);
            var bytes = Enumerable.Repeat(0.5f, 10).SelectMany(BitConverter.GetBytes).ToArray();
            await File.WriteAllBytesAsync(Path.Combine(request.CacheDirectory, "envelope-10ms.f32"), bytes, ct);
            return new(new("unused.wav", 1600, 0.1, 0, 0), new(48000, 0.01, Enumerable.Repeat(0.5f, 10).ToArray()));
        }
    }
}
#endif
