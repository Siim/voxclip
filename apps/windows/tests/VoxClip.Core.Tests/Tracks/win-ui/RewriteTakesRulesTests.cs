#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Takes rules on Windows (Mac smokefix and smokereal): the automatic-take ranking, voiced phrases never held back by a
/// re-estimate, the paid-only fit footer, no Use anyway for a join advisory (ADR-R39), and ADR-R37: an unmeasured short take is never chosen
/// automatically but offered as [Choose Take N], a measured one still is. Stub connectors and runners only.</summary>
public sealed class RewriteTakesRulesTests
{
    [Fact]
    public async Task TheAutomaticTakeIsOneADurationCanCarryElseTheClosestToTheSlotNotTheBestScore()
    {
        // Each round's wording is new and shorter: the fix loop never voices a repeat (voice-lab.md §8.2.2).
        var connector = new Connector(Reply, (request, ordinals) => Rows(ordinals, request == 1 ? "said briefly" : "so brief"));
        var runner = new Runner((run, _) => run switch { 1 => (5.8, Passed), 2 => (7.0, Passed), _ => (Fit, Passed) })
            { Score = run => run switch { 1 => .9, 2 => .3, _ => .1 } };
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        Assert.Equal(2, window.Rows.Count);
        Assert.NotNull(session.AutoFix.Capped);
        Assert.Equal(window.Rows[0].Id, window.AutomaticTake()!.Id);
        Assert.Equal(window.Rows[0].Id, window.SelectedTakeId);
        // No duration can carry it, so the footer never asks for a duration choice that doesn't exist: it names the take that can't
        // fit (Mac acceptanceBlocker), and the capped resolver still owns the phrase, so it is not kept as recorded yet.
        Assert.Equal("Phrase 1's take can't fit its place in the video.", session.AcceptanceBlocker);
        Assert.False(window.LeftOut);
        Assert.Equal(RewriteFooterAction.KeepFixing, session.FooterStep.Action);
        Assert.False(window.DurationAvailable(window.Rows[1]));
        session.KeepFixing();
        await SettleAsync(session);
        Assert.Equal(3, window.Rows.Count);
        Assert.True(window.DurationAvailable(window.Rows[2]));
        Assert.Equal(window.Rows[2].Id, window.AutomaticTake()!.Id);
        Assert.Equal(window.Rows[2].Id, window.SelectedTakeId);
        Assert.Equal([window.Rows[2], window.Rows[0], window.Rows[1]], window.Ranked(window.Rows));
    }

    [Fact]
    public async Task AVoicedPhraseIsNeverHeldBackAndItsRowShowsNoEstimateOrRecovery()
    {
        const string Long = "a much much longer phrasing than this slot could hold";
        // Stopped before the fit kept it, then priced by the user's own click (ADR-R42 keeps a long change otherwise).
        var connector = new Connector(Long + " word11 word12", (_, ordinals) => Rows(ordinals, Long)) { HoldFits = true };
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = Session(connector);
        var proposing = ProposeAsync(session);
        await connector.FitSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        session.StopWordingFit();
        connector.Release.SetResult();
        Assert.True(await proposing);
        await session.WordingFitWork;
        Assert.True(session.ShowsEstimate(1));
        Assert.True(session.PriceItAnyway(1));
        Assert.False(session.Review!.VoiceHunks[0].Fit!.Fits);
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        session.MarkBatchEstimateShown(session.PreparedBatch!);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        await SettleAsync(session);
        Assert.Equal([1], session.VoicedOrdinals);
        Assert.False(session.ShowsEstimate(1));
        Assert.Null(session.FitRowNote(1));
        Assert.Empty(session.BlockedVoiceHunks);
        Assert.Null(session.StuckReason(0));
        Assert.Equal(1, runner.Sends);
    }

