#if WIN_UI_TESTS
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinUi.RewriteAutoFixTests;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>The learning fix loop (voice-lab.md §8.2.2; Mac RewriteAutoFix, RewriteWordingFit): failure classes, where only wording
/// and fit failures reword; provider failures show their cause and fix with [Price a take] and [Keep original words]; the tried
/// history and bridge words sent with each measured round; one free re-ask for a reply that drops the bridge words; no repeat
/// or non-moving wording is voiced; "Round k of 3 · tried: …". Stub connectors and runners only.</summary>
public sealed class RewriteLearningLoopTests
{
    /// <summary>The Rewrite reply changes word11 only; word11 starts where word10 ends, so the window bridges word10.</summary>
    internal const string BridgedReply = "word10 shiny brand new golden words for you word12";

    [Fact]
    public async Task AProviderFailureShowsItsCauseAndFixWithPriceATakeAndKeepOriginalWordsAndNoWordingChips()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"))
            { NextActions = [new System.Text.Json.Nodes.JsonObject { ["label"] = "Say it plainer", ["instruction"] = "Use plainer words.", ["ordinals"] = new System.Text.Json.Nodes.JsonArray(1) }] };
        var runner = new Runner((_, _) => (Fit, Passed)) { Fails = (run, _) => run == 1 ? (new VoiceLabException(VoiceLabErrorKind.QuotaExceeded), true) : null };
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        Assert.Equal(1, runner.Sends);
        Assert.IsType<StuckTakeReason.Provider>(session.StuckReason(0));
        Assert.False(session.StuckReason(0)!.Rewords);
        Assert.True(session.AutoFix.Armed);
        Assert.False(session.AutoFix.Stopped);
        Assert.Empty(session.AutoFix.Rounds);
        Assert.Contains("Add credit to your ElevenLabs account, then choose Price a take.", session.Generation!.Problem);
        var card = Assert.Single(session.NextStepCards, card => card.Id == "Rewrite.Steps.Phrase1");
        Assert.Contains("Add credit to your ElevenLabs account, then choose Price a take.", card.Sentence);
        Assert.Equal(["Rewrite.Chip.PriceTake1", "Rewrite.Chip.KeepPhrase1"], card.Chips.Select(chip => chip.Id));
        Assert.Equal(["Price a take", "Keep original words"], card.Chips.Select(chip => chip.Title));
        Assert.DoesNotContain(card.Chips, chip => chip.Ai);
        Assert.Empty(connector.FitRequests);
        Assert.Empty(connector.Reasks);
        // [Price a take] prices a new take and shows its price; only the priced click makes it.
        await card.Chips[0].Invoke!();
        Assert.Equal(1, runner.Sends);
        var priced = Assert.Single(session.NextStepCards, card => card.Id == "Rewrite.Steps.Phrase1");
        Assert.Equal("Make take · ≈ $0.06", priced.Chips[0].Title);
        await priced.Chips[0].Invoke!();
        await SettleAsync(session);
        Assert.Equal(2, runner.Sends);
        Assert.Null(session.StuckReason(0));
    }

    [Fact]
    public async Task ATakeWithNoWordTimingTriesAnotherOnceThenKeepsTheOriginalWordsWithoutRewording()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x")) { Reask = "plainly said word11 word12" };
        var runner = new Runner((_, _) => (Fit, Passed)) { Fails = (_, _) => (new VoiceLabException(VoiceLabErrorKind.InvalidAlignment), false) };
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        Assert.Equal(2, runner.Sends);
        Assert.Contains(0, session.AutoFix.TriedAnother);
        Assert.Contains(0, session.AutoFix.GaveUp);
        Assert.True(session.Generation!.LeftOut);
        Assert.Empty(connector.FitRequests);
        Assert.Empty(connector.Reasks);
        Assert.Equal("Phrase 1: its take's word timing couldn't be read, even from the word check.",
            RewriteSession.StuckSentence(new StuckTakeReason.Timing(), 1));
    }

    [Fact]
    public async Task AMeasuredRoundSendsTheBridgeAndTriedHistoryAndAReplyThatDropsTheBridgeGetsOneFreeReask()
    {
        var connector = Measured(BridgedReply, request => request == 1 ? "brief words" : "word10 brief");
        var runner = new Runner((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed));
        using var session = await PricedAsync(connector, runner, BridgedSession);
        await SettleAsync(session);
        Assert.Equal(2, connector.FitRequests.Count);
        Assert.Contains("Required: the text must begin with “word10”", connector.FitRequests[0].CachedBlock);
        Assert.Contains("- “word10 shiny brand new golden words for you”: too long by", connector.FitRequests[0].CachedBlock);
        Assert.Contains("- “brief words”: dropped the joining words, not used", connector.FitRequests[1].CachedBlock);
        Assert.Equal(1, session.AutoFix.Rounds[0]);
        Assert.Equal(2, runner.Sends);
        var window = session.Generation!;
        Assert.Equal("word10 brief", window.InputFor(window.Rows[1].Id)!.Text);
        Assert.Equal(window.Rows[1].Id, window.SelectedTakeId);
        var line = session.AutoFixHistoryLine(0);
        Assert.NotNull(line);
        Assert.StartsWith("Round 1 of 3 · tried: “word10 shiny brand new golden words for you” (", line);
        Assert.Contains("“brief words” (dropped “word10”, not used)", line);
        Assert.Contains("“word10 brief” (fits)", line);
    }

    [Fact]
    public async Task AReaskThatStillDropsTheBridgeEndsTheRoundWithItsLineAndNoTake()
    {
        var connector = Measured(BridgedReply, request => request == 1 ? "brief words" : "short words");
        var runner = new Runner((_, _) => (5.8, Passed));
        using var session = await PricedAsync(connector, runner, BridgedSession);
        await SettleAsync(session);
        Assert.Equal(1, runner.Sends);
        Assert.True(connector.FitRequests.Count >= 2);
        Assert.Contains("“brief words” (dropped “word10”, not used)", session.AutoFixHistoryLine(0));
        Assert.Contains("“short words” (dropped “word10”, not used)", session.AutoFixHistoryLine(0));
        Assert.Contains("- “brief words”: dropped the joining words, not used", connector.FitRequests[1].CachedBlock);
        Assert.All(session.Generation!.Rows, row => Assert.Equal("word10 shiny brand new golden words for you", session.Generation.InputFor(row.Id)!.Text));
    }

    [Fact]
    public async Task AnAutomaticRoundNeverVoicesARepeatOrAWordingThatDoesNotMoveTowardTheSlot()
    {
        // Round 1's reply repeats the measured wording; round 2's is longer than it; round 3's is shorter and is voiced.
        var connector = Measured(BridgedReply, request => request switch
        {
            1 => "Word10, shiny brand new golden words for you!",
            2 => "word10 shiny brand new golden words for you and many more words than before",
            _ => "word10 brief"
        });
        var runner = new Runner((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed));
        using var session = await PricedAsync(connector, runner, BridgedSession);
        await SettleAsync(session);
        Assert.Equal(3, connector.FitRequests.Count);
        Assert.Contains("- “Word10, shiny brand new golden words for you!”: repeated an earlier wording, not used", connector.FitRequests[1].CachedBlock);
        Assert.Contains("was not shorter, not used", connector.FitRequests[2].CachedBlock);
        Assert.Equal(2, runner.Sends);
        Assert.Equal(3, session.AutoFix.Rounds[0]);
        var line = session.AutoFixHistoryLine(0)!;
        Assert.StartsWith("Round 3 of 3 · tried: ", line);
        Assert.Contains("(repeat, not used)", line);
        Assert.Contains("(not shorter, not used)", line);
    }

    [Fact]
    public async Task WordingSuggestionsShowOnlyForWordingAndFitFailuresAndNeverRepeatATriedWording()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"))
        {
            NextActions =
            [
                new System.Text.Json.Nodes.JsonObject { ["label"] = "Say it plainer", ["instruction"] = "Use plainer words.", ["ordinals"] = new System.Text.Json.Nodes.JsonArray(1) },
                new System.Text.Json.Nodes.JsonObject { ["label"] = "Say it plainer", ["instruction"] = "Use plainer words.", ["ordinals"] = new System.Text.Json.Nodes.JsonArray(1) },
            ]
        };
        var voice = new VoiceLabTakeQaResult(.95, 0, -3, .2, [VoiceLabTakeQaFailure.Speaker]);
        var runner = new Runner((_, _) => (Fit, voice));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        session.StopAutoFix();
        Assert.IsType<StuckTakeReason.Voice>(session.StuckReason(0));
        var card = Assert.Single(session.NextStepCards, card => card.Id == "Rewrite.Steps.Phrase1");
        Assert.DoesNotContain(card.Chips, chip => chip.Id.StartsWith("Rewrite.Chip.Ai", StringComparison.Ordinal));
        using var words = await PricedAsync(new Connector(Reply, (_, ordinals) => Rows(ordinals, "x")) { NextActions = connector.NextActions, Reask = "plainly said word11 word12" },
            new Runner((_, _) => (Fit, WordsFailed)));
        await SettleAsync(words);
        words.StopAutoFix();
        var wording = Assert.Single(words.NextStepCards, card => card.Id == "Rewrite.Steps.Phrase1");
        Assert.Single(wording.Chips, chip => chip.Id.StartsWith("Rewrite.Chip.Ai", StringComparison.Ordinal));
    }

    [Fact]
    public void AnAccountFailureNamesItsOneFix()
    {
        Assert.Equal("Add credit to your ElevenLabs account, then choose Price a take.", RewriteSession.ProviderFix(VoiceLabErrorKind.QuotaExceeded));
        Assert.Equal("Check the ElevenLabs key in Settings, then choose Price a take.", RewriteSession.ProviderFix(VoiceLabErrorKind.Unauthorized));
        Assert.Equal("Check the ElevenLabs key in Settings, then choose Price a take.", RewriteSession.ProviderFix(VoiceLabErrorKind.MissingKey));
        Assert.Equal("Give the ElevenLabs key the Text to Speech permission, then choose Price a take.", RewriteSession.ProviderFix(VoiceLabErrorKind.PermissionMissing));
        Assert.Equal("Choose Price a take to send it again.", RewriteSession.ProviderFix(VoiceLabErrorKind.Network));
        Assert.Null(RewriteSession.ProviderFix(VoiceLabErrorKind.InvalidAlignment));
        Assert.True(RewriteSession.IsAccountFailure(VoiceLabErrorKind.ModelAccessDenied));
        Assert.False(RewriteSession.IsAccountFailure(VoiceLabErrorKind.InvalidAlignment));
    }

    [Fact]
    public async Task TheFootersLastFallbacksNameTheirControl()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed)) { Fails = (_, _) => (new VoiceLabException(VoiceLabErrorKind.QuotaExceeded), true) };
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        // A provider-stuck phrase names its fix above; past it, a phrase with no take to use offers Keep original words.
        Assert.True(session.FooterStep.Line.Contains("Choose a next step above.", StringComparison.Ordinal), session.FooterStep.ToString());
        Assert.Equal(RewriteFooterAction.None, session.FooterStep.Action);
        Assert.Equal(new RewriteFooterStep("Phrase 1 has no take to use.", "Keep original words for phrase 1", RewriteFooterAction.KeepOriginal, 0),
            RewriteSession.NoTakeToUseStep(0));
        Assert.Equal(new RewriteFooterStep("Phrase 2 has no take yet.", "Price a take for phrase 2", RewriteFooterAction.PriceTake, 1), RewriteSession.NoTakeYetStep(1));
    }

    /// <summary>A stub fit connector for measured rounds: <paramref name="reply"/> gets the measured request's number (1-based).</summary>
    internal static Connector Measured(string rewrite, Func<int, string> reply)
    {
        Connector? connector = null;
        connector = new(rewrite, (_, ordinals) =>
        {
            var last = connector!.FitRequests[^1].CachedBlock!;
            // A fit round before takes keeps the proposal as it is.
            if (!last.Contains("Measured take:", StringComparison.Ordinal))
                return Rows(ordinals, System.Text.RegularExpressions.Regex.Match(last, "Current proposal: (.*)").Groups[1].Value);
            return Rows(ordinals, reply(connector.FitRequests.Count(request => request.CachedBlock!.Contains("Measured take:", StringComparison.Ordinal))));
        });
        return connector;
    }

    internal static RewriteSession BridgedSession(Connector connector) =>
        new(BridgedEditor(), 10, 12, RewriteAutoFixTests.Envelope(), new(connector, "chosen", "Stub", "local", ""), consent: _ => Task.FromResult(true));

    /// <summary>The fix-loop editor with word11 starting where word10 ends: no seam fits between them, so word10 bridges.</summary>
    internal static EditorViewModel BridgedEditor()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
        var words = Enumerable.Range(0, 80).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word,
            index == 11 ? 11.4 : index + 1, index == 11 ? 11.8 : index + 1.4, null, null, 1, null, TimingSource.Native)).ToArray();
        project = project with { Transcript = project.Transcript! with { Words = words },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } };
        return new(project, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
    }
}
#endif
