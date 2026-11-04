#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Phrase cards on Windows (Mac stucktakes): durations only with a passing take, the first valid one chosen at once,
/// the forward-looking status line, quote marks on the words, and per-phrase expressions with click-to-place that never discard
/// paid takes. Stub connectors and runners only.</summary>
public sealed class RewritePhraseCardsTests
{
    [Fact]
    public async Task APassingTakeThatNeedsAChangedDurationGetsTheFirstValidOneAtOnce()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (1.5, Passed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        Assert.False(window.Selected!.Fits);
        Assert.DoesNotContain(VoiceLabVideoMode.Source, window.ValidVideoChoices);
        Assert.NotEmpty(window.ValidVideoChoices);
        Assert.Equal(window.ValidVideoChoices[0], window.VideoChoice);
        Assert.Equal(RewriteGenerationPhase.ReadyToAccept, window.Phase);
        Assert.StartsWith("Video: ", window.VideoChoiceLine);
        Assert.Null(session.StuckReason(0));
        Assert.Null(session.AcceptanceBlocker);
        Assert.Equal(1, runner.Sends);
        Assert.Matches(@"^Take 1 · 1\.5 s · video (cut to fit|matched)$", session.PhraseStatus(0));
    }

    [Fact]
    public async Task NoDurationChoiceShowsBeforeAPassingTake()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (1.1, WordsFailed));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        Assert.Empty(session.Generation!.ValidVideoChoices);
        Assert.Equal("Takes start after you approve the price.", session.PhraseStatus(0));
    }

    [Fact]
    public async Task AnExpressionAfterTakesChangesOnlyItsPhraseKeepsThePaidTakeAndMakesANewOne()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        var paid = Assert.Single(window.Rows);
        var tag = VoiceLabAudioTags.Definitions[0].Tag;
        Assert.True(session.AddExpression(1, tag));
        Assert.Null(session.PendingPaidReviewChange);
        Assert.Same(window, session.Generation);
        Assert.True(window.IsBeforeExpression(paid.Id));
        var added = Assert.Single(session.ShownAudioTags(1));
        Assert.Equal(new VoiceLabAudioTag(0, tag), added);
        await SettleAsync(session);
        Assert.Equal(2, runner.Sends);
        Assert.Equal(2, window.Rows.Count);
        Assert.Equal(window.Rows[1].Id, window.SelectedTakeId);
        Assert.False(window.IsBeforeExpression(window.Rows[1].Id));
        Assert.Contains(runner.Input!.AudioTags, audio => audio.Tag == tag);
        Assert.Equal(.06m, session.AutoFix.Spent);
        Assert.True(session.MoveExpression(1, 0, 2));
        Assert.Equal(2, Assert.Single(session.ShownAudioTags(1)).BeforeToken);
    }

    [Fact]
    public async Task KeptPhrasesSayWhatHappensNext()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        Assert.Equal("Take 1 · 1.0 s · fits", session.PhraseStatus(0));
        Assert.True(session.KeepOriginal(0));
        Assert.Equal("Keeps your original words. Its takes stay listed.", session.PhraseStatus(0));
    }

    [Fact]
    public void QuoteMarksSitOnTheWordsOrStandAloneBesideATag()
    {
        string Render(IReadOnlyList<VoiceLabAudioTag> tags) => string.Join(" ", RewriteQuote.Pieces(["a", "much", "clearer"], tags)
            .Select(piece => piece.Tag is null ? piece.Text : "[" + piece.Text + "]"));
        Assert.Equal("“a much clearer”", Render([]));
        Assert.Equal("“ [laughs] a much clearer”", Render([new(0, "laughs")]));
        Assert.Equal("“a much [sighs] clearer”", Render([new(2, "sighs")]));
        Assert.Equal("“a much clearer [laughs] ”", Render([new(3, "laughs")]));
    }
}
#endif
