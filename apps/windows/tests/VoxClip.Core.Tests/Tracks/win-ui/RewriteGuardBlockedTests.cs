#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Domain.Shared;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>A phrase the use-time guard refused (ADR-R40, voice-lab.md §6.9; Mac <c>RewriteSettledPhrasesTests</c>): settled for the
/// Rewrite, said once with [● Say it myself] [Keep as recorded], never retried or reworded, never priced again, and the footer keeps its
/// original audio with one click. ✦ Make it postable keeps it as recorded with no click and counts nothing as spent. Stubs only.</summary>
public sealed class RewriteGuardBlockedTests
{
    private static Runner Blocked(VoiceConsentError error) =>
        new((_, _) => (Fit, Passed)) { Blocks = _ => new VoiceConsentException(error) };

    [Fact]
    public async Task ABlockedPhraseIsSaidOnceWithItsTwoWaysOnAndNeverRetried()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = Blocked(VoiceConsentError.VoiceOwnerMismatch);
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = Assert.Single(session.GenerationWindows);
        Assert.Equal("This doesn't sound like the voice owner. Voice Lab is only for your own videos. Nothing sent for this phrase.", window.Blocked);
        Assert.IsType<StuckTakeReason.Blocked>(session.StuckReason(0));
        // Nothing was sent, and the resolver neither retried the phrase nor asked the AI for new words.
        Assert.Equal(1, runner.Executions);
        Assert.Equal(0, runner.Sends);
        Assert.Empty(connector.Reasks);
        Assert.Empty(session.AutoFix.Lines);
        Assert.False(session.HasPaidTakes);
        // The stop once, at the top (every phrase is blocked), with its two ways on and no priced control.
        var card = session.NextStepCards[0];
        Assert.Equal("Rewrite.Steps.GuardBlocked", card.Id);
        Assert.Equal(window.Blocked, card.Sentence);
        Assert.DoesNotContain(session.NextStepCards, card => card.Id == "Rewrite.Steps.Phrase1");
        Assert.Equal(["● Say it myself", "Keep as recorded"], card.Chips.Select(chip => chip.Label));
        Assert.False(card.Asks);
        Assert.DoesNotContain(session.NextStepCards.SelectMany(card => card.Chips), chip => chip.Label.Contains('$') || chip.Id.StartsWith("Rewrite.Chip.TryAnother", StringComparison.Ordinal));
        Assert.False(session.CanGenerateAll);
        Assert.False(window.CanExecute);
        Assert.True(session.EveryPhraseSettled);
        // The footer's one step forward keeps the original audio.
        var footer = session.FooterStep;
        Assert.Equal(RewriteFooterAction.KeepOriginal, footer.Action);
        Assert.Equal("Keep Original Audio for Phrase 1", footer.Title);
        Assert.True(session.KeepOriginal(footer.Phrase));
        Assert.Null(session.StuckReason(0));
        Assert.Equal(RewriteFooterAction.Done, session.FooterStep.Action);
        Assert.Equal(1, runner.Executions);
    }

    /// <summary>Mac <c>everyPhraseBlockedSteps</c>: every phrase blocked, none with a take of its own. The stop is said once at the top with
    /// "This holds for all 2 phrases.", [● Say it myself] and [Keep all as recorded]; no card per phrase repeats it.</summary>
    [Fact]
    public async Task EveryPhraseBlockedIsSaidOnceAtTheTopAndKeepAllKeepsThem()
    {
        var connector = new Connector(RewriteDurationSettleTests.TwoChanges, (_, ordinals) => Rows(ordinals, "x"));
        Runner[] runners = [Blocked(VoiceConsentError.VoiceOwnerMismatch), Blocked(VoiceConsentError.VoiceOwnerMismatch)];
        using var session = Session(connector, last: 16);
        RewriteOwnTakeTests.ConfigureWithSource(session, index => runners[index]);
        Assert.True(await ProposeAsync(session));
        await PriceAndMakeAsync(session);
        Assert.All(session.GenerationWindows, window => Assert.True(window.WaitsOnBlock));
        Assert.True(session.EveryPhraseBlocked);
        var card = Assert.Single(session.NextStepCards);
        Assert.Equal("Rewrite.Steps.GuardBlocked", card.Id);
        Assert.Equal(session.GenerationWindows[0].Blocked + " This holds for all 2 phrases.", card.Sentence);
        Assert.Equal(["● Say it myself", "Keep all as recorded"], card.Chips.Select(chip => chip.Label));
        Assert.False(card.Asks);
        await card.Chips[1].Invoke!();
        Assert.All(session.GenerationWindows, window => Assert.True(window.LeftOut));
        Assert.Null(session.EveryPhraseBlockedCard);
        Assert.Equal(RewriteFooterAction.Done, session.FooterStep.Action);
        Assert.All(runners, runner => Assert.Equal(0, runner.Sends));
    }

    /// <summary>Mac <c>rememberBlocked</c>/<c>applyRememberedBlocks</c> and <c>voiceableIndices</c>: a change the guard settled stays settled in a
    /// later plan of the same Rewrite, blocked before anything is priced, and left out of that plan's price and run.</summary>
    [Fact]
    public async Task ASettledChangeStaysSettledInALaterPlanAndIsLeftOutOfItsPrice()
    {
        var connector = new Connector(RewriteDurationSettleTests.TwoChanges, (_, ordinals) => Rows(ordinals, "x"));
        Runner[] runners = [Blocked(VoiceConsentError.VoiceOwnerMismatch), new((_, _) => (Fit, Passed))];
        using var session = Session(connector, last: 16);
        RewriteOwnTakeTests.ConfigureWithSource(session, index => runners[index]);
        Assert.True(await ProposeAsync(session));
        await PriceAndMakeAsync(session);
        var first = session.GenerationWindows[0];
        Assert.NotNull(first.Blocked);
        Assert.True(session.HasPaidTakes);
        // A later plan: change 2 is left out (its paid take is discarded only after the confirm), so phrase 1 is planned again.
        Assert.False(session.SetChangeIncluded(2, false));
        Assert.True(await session.ConfirmPaidReviewChangeAsync(session.PendingPaidReviewChange!));
        var alone = Assert.Single(session.GenerationWindows);
        Assert.NotNull(alone.Blocked);
        await session.DiscoverWindowsAsync();
        Assert.Null(session.PreparedBatch);
        Assert.False(session.CanGenerateAll);
        Assert.Equal(1, runners[0].Executions);
        // Change 2 comes back: only its phrase is priced and run; the settled phrase sends nothing again.
        Assert.True(session.SetChangeIncluded(2, true));
        Assert.Equal(2, session.GenerationWindows.Count);
        Assert.NotNull(session.GenerationWindows[0].Blocked);
        await session.DiscoverWindowsAsync();
        foreach (var window in session.GenerationWindows) await window.PendingUpdate;
        var batch = session.PreparedBatch!;
        Assert.Same(session.GenerationWindows[1], Assert.Single(session.PricedWindows));
        Assert.Single(batch.Windows);
        Assert.Equal(.06m, batch.Estimate.Usd);
        session.MarkBatchEstimateShown(batch);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.Equal(1, runners[0].Executions);
        Assert.Equal(0, runners[0].Sends);
        Assert.Equal(2, runners[1].Sends);
    }

    private static async Task PriceAndMakeAsync(RewriteSession session)
    {
        await session.DiscoverWindowsAsync();
        foreach (var window in session.GenerationWindows) await window.PendingUpdate;
        session.MarkBatchEstimateShown(session.PreparedBatch!);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        await SettleAsync(session);
    }

    [Fact]
    public async Task TooLittleSpeechToCheckSaysSo()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        using var session = await PricedAsync(connector, Blocked(VoiceConsentError.SpeakerMismatch));
        await SettleAsync(session);
        Assert.Equal("There isn't enough speech near this phrase to check that it's your voice. Nothing sent for this phrase.", session.GenerationWindows[0].Blocked);
    }

    /// <summary>Any other consent failure still ends the run as before: it is not the guard's settled verdict.</summary>
    [Fact]
    public void OnlyTheGuardsRefusalsReadAsBlocked()
    {
        Assert.Equal("There isn't enough speech near this phrase to check that it's your voice. Nothing sent for this phrase.",
            RewriteSession.BlockedCopy(new VoiceConsentException(VoiceConsentError.SpeakerMismatch)));
        Assert.EndsWith("Nothing sent for this phrase.", RewriteSession.BlockedCopy(new VoiceConsentException(VoiceConsentError.VoiceOwnerMismatch)));
    }

    /// <summary>Mac S-guard-claude (G4): ✦ Make it postable keeps the blocked phrase as recorded with no click, nothing is counted as
    /// spent, and the Rewrite ends with the project as it was.</summary>
    [Fact]
    public async Task TheDriverKeepsABlockedPhraseAsRecordedWithNoClickAndSpendsNothing()
    {
        RewriteSession? opened = null;
        Runner? runner = null;
        var editor = Editor();
        var before = ProjectSerialization.Serialize(editor.Project);
        var driver = new MakeItRewriteDriver(editor, new(10, 12, Reply, "c1", 5m), request =>
        {
            opened = Session(new(Reply, (_, ordinals) => Rows(ordinals, "x")), request.First, request.Last, editor: editor);
            Configure(opened, runner = Blocked(VoiceConsentError.VoiceOwnerMismatch));
            return Task.FromResult<RewriteSession?>(opened);
        }, _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        var outcome = await driver.RunAsync(TestContext.Current.CancellationToken);
        var kept = Assert.IsType<MakeItRewriteResult.KeptAsRecorded>(outcome.Result);
        Assert.Equal(RewriteSession.NotYourVoiceHere, kept.Reason);
        Assert.Equal(1, outcome.KeptAsRecorded);
        Assert.Equal(0m, outcome.Spent);
        Assert.Equal(0, runner!.Sends);
        Assert.Contains("Make it postable keeps phrase 1 as recorded (not the voice owner)", driver.Pressed);
        Assert.False(opened!.HasPaidTakes);
        Assert.False(opened.IsOpen);
        Assert.Equal(before, ProjectSerialization.Serialize(editor.Project));
    }
}
#endif
