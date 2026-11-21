using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;
using Xunit;

namespace VoxClip.Media.Tests.VoiceLab;

/// <summary>Paid takes are kept (voice-lab §3; Mac <c>VoiceLabTakeRunTests</c> "Paid takes are kept"): a paid take is journaled as
/// it arrives and the next run over the same request adopts it for free.</summary>
public sealed partial class VoiceLabTakeRunTests
{
    private static VoiceLabTakeRun NextRun(Fixture fixture, string projectId, string scratch) =>
        new(fixture.Client, fixture.Store, new(projectId, Path.Combine(fixture.Root, "Paid"), Path.Combine(fixture.Root, scratch)),
            new VoiceLabDispatchGate(), _ => Task.FromResult(true), fixture.Checks);

    private static async Task<(VoiceLabTakeRow Row, VoiceLabAsset Asset, string ProjectId)> PayForOneTake(Fixture fixture)
    {
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        var row = Assert.Single(result.Rows);
        Assert.True(row.Selectable, row.Failure?.ToString());
        var asset = fixture.Run.PaidAsset(row.Id)!;
        return (row, asset, asset.File.Split('/')[0]);
    }

    /// <summary>Once the paying run is gone, the next run adopts the take: nothing is synthesized, the quote prices only the word
    /// check, the take passes the same checks and Use publishes the same asset. Preparing again buys new takes. The take used to be
    /// paid for again.</summary>
    [Fact]
    public async Task APaidTakeIsAdoptedForFreeByTheNextRun()
    {
        await using var fixture = new Fixture();
        var (paidRow, paid, projectId) = await PayForOneTake(fixture);
        var entry = Assert.Single(VoiceLabTakeJournal.List(projectId, Path.Combine(fixture.Root, "Paid")));
        Assert.Equal(paid.File, entry.AssetFile);
        Assert.Equal(paid.Sha256, entry.AssetSha256);
        Assert.Equal(paidRow.Receipt!.ActionId.ToString("D"), entry.RequestId);
        Assert.Equal(VoiceLabTakeJournalKey.Of(fixture.Input, fixture.Record.VoiceId), entry.Key);
        Assert.False(entry.Alignment!.Recovered);
        var spent = (await fixture.Ledger.TotalAsync("elevenlabs", DateTimeOffset.UnixEpoch, Token))!.Usd;
        await fixture.Run.InvalidateAsync();

        var next = NextRun(fixture, projectId, "next");
        try
        {
            var quote = await next.PrepareAsync(fixture.Input, Token);
            var take = Assert.Single(quote.Takes);
            Assert.Equal(paid.File, take.AdoptedAsset);
            Assert.Equal(take.Qa.Estimate.Usd, quote.Estimate.Usd);
            Assert.Equal(new[] { take.Qa }, quote.PricedActions);
            var result = await next.ExecuteAsync(quote, true, ct: Token);
            var row = Assert.Single(result.Rows);
            Assert.True(row.Selectable, row.Failure?.ToString());
            Assert.Equal(paid.File, row.AdoptedAsset);
            Assert.Equal(paidRow.Receipt, row.Receipt);
            Assert.Equal(new[] { take.Synthesis.Review.RequestId, take.Qa.Review.RequestId }.Order(), row.AcceptedRequestIds.Order());
            Assert.Single(fixture.Remote.Seeds);
            Assert.Equal(2, fixture.Remote.Qa);
            Assert.Equal(spent + take.Qa.Estimate.Usd, (await fixture.Ledger.TotalAsync("elevenlabs", DateTimeOffset.UnixEpoch, Token))!.Usd);
            var (publication, _) = await next.PublishForAcceptanceAsync(row.Id, DateTimeOffset.UtcNow, Token);
            Assert.Equal(paid.File, publication.Assets[0].File);
            Assert.Equal(paidRow.Receipt.ActionId.ToString("D"), publication.Chunks[0].RequestId);
            var again = await next.PrepareAsync(fixture.Input, Token);
            Assert.Equal(3, again.Takes.Count);
            Assert.All(again.Takes, item => Assert.Null(item.AdoptedAsset));
            await next.DiscardPendingAsync();
        }
        finally { await next.InvalidateAsync(); }
    }

