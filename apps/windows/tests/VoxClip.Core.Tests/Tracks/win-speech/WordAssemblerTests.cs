using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Transcript;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class WordAssemblerTests
{
    private static RawToken Token(string text, bool joins = false, double? start = 0.1, double? end = 0.3,
        double? confidence = 0.8, int group = 0, WordKind? kind = null) => new(text, joins, start, end, confidence, "speaker_0", kind, group);

    [Fact]
    public void JoinsSubwordsAndAddsPresentationOffsetOnce()
    {
        var words = WordAssembler.Group([Token("õh"), Token("tu", true, 0.2, 0.4), Token("tere", false, 0.5, 0.8)],
            new(GroupingEnd.LastToken, GroupingConfidence.Mean, false), 0.5);
        Assert.Equal(new[] { "õhtu", "tere" }, words.Select(word => word.Text));
        Assert.Equal(0.6, words[0].Start);
        Assert.Equal(0.9, words[0].End);
        Assert.Equal("speaker_0", words[0].Speaker);
    }

    [Theory]
    [InlineData(GroupingConfidence.Single, 0.8)]
    [InlineData(GroupingConfidence.Mean, 0.5)]
    [InlineData(GroupingConfidence.Min, 0.2)]
    public void AggregatesConfidenceIgnoringMissingValues(GroupingConfidence confidence, double expected)
    {
        var word = Assert.Single(WordAssembler.Group([Token("hello"), Token("there", true, confidence: null), Token("!", true, confidence: 0.2)],
            new(GroupingEnd.LastToken, confidence, false), 0));
        Assert.Equal(expected, word.Conf!.Value, 12);
    }

    [Fact]
    public void NextStartSkipsPunctuationAndUntimedDraftsAndStopsAtGroupBoundary()
    {
        var words = WordAssembler.Group([Token("one"), Token(",", start: 0.35), Token("unknown", start: null),
            Token("two", start: 0.9, end: 0.91), Token("three", true, 2, 3, group: 1)],
            new(GroupingEnd.NextWordStart, GroupingConfidence.Mean, false), 0);
        Assert.Equal(0.9, words[0].End);
        Assert.Equal(0.94, words[3].End!.Value, 12);
        Assert.Equal("three", words[4].Text);
    }

    [Fact]
    public void UnknownTimingAndConfidenceStayNull()
    {
        var word = Assert.Single(WordAssembler.Group([Token("unknown", start: null, end: null, confidence: null)],
            new(GroupingEnd.NextWordStart, GroupingConfidence.Mean, false), 0.5));
        Assert.Null(word.Start); Assert.Null(word.End); Assert.Null(word.Conf);
    }

    [Fact]
    public void ExplicitEventsNeverJoinAdjacentWords()
    {
        var words = WordAssembler.Group([Token("hello"), Token("(laughs)", true, kind: WordKind.Event), Token("today", true)],
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), 0);
        Assert.Equal(3, words.Count);
        Assert.Equal(WordKind.Event, words[1].Kind);
    }

    [Theory]
    [InlineData("[laughs]", true)]
    [InlineData("(applause)", true)]
    [InlineData("[BLANK_AUDIO]", false)]
    [InlineData("[silence]", false)]
    [InlineData("[NO_SPEECH]", false)]
    [InlineData("(music)", false)]
    [InlineData("[inaudible]", false)]
    [InlineData("♪ ♫", false)]
    public void BracketEventsAreClassifiedAndHallucinationsDropped(string text, bool keep)
    {
        var words = WordAssembler.Group([Token(text)], new(GroupingEnd.NextWordStart, GroupingConfidence.Mean, true), 0);
        if (keep) Assert.Equal(WordKind.Event, Assert.Single(words).Kind); else Assert.Empty(words);
    }

    [Fact]
    public void SplitBracketEventMergesAtMostSixDraftsInSameGroup()
    {
        var words = WordAssembler.Group([Token("(soft"), Token("music)", start: 0.4, end: 0.7), Token("word", start: 1)],
            new(GroupingEnd.LastToken, GroupingConfidence.Mean, true), 0.5);
        Assert.Equal("(soft music)", words[0].Text);
        Assert.Equal(WordKind.Event, words[0].Kind);
        Assert.Equal(1.2, words[0].End);
        Assert.Equal(2, words.Count);
    }

    [Fact]
    public void BracketMergeDoesNotCrossDecodeGroup()
    {
        var words = WordAssembler.Group([Token("[soft"), Token("laughs]", group: 1)], new(GroupingEnd.LastToken, GroupingConfidence.Single, true), 0);
        Assert.Equal(2, words.Count);
        Assert.All(words, word => Assert.Equal(WordKind.Word, word.Kind));
    }

    [Fact]
    public void SevenDraftEventAbsorbsSixFollowingDraftsButNeverASeventh()
    {
        var rule = new GroupingRule(GroupingEnd.LastToken, GroupingConfidence.Single, true);
        var seven = new[] { "(one", "two", "three", "four", "five", "six", "seven)" };
        var merged = Assert.Single(WordAssembler.Group(seven.Select(text => Token(text)).ToArray(), rule, 0));
        Assert.Equal("(one two three four five six seven)", merged.Text);
        Assert.Equal(WordKind.Event, merged.Kind);
        var eight = new[] { "(one", "two", "three", "four", "five", "six", "seven", "eight)" };
        var limited = WordAssembler.Group(eight.Select(text => Token(text)).ToArray(), rule, 0);
        Assert.Equal(2, limited.Count);
        Assert.Equal("(one two three four five six seven", limited[0].Text);
        Assert.Equal("eight)", limited[1].Text);
        Assert.All(limited, word => Assert.Equal(WordKind.Word, word.Kind));
    }

    [Theory]
    [InlineData(-0.4, 0)]
    [InlineData(2.0, 1)]
    public void ClampsConfidence(double confidence, double expected)
        => Assert.Equal(expected, Assert.Single(WordAssembler.Group([Token("word", confidence: confidence)],
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), 0)).Conf);

    [Fact]
    public void EmptyInputReturnsNoWords() => Assert.Empty(WordAssembler.Group([], new(GroupingEnd.LastToken, GroupingConfidence.Single, false), 0));

    [Fact]
    public void MergedEditingPipelineMarksEnvelopeBackedImportsRefined()
    {
        var raw = new RawTranscript(new(TranscriptEngine.Elevenlabs, "scribe_v2", null, "scribe_v2", null), 1,
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), [Token("hello")], "en", null, true, TimingSource.Native, null);
        var transcript = TranscriptPostProcessor.Process(raw, 1, new(16000, 0.01, [0.1f]), new string('a', 64), DateTimeOffset.UtcNow);
        Assert.True(transcript.Refined);
        Assert.Equal("hello", Assert.Single(transcript.Words).Text);
        var import = EditingImport.Pipeline(WordAssembler.Group(raw.Tokens, raw.Grouping, 0), new(16000, 0.01, [0.1f]),
            raw.Timing, raw.Verbatim, 1);
        Assert.Equal(0.8, import.PauseThresholdSeconds);
        Assert.Empty(import.Pauses);
    }

    [Theory]
    [InlineData(TimingSource.Estimated)]
    [InlineData(TimingSource.Detected)]
    public void UnsupportedTranscriptTimingUsesExactFailureCopy(TimingSource timing)
    {
        var raw = new RawTranscript(new(TranscriptEngine.Whispercpp, null, null, "test", null), 1,
            new(GroupingEnd.LastToken, GroupingConfidence.Single, false), [], "en", null, false, timing, null);
        var error = Assert.Throws<VoxClipException>(() => TranscriptPostProcessor.Process(raw, 1, null,
            new string('a', 64), DateTimeOffset.UtcNow));
        Assert.Equal(VoxClipErrorCode.TranscriptionFailed, error.Code);
        Assert.Equal("Transcription stopped: the engine returned unsupported timing. Your video is still here.", error.Message);
    }
}