    [Fact]
    public async Task TheFitFooterShowsOnlyBeforePaidTakes()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Assert.Equal("Nothing paid yet.", session.ReviewFooter);
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        session.MarkBatchEstimateShown(session.PreparedBatch!);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.True(session.HasPaidTakes);
        Assert.Equal("", session.ReviewFooter);
    }

    /// <summary>ADR-R39: a take whose only issue is its join is chosen automatically when some video duration can carry it;
    /// one no duration can carry is still chosen as the closest take, so the automatic fixes reword from it.</summary>
    [Theory]
    [InlineData(0.0, true)]
    [InlineData(5.8, false)]
    public async Task AnAdvisoryTakeIsChosenAutomaticallyWithNoUseAnyway(double seconds, bool carried)
    {
        var advisory = new VoiceLabTakeQaResult(1, 4, -3, .8, [VoiceLabTakeQaFailure.Loudness]) { JoinSeams = [new("left", 4)] };
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (seconds, advisory));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        var row = window.Rows[0];
        Assert.True(row.HasJoinAdvisory);
        Assert.False(row.RequiresJoinAdvisoryAcceptance);
        Assert.Equal(carried, window.DurationAvailable(row));
        // A take some duration carries is used as it is; one none carries is the take the fixes reword from, so they make another.
        if (carried) Assert.Equal(row.Id, Assert.Single(window.Rows).Id);
        Assert.True(window.LeftOut || window.SelectedTakeId == window.AutomaticTake()?.Id);
        Assert.False(window.Selected?.RequiresJoinAdvisoryAcceptance == true);
        Assert.Null(window.OfferedTake());
        Assert.DoesNotContain("Use anyway", session.ReviewFooter);
    }

    private static VoiceLabShortSpeechEvidence Evidence(VoiceLabShortSpeechMode mode) =>
        new(mode, "record", VoiceConsentMethod.RecordedStatement, mode == VoiceLabShortSpeechMode.Pooled ? 52_000 : 20_000, mode == VoiceLabShortSpeechMode.Pooled ? 3 : 1);

    [Fact]
    public async Task AnUnmeasuredTakeIsNeverPickedAutomaticallyAndTheFooterOffersChooseTake()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed)) { Voice = _ => VoiceLabTakeVoiceCheck.ShortSpeech(Evidence(VoiceLabShortSpeechMode.Unmeasured)) };
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        var row = Assert.Single(window.Rows);
        Assert.True(row.Selectable);
        Assert.Null(row.Qa!.SpeakerScore);
        Assert.Null(window.AutomaticTake());
        Assert.Null(window.SelectedTakeId);
        // The user's pick, not a stuck phrase: the resolver spends nothing on it.
        Assert.Null(session.StuckReason(0));
        Assert.Equal(1, runner.Sends);
        Assert.Equal("voice couldn't be measured (under 3 s of speech)", TakeRowPresentation.From(row, window.BestTakeId).Note);
        Assert.Equal(new RewriteFooterStep("Choose a take for phrase 1.", "Choose Take 1", RewriteFooterAction.ChooseTake), session.FooterStep);
        Assert.True(await session.ChooseOfferedTakeAsync());
        Assert.Equal(row.Id, window.SelectedTakeId);
        Assert.Null(window.OfferedTake());
        Assert.NotEqual(RewriteFooterAction.ChooseTake, session.FooterStep.Action);
    }

    [Fact]
    public async Task AMeasuredPooledTakeStillPicksAutomatically()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed)) { Voice = _ => VoiceLabTakeVoiceCheck.ShortSpeech(Evidence(VoiceLabShortSpeechMode.Pooled)), Score = _ => .9 };
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        var row = Assert.Single(window.Rows);
        Assert.Equal(row.Id, window.SelectedTakeId);
        Assert.Null(window.OfferedTake());
        Assert.Equal("Best match · Short phrase · words checked · voice checked across 3 takes", TakeRowPresentation.From(row, window.BestTakeId).Note);
        Assert.NotEqual(RewriteFooterAction.ChooseTake, session.FooterStep.Action);
    }

    [Theory]
    [InlineData(VoiceLabShortSpeechMode.Pooled, true)]
    [InlineData(VoiceLabShortSpeechMode.Unmeasured, false)]
    public async Task TheBatchsPooledCheckSettlesWaitingTakesInPlace(VoiceLabShortSpeechMode mode, bool picked)
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed)) { Voice = _ => VoiceLabTakeVoiceCheck.Waiting };
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        var waiting = Assert.Single(window.Rows);
        Assert.False(waiting.Selectable);
        Assert.Null(window.SelectedTakeId);
        Assert.Null(session.StuckReason(0));
        Assert.Equal("Take 1, waiting for the voice check", TakeRowPresentation.From(waiting, null).AutomationName);
        var verdict = waiting.CheckingVoice(VoiceLabTakeVoiceCheck.ShortSpeech(Evidence(mode)), mode == VoiceLabShortSpeechMode.Pooled ? .9 : null);
        Assert.True(window.ApplyVoiceChecks(new Dictionary<Guid, VoiceLabTakeRow> { [waiting.Id] = verdict }));
        var row = Assert.Single(window.Rows);
        Assert.True(row.Selectable);
        Assert.Equal(waiting.Index, row.Index);
        Assert.Equal(picked ? row.Id : null, window.SelectedTakeId);
        Assert.Equal(picked ? null : row.Id, window.OfferedTake()?.Id);
        Assert.Equal(1, runner.Sends);
    }
}
#endif
