using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Project;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinEditing.EditingFixtureTests;

namespace VoxClip.Core.Tests.Tracks.WinEditing;

public sealed class ReviewParityTests
{
    [Theory]
    [InlineData(22050, 221)]
    [InlineData(11025, 110)]
    public async Task NativeAnalysisAndCacheRoundTripIgnoreNominalFrameHint(int rate, int frameSize)
    {
        using var storage = new TestStorage();
        var frameLength = (double)frameSize / rate;
        var pcm = Enumerable.Repeat(0.25f, frameSize * 12).ToArray();
        var analyzed = EditingAlgorithms.Analyze([pcm], rate);
        Assert.Equal(12, analyzed.Rms.Count);
        Assert.Equal(0.01, analyzed.FrameSeconds);
        Assert.All(analyzed.Rms, level => Assert.Equal(0.25f, level));
        var levels = Enumerable.Repeat(0.001f, 50060).ToArray();
        Array.Fill(levels, 0.5f, 50000, 60);
        var words = new[] { Word("word", "speech", 50010 * frameLength, 50040 * frameLength) };
        var native = new AudioEnvelope(rate, frameLength, levels);
        var refined = EditingAlgorithms.RefineWordBoundaries(words, native);
        Assert.Equal(50000 * frameLength, refined[0].Start);
        Assert.Equal(levels.Length * frameLength, refined[0].End);
        var index = new CacheIndex(storage.Root);
        var key = new string('a', 64);
        await index.TouchAsync(key, levels.Length * sizeof(float), new(rate, 0.01, levels.Length), TestContext.Current.CancellationToken);
        var file = Path.Combine(storage.Root, key, "envelope-10ms.f32");
        using (var writer = new BinaryWriter(File.Create(file)))
            foreach (var level in levels) writer.Write(level);
        var metadata = Assert.Single(await index.ReadAsync(TestContext.Current.CancellationToken)).Envelope!;
        using var reader = new BinaryReader(File.OpenRead(file));
        var cached = new AudioEnvelope(metadata.SampleRate, metadata.FrameSeconds, Enumerable.Range(0, metadata.Count).Select(_ => reader.ReadSingle()).ToArray());
        Assert.Equal(refined, EditingAlgorithms.RefineWordBoundaries(words, cached));
        Assert.Equal(EditingImport.TightenIntoSound(words, native, TimingSource.Dtw), EditingImport.TightenIntoSound(words, cached, TimingSource.Dtw));
        Assert.Equal(EditingImport.FindUnlabeledSpeech(words, native), EditingImport.FindUnlabeledSpeech(words, cached));
        Assert.Equal(frameLength, EditingAlgorithms.AnalyzeItems(words, cached, null)!.FrameLength);
        Assert.Equal(levels.Length * frameLength, EditingAlgorithms.AnalyzeItems(words, cached, null)!.Total);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void LevelAnalysisRejectsNonpositiveRates(int rate)
        => Assert.Throws<ArgumentOutOfRangeException>(() => EditingAlgorithms.RefineWordBoundaries([Word("word", "speech", 0, 1)], new(rate, 0.01, new float[10])));

    [Fact]
    public void CorrectionsRunIgnoredChecksBeforeLimitsAndNeverChangeSourceTimes()
    {
        var overlong = new string('x', 201);
        var state = State([Word("word", "original", 0, 1), Word("event", "(laugh)", 1, 2) with { Kind = WordKind.Event }]);
        foreach (var correction in new[] { new EditOperation.Correct("event", overlong), new EditOperation.Correct("missing", overlong),
            new EditOperation.Correct("word", " \t "), new EditOperation.Correct("word", "original"), new EditOperation.Correct("word", overlong) })
            Assert.Same(state, EditingEngine.Reduce(state, correction));
        var corrected = EditingEngine.Reduce(state, new EditOperation.Correct("word", "changed"));
        Assert.Empty(EditingEngine.Reduce(corrected, new EditOperation.Correct("word", "original")).Corrections);
        Assert.Same(state.Transcript, corrected.Transcript);
    }

    [Theory]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    [InlineData(double.NegativeInfinity)]
    [InlineData(-1)]
    [InlineData(11)]
    public void InvalidPauseParametersAreIgnored(double seconds)
    {
        var state = State([Word("word", "speech", 0, 1)]);
        Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.SetPauseKeep(seconds)));
        Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.SetPauseThreshold(seconds)));
    }

    [Fact]
    public void InvalidAiClipDoesNotAbortTheRemainingBatchOrChangeResultIndices()
    {
        var state = State([Word("first", "one", 0, 1), Word("second", "two", 2, 3)]);
        var result = EditingEngine.Reduce(state, new EditOperation.AddAiClips("result", [new AiClip(new string('x', 121), "", 8, "first", "first"),
            new AiClip("valid", "", 8, "second", "second")]));
        var clip = Assert.Single(result.Clips);
        Assert.Equal("second", clip.StartWordId);
        Assert.Equal(1, clip.AiClipIndex);
        var history = new EditHistory(state, [], []).Apply(new EditOperation.AddAiClips("result", [new AiClip("valid", "", 8, "second", "second")]));
        Assert.Same(state, Assert.Single(history.UndoStack));
        Assert.Single(history.Present.Clips);
        Assert.Same(state, history.Undo().Present);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(0.5)]
    [InlineData(1)]
    public void PauseParameterBoundariesRemainValid(double seconds)
    {
        var state = State([Word("word", "speech", 0, 1)]);
        Assert.Equal(seconds, EditingEngine.Reduce(state, new EditOperation.SetPauseKeep(seconds)).PauseKeepSeconds);
        if (seconds == 0) Assert.Same(state, EditingEngine.Reduce(state, new EditOperation.SetPauseThreshold(seconds)));
        else Assert.Equal(seconds, EditingEngine.Reduce(state, new EditOperation.SetPauseThreshold(seconds)).PauseThresholdSeconds);
    }
}
