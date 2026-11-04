using VoxClip.Core.Domain.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>voice-lab §8.5 "Timing recovery" (Mac <c>VoiceLabProviderTimingTests</c>): a take's word check (or the
/// on-device transcriber) gives its word times. The provider replies are replayed from v4-timing-cases.json in
/// <see cref="VoiceLabDialogueTests"/>.</summary>
public sealed class VoiceLabProviderTimingTests
{
    static IReadOnlyList<VoiceLabWord> Words(IReadOnlyList<VoiceLabCharacterTiming> timing, string typed) =>
        VoiceLabAlignment.Words(timing.Select(item => item.Character).ToArray(), timing.Select(item => item.Start).ToArray(),
            timing.Select(item => item.End).ToArray(), typed);

    [Fact]
    public void HeardWordsKeepTheirTimesAndMapToTheTypedSpelling()
    {
        const string typed = "Claude, that is, when you are using your Claude's";
        var heard = new[] { "claude", "that", "is", "when", "you", "are", "using", "your", "claudes" }
            .Select((text, index) => new VoiceLabWord(text, 0.1 + index * 0.3, 0.35 + index * 0.3, true)).ToArray();
        var result = Words(VoiceLabProviderTiming.Recovered(heard, typed), typed);
        Assert.Equal(typed.Split(' '), result.Select(word => word.Text));
        Assert.Equal(heard.Select(word => word.Start), result.Select(word => word.Start));
        Assert.Equal(heard.Select(word => word.End), result.Select(word => word.End));
    }

    [Fact]
    public void MisheardAndMissedWordsShareTheirNeighboursSpan()
    {
        const string typed = "I use a similar method as";
        // Scribe hears "simmer" for "similar" and misses "a": the take is still timed; the word check decides.
        var heard = new[] { ("I", .1, .2), ("use", .2, .4), ("simmer", .5, .9), ("method", .9, 1.3), ("as", 1.3, 1.5) }
            .Select(item => new VoiceLabWord(item.Item1, item.Item2, item.Item3, true)).ToArray();
        var result = Words(VoiceLabProviderTiming.Recovered(heard, typed), typed);
        Assert.Equal(new[] { "I", "use", "a", "similar", "method", "as" }, result.Select(word => word.Text));
        Assert.Equal(.5, result[2].Start);
        Assert.Equal(.9, result[3].End);
        Assert.All(result.Zip(result.Skip(1)), pair => Assert.True(pair.First.End <= pair.Second.Start));
    }

    [Fact]
    public void NothingHeardIsNotTiming()
    {
        Assert.Equal("recovery_no_words", Assert.Throws<VoiceLabTimingFailure>(() => VoiceLabProviderTiming.Recovered([], "Hello there")).Check);
        Assert.Equal("recovery_no_words", Assert.Throws<VoiceLabTimingFailure>(() => VoiceLabProviderTiming.Recovered([new("…", 0, 1, true)], "Hello")).Check);
    }

    [Fact]
    public void TheLogFieldsNameTheCheckIndexAndCodePointsOnly()
    {
        Assert.Equal("check=alignment_words_mismatch index=1 typed=U+0027 provider=U+2019", new VoiceLabTimingFailure("alignment_words_mismatch", 1, 0x27, 0x2019).LogFields);
        Assert.Equal("check=null_alignment index=none typed=none provider=none", new VoiceLabTimingFailure("null_alignment").LogFields);
        Assert.Equal((1, 0x27, 0x2019), VoiceLabProviderTiming.FirstMismatch("I'm", "I’m"));
        Assert.Equal((2, (int?)null, 0x21), VoiceLabProviderTiming.FirstMismatch("Hi", "Hi!"));
        Assert.Equal((2, 0x1F600, 0x1F601), VoiceLabProviderTiming.FirstMismatch("Hi😀", "Hi😁"));
    }
}
