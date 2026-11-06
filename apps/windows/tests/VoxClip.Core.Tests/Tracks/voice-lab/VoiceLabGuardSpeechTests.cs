using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>The use-time guard hears the patch's speech (voice-lab.md §6.9, ADR-R40; Mac <c>VoiceLabGuardSpeechTests</c>): the
/// transcript words' own spans nearest the patch, up to 10 s, the patch speaker's only; and a window the guard settled lets a
/// batch go on.</summary>
public sealed class VoiceLabGuardSpeechTests
{
    private const int Rate = 16_000;
    private static TimedWord Word(string id, double start, double end, string? speaker = null) =>
        new(id, id, WordKind.Word, start, end, null, null, 1, speaker, TimingSource.Native);
    private static double[][] Seconds(VoiceLabGuardSpeech selection) =>
        selection.Ranges.Select(range => new[] { range.Start / (double)Rate, range.End / (double)Rate }).ToArray();
    private static void Same(double[][] expected, double[][] actual)
    {
        Assert.Equal(expected.Length, actual.Length);
        foreach (var (want, got) in expected.Zip(actual))
        {
            Assert.True(Math.Abs(want[0] - got[0]) < 1e-9, $"{want[0]} != {got[0]}");
            Assert.True(Math.Abs(want[1] - got[1]) < 1e-9, $"{want[1]} != {got[1]}");
        }
    }

    [Fact]
    public void ReadsOnlyWordSpansNearestThePatchUpToTenSeconds()
    {
        // Twenty one-second words, each followed by a second of silence, over 40 s; the patch is word 9 (18–19 s).
        var words = Enumerable.Range(0, 20).Select(index => Word("w" + index, index * 2, index * 2 + 1)).ToArray();
        var selection = VoiceLabGuardSpeech.Select(words, 18, 19, Rate, 40 * Rate);
        Assert.Equal(10L * Rate, selection.Frames);
        // The patch's word and the nine nearest, the earlier of two equally near words first: words 4 to 13.
        Assert.Equal(Enumerable.Range(4, 10).Select(index => index * 2.0), Seconds(selection).Select(range => range[0]));
        Assert.All(selection.Ranges, range => Assert.Equal(Rate, range.End - range.Start));
        Assert.Null(selection.Speaker);
    }

    [Fact]
    public void WidensOutwardWhenThePatchHasLittleSpeech()
    {
        TimedWord[] words = [Word("a", 0, 4), Word("b", 10, 10.3), Word("c", 30, 34), Word("d", 60, 62)];
        var selection = VoiceLabGuardSpeech.Select(words, 10, 10.3, Rate, 70 * Rate);
        // The patch's 0.3 s, then the nearest words at their 2 s cap, each the part nearest the patch.
        Same([[2, 4], [10, 10.3], [30, 32], [60, 62]], Seconds(selection));
        Assert.True(Math.Abs(selection.Frames / (double)Rate - 6.3) < 1e-9);
    }

    [Fact]
    public void StopsAtTenSecondsInsideTheLastWord()
    {
        var words = Enumerable.Range(0, 6).Select(index => Word("w" + index, index * 3, index * 3 + 2)).ToArray();
        var selection = VoiceLabGuardSpeech.Select(words, 0, 2, Rate, 20 * Rate);
        Assert.Equal(10L * Rate, selection.Frames);
        Same([[0, 2], [3, 5], [6, 8], [9, 11], [12, 14]], Seconds(selection));
    }

