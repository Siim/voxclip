#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteLearningLoopTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>My words (design.md §6.3.8, voice-lab.md §8.13; Mac PhraseOwnWords): the segmented control, one field that starts from
/// the change, the live "Your voice reads this…" line, [Make take · ≈ $x] through the priced path once its quote is for these words,
/// ✦ Shorten/Lengthen that fills the field and sends no take, and the resolver and measured reword skipping the user's words.</summary>
public sealed class RewriteOwnWordsTests
{
    internal const string Change = "shiny brand new golden words for you";

    [Fact]
    public async Task MyWordsStartFromTheChangeAndTheirTakeVoicesThemBetweenTheBridgeWords()
    {
        var connector = Measured(BridgedReply, _ => "x");
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = await PricedAsync(connector, runner, BridgedSession);
        await SettleAsync(session);
        var window = session.Generation!;
        Assert.Equal(PhraseWording.Suggested, session.Wording(0));
        Assert.Equal(Change, session.ChangeWords(0));
        await session.ChooseWordingAsync(PhraseWording.OwnWords, 0);
        Assert.Equal(PhraseWording.OwnWords, session.Wording(0));
        Assert.Equal(0, session.OwnWordsEditing);
        Assert.Equal(Change, session.OwnWords(0));
        Assert.Equal("word10 " + Change, session.OwnWordsText(0));
        session.EditOwnWords("bright words here for all of you", 0);
        // Typing drops the unpaid quote: [Make take] waits for the price of these words.
        Assert.Null(session.OwnWordsTakeTitle(0));
        await session.PriceOwnWordsAsync(0);
        Assert.Equal("Make take · ≈ $0.06", session.OwnWordsTakeTitle(0));
        Assert.Equal(1, runner.Sends);
        await session.MakeOwnWordsTakeAsync(0, (_, _) => Task.FromResult(true));
        Assert.Equal(2, runner.Sends);
        Assert.Equal("word10 bright words here for all of you", runner.Input!.Text);
        Assert.Equal(2, window.Rows.Count);
        Assert.Equal("word10 bright words here for all of you", window.InputFor(window.Rows[1].Id)!.Text);
        // Switching back keeps every take; the next take follows the suggestion again.
        await session.ChooseWordingAsync(PhraseWording.Suggested, 0);
        Assert.Equal(2, window.Rows.Count);
        Assert.Equal("word10 " + Change, session.CurrentWording(0));
        Assert.Null(session.OwnWordsTakeTitle(0));
    }

    [Fact]
    public async Task TheLiveLineReadsTheEstimateAndTheGapWithThePlansVerdict()
    {
        var connector = Measured(BridgedReply, _ => "x");
        using var session = await PricedAsync(connector, new Runner((_, _) => (Fit, Passed)), BridgedSession);
        await SettleAsync(session);
        await session.ChooseWordingAsync(PhraseWording.OwnWords, 0);
        var fit = session.OwnWordsFit(0)!;
        Assert.True(fit.Fits);
        Assert.Matches(@"^Your voice reads this\. 8 words · about \d\.\d s, the gap is 1\.7 s ✓$", fit.Line);
        session.EditOwnWords(string.Join(" ", Enumerable.Repeat("remarkably", 12)), 0);
        Assert.EndsWith("· likely too long", session.OwnWordsFit(0)!.Line);
        session.EditOwnWords("hi", 0);
        Assert.EndsWith("· likely too short", session.OwnWordsFit(0)!.Line);
        Assert.StartsWith("Your voice reads this. 2 words · about", session.OwnWordsFit(0)!.Line);
        session.EditOwnWords("", 0);
        Assert.Null(session.OwnWordsFit(0));
        Assert.Null(session.OwnWordsText(0));
    }

    [Fact]
    public async Task ShortenMyWordsFillsTheFieldWithoutTheBridgeWordsAndMakesNoTake()
    {
        // The phrase fits before takes, so the only fit request is the user's ✦ Shorten my words.
        var connector = new Connector(BridgedReply, (_, ordinals) => Rows(ordinals, "word10 golden words for you"));
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = await PricedAsync(connector, runner, BridgedSession);
        await SettleAsync(session);
        Assert.Empty(connector.FitRequests);
        await session.ChooseWordingAsync(PhraseWording.OwnWords, 0);
        session.EditOwnWords(string.Join(" ", Enumerable.Repeat("remarkably", 12)), 0);
        Assert.True(session.OwnWordsFit(0)!.TooLong);
        await session.AdviseOwnWordsAsync(0);
        var request = Assert.Single(connector.FitRequests);
        Assert.Contains("Current proposal: word10 remarkably", request.CachedBlock);
        Assert.Equal("golden words for you", session.OwnWords(0));
        Assert.Equal("word10 golden words for you", session.OwnWordsText(0));
        Assert.Equal(1, runner.Sends);
        Assert.Null(session.OwnWordsTakeTitle(0));
        Assert.False(session.OwnWordsAdvice.Running);
        Assert.Empty(session.OwnWordsAdvice.Problem);
        Assert.Equal(0, session.OwnWordsEditing);
    }

    [Fact]
    public async Task TheResolverAndTheMeasuredRewordNeverRewriteTheUsersWords()
    {
        var connector = Measured(BridgedReply, _ => "word10 brief");
        var runner = new Runner((_, _) => (5.8, Passed));
        using var session = BridgedSession(connector);
        Assert.True(await ProposeAsync(session));
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        await session.ChooseWordingAsync(PhraseWording.OwnWords, 0);
        session.EditOwnWords("bright words here for all of you", 0);
        await session.PriceOwnWordsAsync(0);
        var batch = session.PreparedBatch!;
        Assert.Equal("word10 bright words here for all of you", batch.Windows[0].Input.Text);
        session.MarkBatchEstimateShown(batch);
        await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        await SettleAsync(session);
        Assert.True(session.AutoFix.Armed);
        // The take of the user's own words fits no video duration, so the phrase keeps its recording (design.md R2): neither the
        // resolver nor the measured round owns the user's words.
        Assert.True(session.GenerationWindows[0].LeftOut);
        Assert.Contains(RewriteSession.NoDurationCopy([1]), session.AutoFix.Notes);
        Assert.Null(session.StuckReason(0));
        Assert.Equal(1, runner.Sends);
        Assert.Empty(session.AutoFix.Rounds);
        Assert.DoesNotContain(connector.FitRequests, request => request.CachedBlock!.Contains("Measured take:", StringComparison.Ordinal));
        Assert.Equal("word10 bright words here for all of you", runner.Input!.Text);
        Assert.Null(session.MeasuredWording);
    }
}
#endif
