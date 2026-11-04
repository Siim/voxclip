using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>ADR-R37's pooled voice check (Mac <c>VoiceLabShortTakePool</c>): consecutive groups closing at three seconds of voiced
/// speech with a short tail joining the group before it, a mismatch only on its own group's takes, a plan-wide block on
/// unmeasured takes after a measured mismatch, and a short retry borrowing earlier generated speech of its phrase first.</summary>
public sealed partial class VoiceLabTakeRunTests
{
    private static VoiceLabTakeRow WaitingRow(bool wordsFailed = false) => new(Guid.NewGuid(), 0, 1,
        Qa: new(wordsFailed ? .4 : 1, 0, -3, null, wordsFailed ? [VoiceLabTakeQaFailure.Transcript] : [])) { VoiceCheck = VoiceLabTakeVoiceCheck.Waiting };
    private static VoiceLabShortTakePool.Member PoolMember(VoiceLabTakeRow row, int frames, VoiceConsentRecord record, int? phrase = null,
        float[]? vector = null, List<int>? embedded = null) => new(row, new float[frames], phrase, record, _ => Task.CompletedTask, (voiced, _) =>
        {
            embedded?.Add(voiced.Length);
            return Task.FromResult(vector ?? [1f, 0f]);
        });

    [Theory]
    [InlineData(new[] { 40000, 10000, 40000, 10000 }, new[] { 2, 2 })]
    [InlineData(new[] { 20000, 20000, 10000, 5000 }, new[] { 4 })]
    [InlineData(new[] { 30000, 30000, 30000, 10000 }, new[] { 4 })]
    [InlineData(new[] { 10000 }, new[] { 1 })]
    public async Task GroupsCloseAtThreeSecondsAndAShortTailJoinsTheGroupBefore(int[] frames, int[] sizes)
    {
        await using var fixture = new Fixture();
        var members = frames.Select(count => PoolMember(WaitingRow(), count, fixture.Record)).ToArray();
        Assert.Equal(sizes, VoiceLabShortTakePool.Groups(members).Select(group => group.Count));
    }

    [Fact]
    public async Task AMeasuredMismatchFailsOnlyItsOwnGroupAndKeepsAWordsFailure()
    {
        await using var fixture = new Fixture();
        var pool = new VoiceLabShortTakePool(new());
        List<int> embedded = [];
        var rows = new[] { WaitingRow(), WaitingRow(), WaitingRow(wordsFailed: true), WaitingRow() };
        pool.Append(PoolMember(rows[0], 40000, fixture.Record, embedded: embedded));
        pool.Append(PoolMember(rows[1], 10000, fixture.Record, embedded: embedded));
        pool.Append(PoolMember(rows[2], 40000, fixture.Record, vector: [0f, 1f], embedded: embedded));
        pool.Append(PoolMember(rows[3], 10000, fixture.Record, embedded: embedded));
        var checkedRows = await pool.FinishAsync();
        Assert.Same(checkedRows, await pool.FinishAsync());
        Assert.Equal([50000, 50000], embedded);
        Assert.All(rows.Take(2), row => Assert.Equal(VoiceLabTakeQaVerdict.Passed, checkedRows[row.Id].Qa!.Verdict));
        Assert.Equal(1, checkedRows[rows[0].Id].Qa!.SpeakerScore);
        Assert.Equal([VoiceLabTakeQaFailure.Transcript, VoiceLabTakeQaFailure.Speaker], checkedRows[rows[2].Id].Qa!.Failures);
        Assert.Equal([VoiceLabTakeQaFailure.Speaker], checkedRows[rows[3].Id].Qa!.Failures);
        Assert.All(rows, row => Assert.Equal(VoiceLabShortSpeechMode.Pooled, checkedRows[row.Id].VoiceCheck.Evidence!.Mode));
        Assert.Throws<VoiceLabException>(() => pool.Append(PoolMember(WaitingRow(), 1000, fixture.Record)));
    }

    [Fact]
    public async Task AMeasuredMismatchBlocksUnmeasuredTakesAcrossThePlanUntilALaterRunPasses()
    {
        await using var fixture = new Fixture();
        var session = new VoiceLabVoiceCheckSession();
        var first = WaitingRow();
        var run1 = new VoiceLabShortTakePool(session);
        run1.Append(PoolMember(first, 20000, fixture.Record));
        var checked1 = await run1.FinishAsync();
        Assert.True(checked1[first.Id].VoiceCheck.Complete);
        Assert.Equal(VoiceLabTakeQaVerdict.Passed, checked1[first.Id].Qa!.Verdict);
        Assert.Null(checked1[first.Id].Qa!.SpeakerScore);

        // A long take's measured mismatch; a pass in the same run does not clear it.
        var second = WaitingRow();
        var run2 = new VoiceLabShortTakePool(session);
        run2.Measured(Guid.NewGuid(), new float[48000], fixture.Record, null, passed: false);
        run2.Measured(Guid.NewGuid(), new float[48000], fixture.Record, null, passed: true);
        run2.Append(PoolMember(second, 20000, fixture.Record));
        var checked2 = await run2.FinishAsync();
        Assert.Contains(VoiceLabTakeQaFailure.Speaker, checked2[second.Id].Qa!.Failures);
        Assert.Contains(VoiceLabTakeQaFailure.Speaker, checked2[first.Id].Qa!.Failures);
        Assert.Null(checked2[first.Id].Qa!.SpeakerScore);

        var third = WaitingRow();
        var run3 = new VoiceLabShortTakePool(session);
        run3.Measured(Guid.NewGuid(), new float[48000], fixture.Record, null, passed: true);
        run3.Append(PoolMember(third, 20000, fixture.Record));
        var checked3 = await run3.FinishAsync();
        Assert.All(new[] { first, second, third }, row => Assert.Equal(VoiceLabTakeQaVerdict.Passed, checked3[row.Id].Qa!.Verdict));
    }

    [Fact]
    public async Task AShortRetryBorrowsItsPhrasesEarlierSpeechFirstTruncatingTheLastDonor()
    {
        await using var fixture = new Fixture();
        var session = new VoiceLabVoiceCheckSession();
        var run1 = new VoiceLabShortTakePool(session);
        run1.Append(PoolMember(WaitingRow(), 40000, fixture.Record, phrase: 0));
        run1.Measured(Guid.NewGuid(), new float[50000], fixture.Record, 1, passed: true);
        await run1.FinishAsync();
        List<int> embedded = [];
        var retry = WaitingRow();
        var run2 = new VoiceLabShortTakePool(session, retryPhrase: 0);
        run2.Append(PoolMember(retry, 10000, fixture.Record, phrase: 0, embedded: embedded));
        var row = (await run2.FinishAsync())[retry.Id];
        Assert.Equal([48000], embedded);
        Assert.Equal(new VoiceLabShortSpeechEvidence(VoiceLabShortSpeechMode.Pooled, fixture.Record.RecordId, fixture.Record.ConsentMethod, 48000, 2), row.VoiceCheck.Evidence);
        Assert.Equal(VoiceLabTakeQaVerdict.Passed, row.Qa!.Verdict);
    }
}