    [Fact]
    public void StaysWithThePatchSpeakerWhereTheTranscriptKnowsSpeakers()
    {
        // A interviews B: A 0–6 s, B 6–20 s, A 20–24 s. A patch on B's words reads B's turn only; one on A's reads A's words, never
        // B's, even though B's are nearer than A's other turn.
        TimedWord[] words = [Word("a1", 0, 2, "A"), Word("a2", 3, 5, "A"), Word("b1", 6, 8, "B"), Word("b2", 9, 11, "B"), Word("b3", 12, 14, "B"),
            Word("b4", 15, 17, "B"), Word("b5", 18, 19.5, "B"), Word("a3", 20, 22, "A"), Word("a4", 22.5, 24, "A")];
        var other = VoiceLabGuardSpeech.Select(words, 12, 14, Rate, 25 * Rate);
        Assert.Equal("B", other.Speaker);
        Same([[6, 8], [9, 11], [12, 14], [15, 17], [18, 19.5]], Seconds(other));
        var owner = VoiceLabGuardSpeech.Select(words, 3, 5, Rate, 25 * Rate);
        Assert.Equal("A", owner.Speaker);
        Same([[0, 2], [3, 5], [20, 22], [22.5, 24]], Seconds(owner));
    }

    [Fact]
    public void ALongWordOverThePatchGivesThePartAroundIt()
    {
        TimedWord[] words = [Word("long", 0, 49.9), Word("next", 50.7, 60)];
        Same([[29.5, 31.5], [50.7, 52.7]], Seconds(VoiceLabGuardSpeech.Select(words, 30, 31, Rate, 60 * Rate)));
    }

    [Fact]
    public void SkipsEventsAndUntimedItems()
    {
        TimedWord[] words = [new("laugh", "(laughs)", WordKind.Event, 0, 5, null, null, 1, null, TimingSource.Native), Word("x", 6, 6), Word("y", 7, 8)];
        Same([[7, 8]], Seconds(VoiceLabGuardSpeech.Select(words, 0, 5, Rate, 10 * Rate)));
        Assert.Empty(VoiceLabGuardSpeech.Select([], 0, 1, Rate, Rate).Ranges);
    }

    [Fact]
    public void CoversJoinNearbyWordsForOneDecode()
    {
        var selection = new VoiceLabGuardSpeech([(0, 10), (20, 30), (100, 110)], null);
        Assert.Equal([(0L, 30L), (100L, 110L)], selection.Covers(15));
    }

    [Fact]
    public void TheJoinedSamplesComeFromTheExcerptInSourceOrder()
    {
        var whole = Enumerable.Range(0, 100).Select(index => (float)index).ToArray();
        var selection = new VoiceLabGuardSpeech([(10, 13), (50, 52)], null);
        Assert.Equal([10f, 11f, 12f, 50f, 51f], selection.Samples(VoiceLabSourceExcerpt.Whole(whole))!);
        // An excerpt that lacks a range gives none, never a partial reading.
        var partial = new VoiceLabSourceExcerpt(100, [new VoiceLabSourceExcerpt.Region(0, whole.AsSpan(0, 20))]);
        Assert.Null(selection.Samples(partial));
    }

    /// <summary>A window the guard settled sent nothing: the batch goes on to its next window and that window's requests are not
    /// discarded (Mac <c>VoiceLabTakeBatchProgress.finish</c> on <c>.blocked</c>).</summary>
    [Fact]
    public void ABlockedWindowLetsTheBatchGoOn()
    {
        var document = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/take-batch-cases.json"))!;
        var row = document["cases"]!.AsArray().First(item => item!["windows"]!.AsArray().Count >= 2)!;
        var batch = new VoiceLabTakeBatch(row["windows"]!.AsArray().Select(value => VoiceLabTakeBatchTests.Window(value!, 24000)).ToArray());
        var progress = new VoiceLabTakeBatchProgress(batch);
        progress.Finish(0, new VoiceLabTakeRunResult([], VoiceLabTakeRunEnd.Blocked));
        Assert.Equal(1, progress.Window);
        Assert.Empty(progress.Sent);
        Assert.True(progress.Discarded.SetEquals(batch.Windows[0].RequestIds));
        Assert.False(progress.Discarded.Overlaps(batch.Windows[1].RequestIds));
        // A fatal end still stops the batch and discards the rest.
        var stopped = new VoiceLabTakeBatchProgress(batch);
        stopped.Finish(0, new VoiceLabTakeRunResult([], VoiceLabTakeRunEnd.Fatal));
        Assert.Null(stopped.Window);
        Assert.True(stopped.Discarded.IsSupersetOf(batch.Windows[1].RequestIds));
    }
}
