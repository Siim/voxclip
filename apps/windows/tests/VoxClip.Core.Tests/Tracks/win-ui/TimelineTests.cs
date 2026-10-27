#if WIN_UI_TESTS
using VoxClip.App.Services;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Media;
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
            Assert.Equal(1, extractor.Calls);
            Assert.Empty(await service.GetAsync(media with { Audio = null }, key, CancellationToken.None));
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.GetAsync(media, key, cancelled.Token));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

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
