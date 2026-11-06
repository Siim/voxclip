#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Get Price screens every phrase first (ADR-R41, voice-lab.md §6.9; Mac <c>ClipTakePlanTests</c> getPriceNeverPricesAPhraseTheGuardBlocks,
/// everyPhraseBlockedBeforePricingAsksForNoPrice, aPhraseMatchedThroughThisVideosReferenceSaysSo): a phrase the free local guard blocks is
/// settled before any price, so the price, its approval and the run cover only the rest. Stubs only; nothing is sent.</summary>
public sealed class RewriteGuardScreenTests
{
    private static Connector Two() => new(RewriteDurationSettleTests.TwoChanges, (_, ordinals) => Rows(ordinals, "x"));

    private static RewriteSession TwoPhrases(Runner[] runners)
    {
        var session = Session(Two(), last: 16);
        RewriteOwnTakeTests.ConfigureWithSource(session, index => runners[index]);
        return session;
    }

    private static async Task PriceAsync(RewriteSession session)
    {
        await session.DiscoverWindowsAsync();
        foreach (var window in session.GenerationWindows) await window.PendingUpdate;
    }

    [Fact]
    public async Task GetPriceNeverPricesAPhraseTheGuardBlocks()
    {
        Runner[] runners =
        [
            new((_, _) => (Fit, Passed)) { Screen = inputs => [VoiceGuardVerdict.Blocked(VoiceConsentError.VoiceOwnerMismatch), VoiceGuardVerdict.Passes(new(.8, "another-video"))] },
            new((_, _) => (Fit, Passed))
        ];
        using var session = TwoPhrases(runners);
        Assert.True(await ProposeAsync(session));
        await PriceAsync(session);
        Assert.Equal(1, runners[0].Screens);
        var windows = session.GenerationWindows;
        Assert.Equal(RewriteSession.BlockedCopy(new VoiceConsentException(VoiceConsentError.VoiceOwnerMismatch)), windows[0].Blocked);
        Assert.Null(windows[1].Blocked);
        // The price and its approval cover phrase 2 only; nothing was sent.
        Assert.Same(windows[1], Assert.Single(session.PricedWindows));
        var batch = session.PreparedBatch!;
        Assert.Single(batch.Windows);
        Assert.Equal(.06m, batch.Estimate.Usd);
        Assert.All(runners, runner => Assert.Equal(0, runner.Sends));
        Assert.False(session.LearnedFromThisVideo, "phrase 2 matched another video's reference");
        session.MarkBatchEstimateShown(batch);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        Assert.Equal(0, runners[0].Executions);
        Assert.Equal(1, runners[1].Sends);
        // A later price of the same plan still leaves phrase 1 out, even when the screen would pass it now.
        await PriceAsync(session);
        Assert.NotNull(windows[0].Blocked);
        Assert.Equal(0, runners[0].Executions);
    }

    [Fact]
    public async Task EveryPhraseBlockedBeforePricingAsksForNoPrice()
    {
        Runner[] runners =
        [
            new((_, _) => (Fit, Passed)) { Screen = _ => [VoiceGuardVerdict.Blocked(VoiceConsentError.VoiceOwnerMismatch), VoiceGuardVerdict.Blocked(VoiceConsentError.SpeakerMismatch)] },
            new((_, _) => (Fit, Passed))
        ];
        using var session = TwoPhrases(runners);
        Assert.True(await ProposeAsync(session));
        await PriceAsync(session);
        Assert.Null(session.PreparedBatch);
        Assert.False(session.CanGenerateAll);
        Assert.True(session.EveryPhraseBlocked);
        Assert.Equal(RewriteSession.BlockedCopy(new VoiceConsentException(VoiceConsentError.SpeakerMismatch)), session.GenerationWindows[1].Blocked);
        Assert.NotNull(session.EveryPhraseBlockedCard);
        Assert.Equal(RewriteFooterAction.KeepOriginal, session.FooterStep.Action);
        Assert.All(runners, runner => Assert.Equal(0, runner.Executions));
    }

    [Fact]
    public async Task APhraseMatchedThroughThisVideosReferenceSaysSo()
    {
        var runner = new Runner((_, _) => (Fit, Passed)) { Screen = inputs => [VoiceGuardVerdict.Passes(new(.8, inputs[0].ContentKey))] };
        using var session = Session(new(Reply, (_, ordinals) => Rows(ordinals, "x")));
        Configure(session, runner);
        Assert.True(await ProposeAsync(session));
        await PriceAsync(session);
        Assert.True(session.LearnedFromThisVideo);
        Assert.Equal("Nothing paid yet. Matched your voice from this video.", session.ReviewFooter);
        Assert.NotNull(session.PreparedBatch);
        Assert.Null(session.GenerationWindows[0].Blocked);
    }