    /// <summary>Takes whose audio failed their checks (dropped or changed words, their own speaker check, or words their timing can't be
    /// recovered from) are journaled with that verdict and never adopted (Mac <c>aTakeThatFailedItsChecksIsNeverAdopted</c>): the next
    /// run prepares the full set of new takes instead of a known-bad take whose word check it would buy again only to fail the same
    /// way. They used to be adopted one by one, each costing a word check.</summary>
    [Theory]
    [InlineData("words")]
    [InlineData("speaker")]
    [InlineData("timing")]
    public async Task TakesThatFailedTheirChecksAreNeverAdopted(string check)
    {
        await using var fixture = new Fixture();
        if (check == "words") fixture.Remote.Mismatches = 100;
        if (check == "speaker") fixture.SpeakerFailure = true;
        if (check == "timing") { fixture.Remote.MissingAlignment = true; fixture.Remote.Heard = ""; }
        var result = await fixture.Run.ExecuteAsync(await fixture.Prepare(), true, ct: Token);
        Assert.Equal(3, result.Rows.Count);
        Assert.All(result.Rows, row => Assert.False(row.Selectable));
        var projectId = fixture.Run.PaidAsset(result.Rows[0].Id)!.File.Split('/')[0];
        var entries = VoiceLabTakeJournal.List(projectId, Path.Combine(fixture.Root, "Paid"));
        Assert.Equal(3, entries.Count);
        Assert.All(entries, entry =>
        {
            Assert.False(entry.Adoptable);
            Assert.Equal(check switch { "words" => "transcript", "speaker" => "speaker", _ => "timing" }, Assert.Single(entry.Checks!.HardFailures));
            Assert.Equal(check == "speaker" ? VoiceLabTakeJournalOutcome.Passed : VoiceLabTakeJournalOutcome.Failed, entry.Checks.Words);
        });
        await fixture.Run.InvalidateAsync();
        var next = NextRun(fixture, projectId, "next");
        try
        {
            var quote = await next.PrepareAsync(fixture.Input, Token);
            Assert.Equal(3, quote.Takes.Count);
            Assert.All(quote.Takes, take => Assert.Null(take.AdoptedAsset));
            Assert.Equal(quote.Actions.Count, quote.PricedActions.Count);
            await next.DiscardPendingAsync();
            Assert.Equal(3, fixture.Remote.Seeds.Count);
            Assert.Equal(3, fixture.Remote.Qa);
        }
        finally { await next.InvalidateAsync(); }
    }

    /// <summary>A live run's take is never adopted by another run, one take is reserved for one prepared set at a time, and a
    /// withdrawn consent record stops an adoption before its audio is used.</summary>
    [Fact]
    public async Task APaidTakeIsNeverAdoptedTwiceAndNeedsActiveConsent()
    {
        await using var fixture = new Fixture();
        var (_, paid, projectId) = await PayForOneTake(fixture);
        var first = NextRun(fixture, projectId, "first");
        var second = NextRun(fixture, projectId, "second");
        try
        {
            var held = await first.PrepareAsync(fixture.Input, Token);
            Assert.All(held.Takes, item => Assert.Null(item.AdoptedAsset));
            await first.DiscardPendingAsync();
            await fixture.Run.InvalidateAsync();
            var adopting = await first.PrepareAsync(fixture.Input, Token);
            Assert.Equal(paid.File, Assert.Single(adopting.Takes).AdoptedAsset);
            var other = await second.PrepareAsync(fixture.Input, Token);
            Assert.Equal(3, other.Takes.Count);
            await second.DiscardPendingAsync();
            fixture.Store.BeginDeletion(fixture.Record.RecordId, ElevenLabsRegion.Default, DateTimeOffset.UtcNow);
            var refused = await Record.ExceptionAsync(async () =>
            {
                var result = await first.ExecuteAsync(adopting, true, ct: Token);
                Assert.DoesNotContain(result.Rows, row => row.Selectable);
            });
            Assert.True(refused is null or VoiceConsentException or VoiceLabException, refused?.ToString());
            Assert.Single(fixture.Remote.Seeds);
            Assert.Equal(1, fixture.Remote.Qa);
        }
        finally { await first.InvalidateAsync(); await second.InvalidateAsync(); }
    }
}
