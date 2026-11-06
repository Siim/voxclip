#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>design.md R2 "A take that can't fit its place" on Windows (Mac track/v2-duration-deadend, <c>ClipTakePlanTests</c>): a take no
/// video duration can carry keeps its phrase's recorded audio with one line and no click, and Use goes on with the rest; a too-long take is
/// left to the armed resolver or the measured rewording round first; a too-short one is never reworded longer; such a take is never
/// offered as [Choose Take N]; the footer asks for a duration only when one is allowed, with that choice as its primary. Stubs only.</summary>
public sealed class RewriteDurationSettleTests
{
    /// <summary>Words 10 and 14 change, words 11–13 stay: two phrases.</summary>
    internal const string TwoChanges = "a much clearer phrasing word11 word12 word13 a brighter phrasing word15 word16";
    /// <summary>A take this many seconds long fits no duration of a phrase's slot: too short to keep the source, no clean cut, and far
    /// outside the matched speed (Mac S-duration-short's 0.41 s take for a 1.7 s slot).</summary>
    internal const double TooShort = 0.1;

    private static (RewriteSession Session, Runner[] Runners) TwoPhrases(Connector connector, params Runner[] runners)
    {
        var session = Session(connector, last: 16);
        RewriteOwnTakeTests.ConfigureWithSource(session, index => runners[index]);
        return (session, runners);
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
    public async Task ATakeTooShortForEveryDurationKeepsItsAudioWithNoClickAndUseGoesOn()
    {
        var connector = new Connector(TwoChanges, (_, ordinals) => Rows(ordinals, "x"));
        var (session, runners) = TwoPhrases(connector, new((_, _) => (TooShort, Passed)), new((_, _) => (Fit, Passed)));
        using var _ = session;
        Assert.True(await ProposeAsync(session));
        await PriceAndMakeAsync(session);
        var windows = session.GenerationWindows;
        Assert.Equal(2, windows.Count);
        var take = Assert.Single(windows[0].Rows);
        Assert.True(take.Selectable);
        Assert.False(windows[0].DurationAvailable(take));
        // Kept as recorded with one line, said once and with no click; the other phrase is used.
        Assert.True(windows[0].LeftOut, windows[0].TakeDetail);
        Assert.False(windows[1].LeftOut);
        Assert.NotNull(windows[1].Selected);
        var line = "Phrase 1's take can't fit its place in the video, so it keeps your original audio.";
        Assert.Equal(line, RewriteSession.NoDurationCopy([1]));
        Assert.Single(session.AutoFix.Notes, note => note == line);
        Assert.Equal(line, session.AutoFix.Announcement);
        // A too-short take is never reworded longer, which would only pad (ADR-R42): no round, no second take.
        Assert.Empty(session.AutoFix.Rounds);
        Assert.DoesNotContain(connector.FitRequests, request => request.CachedBlock!.Contains("Measured take:", StringComparison.Ordinal));
        Assert.Equal(1, runners[0].Sends);
        Assert.Null(session.StuckReason(0));
        // No footer asks for a duration no control makes, and nothing waits on phrase 1.
        Assert.Null(session.AcceptanceBlocker);
        Assert.DoesNotContain("Choose the video duration", session.FooterStep.Line, StringComparison.Ordinal);
        Assert.NotEqual(0, session.FooterStep.Phrase);
        session.AdvanceAutoFix();
        Assert.Single(session.AutoFix.Notes, note => note == line);
    }

    [Fact]
    public async Task ATooShortMeasuredTakeKeepsTheRecordingWithoutARewordingRound()
    {
        // Mac aTooShortMeasuredTakeKeepsTheRecordingWithoutARewordingRound: one take made by its own click (no Get Price, so the measured
        // round, not the resolver, would answer a too-long take).
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "said briefly"));
        var runner = new Runner((_, _) => (TooShort, Passed));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        await session.MeasuredWork;
        Assert.False(session.AutoFix.Armed);
        Assert.Null(session.MeasuredWording);
        Assert.DoesNotContain(connector.FitRequests, request => request.CachedBlock!.Contains("Measured take:", StringComparison.Ordinal));
        Assert.True(generation.LeftOut);
        Assert.Contains(RewriteSession.NoDurationCopy([1]), session.AutoFix.Notes);
        Assert.Equal(1, runner.Sends);
    }

    [Fact]
    public async Task ATooLongTakeWaitsForTheMeasuredRoundAndIsSettledWhenTheRoundIsDeclined()
    {
        // Mac measuredRewordingPreparesButNeverPaysAndDecliningKeepsTheRecording: the round offers a shorter wording before the phrase is
        // settled; the settle waits while it runs or waits on the creator.
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "said briefly"));
        var runner = new Runner((_, _) => (5.8, Passed));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        await session.MeasuredWork;
        var suggestion = session.MeasuredWording!;
        Assert.True(suggestion.TooLong);
        Assert.Equal("said briefly", suggestion.Text);
        Assert.True(generation.FitsNoDuration);
        Assert.False(generation.LeftOut);
        Assert.DoesNotContain(RewriteSession.NoDurationCopy([1]), session.AutoFix.Notes);
        session.AdvanceAutoFix();
        Assert.False(generation.LeftOut);
        Assert.Equal("Keep Original Audio", session.MeasuredKeepTitle(suggestion));
        await session.KeepMeasuredTakeAsync();
        Assert.True(generation.LeftOut);
        Assert.Contains(RewriteSession.NoDurationCopy([1]), session.AutoFix.Notes);
        Assert.Equal(1, runner.Sends);
    }

    [Fact]
    public async Task ATooLongTakeIsLeftToTheArmedResolver()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "said briefly"));
        var runner = new Runner((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        // The resolver reworded it shorter and made a take that fits, instead of keeping the recording at once.
        Assert.Equal(2, runner.Sends);
        Assert.False(window.LeftOut);
        Assert.Equal(window.Rows[1].Id, window.SelectedTakeId);
        Assert.DoesNotContain(RewriteSession.NoDurationCopy([1]), session.AutoFix.Notes);
    }

    [Fact]
    public async Task AnUnmeasuredTakeNoDurationCarriesIsNeverOfferedAndKeepsItsAudio()
    {
        // ADR-R37: a passing take whose voice couldn't be measured is offered for the user's click only when a duration can carry it.
        var connector = new Connector(TwoChanges, (_, ordinals) => Rows(ordinals, "x"));
        var unmeasured = new VoiceLabShortSpeechEvidence(VoiceLabShortSpeechMode.Unmeasured, "record", VoiceConsentMethod.RecordedStatement, 16_000, 1);
        var (session, _) = TwoPhrases(connector, new((_, _) => (TooShort, Passed)) { Voice = _ => VoiceLabTakeVoiceCheck.ShortSpeech(unmeasured) },
            new((_, _) => (Fit, Passed)));
        using var disposed = session;
        Assert.True(await ProposeAsync(session));
        await PriceAndMakeAsync(session);
        var window = session.GenerationWindows[0];
        var take = Assert.Single(window.Rows);
        Assert.True(take.Selectable);
        Assert.Null(window.OfferedTake());
        Assert.True(window.LeftOut);
        Assert.Contains(RewriteSession.NoDurationCopy([1]), session.AutoFix.Notes);
        Assert.NotEqual(RewriteFooterAction.ChooseTake, session.FooterStep.Action);
    }

    [Fact]
    public async Task ADurationAllowedButNotChosenIsTheFootersPrimary()
    {
        // Phrase 1's 1.45 s take runs past its 1.3 s fit window: the matched speed (0.90×) carries it. Windows chooses a valid duration as the take lands
        // (Mac autoChooseVideo), so the undecided state is set up by clearing that choice.
        var connector = new Connector(TwoChanges, (_, ordinals) => Rows(ordinals, "x"));
        var (session, _) = TwoPhrases(connector, new((_, _) => (1.45, Passed)), new((_, _) => (Fit, Passed)));
        using var disposed = session;
        Assert.True(await ProposeAsync(session));
        await PriceAndMakeAsync(session);
        var window = session.GenerationWindows[0];
        Assert.False(window.Selected?.Fits ?? true, window.TakeDetail);
        Assert.NotEmpty(window.ValidVideoChoices);
        Assert.False(window.FitsNoDuration);
        var choice = window.ValidVideoChoices[0];
        const System.Reflection.BindingFlags Internal = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        typeof(RewriteGeneration).GetProperty(nameof(RewriteGeneration.VideoChoice), Internal)!.SetValue(window, null);
        typeof(RewriteGeneration).GetProperty(nameof(RewriteGeneration.Phase), Internal)!.SetValue(window, RewriteGenerationPhase.LengthChanged);
        Assert.Equal("Choose the video duration for phrase 1.", session.AcceptanceBlocker);
        var footer = session.FooterStep;
        Assert.Equal(RewriteFooterAction.ChooseDuration, footer.Action);
        Assert.Equal(RewriteSession.DurationTitle(choice, 0), footer.Title);
        Assert.Equal(0, footer.Phrase);
        // The click is what the phrase card's duration radio does.
        Assert.True(session.ChooseDuration(footer.Phrase));
        Assert.Equal(choice, window.VideoChoice);
        Assert.Null(session.AcceptanceBlocker);
        Assert.False(session.ChooseDuration(0));
        Assert.Equal("Keep Source Duration for Phrase 1", RewriteSession.DurationTitle(VoiceLabVideoMode.Source, 0));
        Assert.Equal("Cut the Video for Phrase 1", RewriteSession.DurationTitle(VoiceLabVideoMode.Cut, 0));
        Assert.Equal("Match the Video for Phrase 2", RewriteSession.DurationTitle(VoiceLabVideoMode.Retimed, 1));
        Assert.Equal("Phrase 3's take can't fit its place in the video.", RewriteSession.NoDurationCopy([3], kept: false));
        Assert.Equal("The takes of phrases 1 and 3 can't fit their places in the video, so they keep your original audio.", RewriteSession.NoDurationCopy([1, 3]));
    }

    [Fact]
    public async Task AWaitingTakeNoDurationCarriesHasKeepOriginalAudioNeverADurationRequest()
    {
        // After Stop the resolver still owns a too-long take (its own steps); the footer names it and keeps its audio with one click.
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "said briefly")) { HoldFits = true };
        var runner = new Runner((_, _) => (5.8, Passed));
        using var session = await PricedAsync(connector, runner);
        await connector.FitSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        session.StopAutoFix();
        connector.Release.SetResult();
        await session.MeasuredWork;
        await SettleAsync(session);
        var window = session.Generation!;
        Assert.False(window.LeftOut);
        Assert.Equal("Phrase 1's take can't fit its place in the video.", session.AcceptanceBlocker);
        var footer = session.FooterStep;
        Assert.Equal(RewriteFooterAction.KeepOriginal, footer.Action);
        Assert.Equal("Keep Original Audio for Phrase 1", footer.Title);
        Assert.True(session.KeepOriginal(footer.Phrase));
        Assert.True(window.LeftOut);
        Assert.Equal(1, runner.Sends);
    }
}
#endif