    /// <summary>No price is shown or approvable while the guard screens; the footer says it is checking.</summary>
    [Fact]
    public async Task NothingIsPricedWhileTheGuardScreens()
    {
        var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var runner = new Runner((_, _) => (Fit, Passed)) { ScreenHold = hold };
        using var session = Session(new(Reply, (_, ordinals) => Rows(ordinals, "x")));
        Configure(session, runner);
        Assert.True(await ProposeAsync(session));
        var pricing = session.DiscoverWindowsAsync();
        for (var spin = 0; spin < 200 && runner.Screens == 0; spin++) await Task.Yield();
        Assert.Equal(1, runner.Screens);
        Assert.True(session.ScreeningVoice);
        Assert.Null(session.PreparedBatch);
        Assert.False(session.CanGenerateAll);
        Assert.Equal(RewriteSession.ScreeningCopy, session.FooterStep.Line);
        hold.SetResult();
        await pricing;
        Assert.False(session.ScreeningVoice);
        Assert.NotNull(session.PreparedBatch);
    }

    /// <summary>The production runner has no speaker check behind the closed parity gate: its screen leaves every phrase unchecked, so
    /// nothing is blocked or learned before pricing.</summary>
    [Fact]
    public async Task TheInertScreenLeavesEveryPhraseUnchecked()
    {
        IVoiceLabTakeRunner inert = new InertRunner();
        var verdicts = await inert.ScreenGuardAsync([null!, null!], TestContext.Current.CancellationToken);
        Assert.Equal(2, verdicts.Count);
        Assert.All(verdicts, verdict => Assert.Same(VoiceGuardVerdict.Unchecked, verdict));
    }

    private sealed class InertRunner : IVoiceLabTakeRunner
    {
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default) => throw new InvalidOperationException();
        public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved, Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null,
            CancellationToken ct = default) => throw new InvalidOperationException();
        public Task DiscardPendingAsync() => Task.CompletedTask;
        public void InvalidatePreparation() { }
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => false;
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => Task.FromResult(cap);
        public Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default) => throw new InvalidOperationException();
    }
}

/// <summary>A scripted speaker for the guard's screen in the smoke twins (Mac <c>RewriteSmokeSpeaker</c>): each phrase's speech embeds to a
/// fixed vector by its first word, and the screen follows <see cref="VoiceUseGuard.ScreenAsync"/>'s steps over Core's own reference rules:
/// the best phrase passing against the statement teaches this video's reference (one hop), then every phrase is matched against the
/// statement and the usable references. The learned references persist between screens, as the consent store keeps them.</summary>
internal sealed class ScriptedScreen(IReadOnlyDictionary<string, float[]> byFirstWord)
{
    internal const double Threshold = 0.45;
    internal const string Model = "wespeaker-resnet34";
    internal static readonly float[] Owner = [1, 0, 0, 0];
    /// <summary>0.6 against the owner: passes on its own and teaches.</summary>
    internal static readonly float[] Near = [3, 4, 0, 0];
    /// <summary>0.24 against the owner, 0.90 against <see cref="Near"/>: passes only through the reference this video taught.</summary>
    internal static readonly float[] Beside = [1, 4, 1, 0];
    /// <summary>A guest: 0 against the owner and against <see cref="Near"/>.</summary>
    internal static readonly float[] Guest = [0, 0, 1, 0];
    internal VoiceConsentSpeaker Speaker { get; private set; } = new(Model, Threshold, VoiceConsentRecord.EncodeEmbedding(Owner));

    internal IReadOnlyList<VoiceGuardVerdict> Screen(IReadOnlyList<VoiceLabTakeInput> inputs)
    {
        var vectors = inputs.Select(input => byFirstWord.TryGetValue(input.Window.FirstWordId, out var vector) ? vector : null).ToArray();
        var passing = vectors.Where(vector => vector is not null).Select(vector => (Match: VoiceSpeakerReferences.Match(vector!, Speaker), Vector: vector!))
            .Where(item => item.Match is { ViaReference: false }).MaxBy(item => item.Match!.Score);
        if (passing.Vector is { } best)
            try { Speaker = VoiceSpeakerReferences.Learning(best, inputs[0].ContentKey, Model, DateTimeOffset.UnixEpoch, Speaker); }
            catch (VoiceReferenceRefusedException) { }
        return vectors.Select(vector => vector is null ? VoiceGuardVerdict.Unchecked
            : VoiceSpeakerReferences.Match(vector, Speaker) is { } match ? VoiceGuardVerdict.Passes(match) : VoiceGuardVerdict.Blocked(VoiceConsentError.VoiceOwnerMismatch)).ToArray();
    }
}
#endif
