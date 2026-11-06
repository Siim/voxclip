#if WIN_UI_TESTS
using System.Reflection;
using System.Text.Json.Nodes;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinUi;

/// <summary>Automatic wording fit on Windows, with stub connectors only: rounds, frozen phrases, keep-original, Stop, edits,
/// billed-connector approval, calibration and the measured rewording that never pays by itself.</summary>
public sealed class RewriteWordingFitTests
{
    private const string Fits = "a much clearer phrasing";
    private const string Short = "clearer";

    [Fact]
    public async Task APhraseThatFitsInRoundOneStopsTheRoundsAndShowsTheFittedRow()
    {
        var connector = new Connector(Short + " word11 word12", (_, ordinals) => Rows(ordinals, Fits));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Assert.Single(connector.FitRequests);
        Assert.Equal(Fits + " word11 word12", session.NewWords);
        Assert.Empty(session.BlockedVoiceHunks);
        Assert.Equal(1, session.WordingFitRound);
        Assert.True(session.WordingFitCompleted);
        Assert.False(session.WordingIsLocked);
        Assert.StartsWith("reworded to fit · was ≈ 0.9 s, now ≈ ", session.FitRowNote(1));
        Assert.EndsWith(" · slot 1.4 s", session.FitRowNote(1));
        Assert.Equal("1 phrases fit · 0 kept as recorded", session.ReviewFooter);
        var line = connector.FitRequests[0].CachedBlock!;
        Assert.Contains("Phrase 1\nOriginal words: word10\nCurrent proposal: clearer\n", line);
        Assert.Contains("say the same point more fully, about 1 more words of real content", line);
        Assert.Contains("Word budget: 1 to 3 words; never more than 3", line);
        Assert.False(session.Editor.LlmRuns.IsBusy);
        Assert.False(session.Editor.CanUndo);
    }

    /// <summary>One free round (ADR-R42, Mac <c>automaticFitRounds</c>): a phrase the round leaves too short is not asked again; it keeps its
    /// recovery row, and the footer's Keep My Words goes on without it.</summary>
    [Fact]
    public async Task APhraseStillTooShortAfterTheOneRoundIsNotAskedAgainAndKeepsTheRecoveryRow()
    {
        var connector = new Connector(Short + " word11 word12", (round, ordinals) => Rows(ordinals, round == 1 ? "x" : Fits));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Assert.Single(connector.FitRequests);
        Assert.Equal(1, session.WordingFitRound);
        Assert.Equal("x word11 word12", session.NewWords);
        Assert.Single(session.BlockedVoiceHunks);
        Assert.Equal("1 phrase needs wording that fits.", session.ReviewFooter);
        Assert.Null(session.FitRowNote(1));
        Assert.Equal(new RewriteFooterStep("Change 1 needs a longer wording before takes.", "Keep My Words", RewriteFooterAction.KeepMyWords), session.FooterStep);
        Assert.True(session.ReviewIsCurrent);
        Assert.True(session.PriceItAnyway(1));
        var review = PanelSource("RewritePanel.Review.cs");
        foreach (var action in new[] { "\"Ask for shorter\"", "\"Ask for longer\"", "\"Use surrounding sentence\"", "\"Keep original words\"", "\"Price it anyway\"" })
            Assert.Contains(action, review);
    }

    [Fact]
    public async Task AStructuredKeepOriginalAnswerKeepsTheRecordingAndEndsTheRounds()
    {
        var connector = new Connector(Short + " word11 word12", (_, ordinals) => new JsonArray(ordinals.Select(ordinal =>
            (JsonNode)new JsonObject { ["ordinal"] = ordinal, ["action"] = "keepOriginal", ["text"] = "" }).ToArray()));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Assert.Single(connector.FitRequests);
        Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[1]);
        Assert.Contains(1, session.WordingFitKept);
        Assert.Empty(session.PricedVoiceHunks);
        Assert.Equal("kept your original words · 1.4 s is too short to re-voice", session.FitRowNote(1));
    }

    [Fact]
    public async Task FittingPhrasesAreFrozenAndNeverSentAgain()
    {
        // Phrase 2 replaces a 0.4 s word, so no wording of it fits: the round asks for it, never for phrase 1, and it then keeps the
        // speaker's words (ADR-R42); phrase 1 is priced.
        const string longer = "a far longer and very much clearer phrasing";
        var connector = new Connector(Fits + " word11 word12 word13 word14 word15 word16 word17 " + longer,
            (_, ordinals) => Rows(ordinals, "still a much longer phrasing than it ever needed"));
        using var session = Session(connector, 10, 18);
        Assert.True(await ProposeAsync(session));
        var request = Assert.Single(connector.FitRequests);
        Assert.Contains("Phrase 2\n", request.CachedBlock);
        Assert.DoesNotContain("Phrase 1\n", request.CachedBlock);
        Assert.StartsWith(Fits + " ", session.NewWords);
        Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[2]);
        Assert.Equal([1], session.PricedVoiceHunks.SelectMany(hunk => hunk.Ordinals).ToArray());
    }

    [Fact]
    public async Task StopMidRoundKeepsTheLatestProposalAndIgnoresTheLateReply()
    {
        var connector = new Connector(Short + " word11 word12", (_, ordinals) => Rows(ordinals, Fits)) { HoldFits = true };
        using var session = Session(connector);
        var proposing = ProposeAsync(session);
        await connector.FitSent.Task;
        Assert.True(session.WordingFitRunning);
        Assert.False(session.ReviewIsCurrent);
        Assert.Equal("Fitting wording to the video · round 1 of 1", session.FitRunningHeadline);
        Assert.Equal("Phrase 1 · ≈ 0.9 s, slot 1.4 s · asking for about 1 more words", RewriteSession.FitPhraseLine(Assert.Single(session.WordingFitPhrases)));
        session.StopWordingFit();
        Assert.False(session.Editor.LlmRuns.IsBusy);
        connector.Release.SetResult();
        Assert.True(await proposing);
        await session.WordingFitWork;
        Assert.Equal(Short + " word11 word12", session.NewWords);
        Assert.True(session.WordingFitStopped);
        Assert.False(session.WordingIsLocked);
        Assert.Single(connector.FitRequests);
        Assert.True(session.ReviewIsCurrent);
    }

    [Fact]
    public async Task AUserEditCancelsTheRounds()
    {
        var connector = new Connector(Short + " word11 word12", (_, ordinals) => Rows(ordinals, Fits)) { HoldFits = true };
        using var session = Session(connector);
        var proposing = ProposeAsync(session);
        await connector.FitSent.Task;
        session.Edit("plainly put word11 word12");
        Assert.False(session.WordingIsLocked);
        connector.Release.SetResult();
        await proposing;
        await session.WordingFitWork;
        Assert.Equal("plainly put word11 word12", session.NewWords);
        Assert.Single(connector.FitRequests);
        Assert.True(session.WordingFitStopped);
    }

    [Fact]
    public async Task ABilledConnectorAsksOnceInlineAndSkipSendsNothing()
    {
        var skipped = new Connector(Short + " word11 word12", (_, ordinals) => Rows(ordinals, "x")) { Billed = true };
        using (var session = Session(skipped, group: "apiKey"))
        {
            Assert.True(await ProposeAsync(session));
            Assert.True(session.WordingFitAwaitingApproval);
            Assert.True(session.FitAsksFirst);
            Assert.Equal("Fit wording automatically · 1 request · price unavailable · billed to your key", session.FitApprovalLine);
            Assert.False(session.GenerationIsCurrent);
            session.StopWordingFit();
            Assert.True(session.WordingFitStopped);
            Assert.False(session.WordingIsLocked);
            Assert.Empty(skipped.FitRequests);
            Assert.Equal(Short + " word11 word12", session.NewWords);
        }
        var approved = new Connector(Short + " word11 word12", (_, ordinals) => Rows(ordinals, "x")) { Billed = true };
        using var fitted = Session(approved, group: "apiKey");
        Assert.True(await ProposeAsync(fitted));
        Assert.True(fitted.WordingFitAwaitingApproval);
        var approvals = 0;
        fitted.Changed += (_, _) => { if (fitted.WordingFitAwaitingApproval) approvals++; };
        await fitted.FitWordingAsync(true);
        Assert.Equal(0, approvals);
        Assert.Single(approved.FitRequests);
        Assert.Equal("Uses Stub, billed to your key. Making a take still needs your paid click.", fitted.FitNote);
    }

    [Fact]
    public async Task MeasuredRewordingPreparesAPricedTakeButNeverPaysByItself()
    {
        var connector = new Connector(Fits + " word11 word12", (_, ordinals) => Rows(ordinals, "said briefly"));
        using var session = Session(connector);
        var calibrations = new RateCalibrations(null);
        session.ConfigureRateCalibrations(calibrations);
        Assert.True(await ProposeAsync(session));
        Assert.Empty(connector.FitRequests);
        var runner = new Runner();
        session.ConfigureGenerationFactory(index => new(runner,
            _ => Task.FromResult(new RewriteGenerationChoices([new("record", "My voice")],
                [new("eleven_multilingual_v2", "Multilingual v2", ["en"], true, false, 5000, 1), new("eleven_v4", "Eleven v4", ["en"], true, false, 5000, 1)])),
            (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed, true,
                (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), ct, index),
            _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent));
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        Assert.Equal("eleven_v4", generation.ModelId);
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        await session.MeasuredWork;
        Assert.Equal(1, runner.Sends);
        var suggestion = session.MeasuredWording!;
        Assert.True(suggestion.TooLong);
        Assert.StartsWith("Take 1 · ", suggestion.Heading);
        Assert.EndsWith(" · slot 1.4 s · too long", suggestion.Heading);
        var request = Assert.Single(connector.FitRequests);
        Assert.Contains("Measured take: ", request.CachedBlock);
        Assert.Contains("Use shorter wording", request.CachedBlock);
        Assert.Contains("at v4's measured pace", request.CachedBlock);
        Assert.Contains("making a new take needs a separate paid click", request.Instruction);
        Assert.Equal("said briefly", suggestion.Text);
        Assert.Same(generation, session.MeasuredGeneration);
        Assert.Equal("said briefly", runner.Input!.Text);
        Assert.Equal(1, runner.Sends);
        Assert.Single(session.RateSamples("eleven_v4"));
        // The take also teaches its voice, across projects (ADR-R43).
        Assert.Single(calibrations.For("record")!.Samples("eleven_v4"));
        // Measured against the current prior, so saved under its key (ADR-R43); the bare model ID is the old prior's.
        Assert.Single(session.CalibratedRates()![VoiceLabRateCalibration.ProjectKey("eleven_v4")]);
        Assert.False(session.CalibratedRates()!.ContainsKey("eleven_v4"));
        // Declining can't keep a take no video duration carries (Mac measuredRewordingPreparesButNeverPaysAndDecliningKeepsTheRecording):
        // the button reads Keep Original Audio and the phrase keeps the recording with one line. Nothing more is paid for.
        Assert.True(generation.FitsNoDuration);
        Assert.Equal("Keep Original Audio", session.MeasuredKeepTitle(suggestion));
        await session.KeepMeasuredTakeAsync();
        Assert.Null(session.MeasuredWording);
        Assert.Equal(Fits, runner.Input.Text);
        Assert.True(generation.LeftOut);
        Assert.Null(generation.Selected);
        Assert.Contains(RewriteSession.NoDurationCopy([1]), session.AutoFix.Notes);
        Assert.Equal(1, runner.Sends);
    }

    [Fact]
    public async Task OnlyThePricedMakeTakeClickMakesTheRewordedTake()
    {
        var connector = new Connector(Fits + " word11 word12", (_, ordinals) => Rows(ordinals, "said briefly"));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        var runner = new Runner();
        session.ConfigureGenerationFactory(index => new(runner,
            _ => Task.FromResult(new RewriteGenerationChoices([new("record", "My voice")], [new("eleven_v4", "Eleven v4", ["en"], true, false, 5000, 1)])),
            (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed, true,
                (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), ct, index),
            _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent));
        await session.DiscoverWindowsAsync();
        var generation = session.Generation!;
        generation.MarkEstimateShown(generation.Quote!);
        await generation.GenerateAsync((_, _) => Task.FromResult(true), autoplay: false);
        await session.MeasuredWork;
        var first = generation.Selected!;
        Assert.Equal("Make Take · ≈ $0.06", generation.GenerationButtonTitle("Make Take"));
        generation.MarkEstimateShown(generation.Quote!);
        var asked = 0;
        await session.MakeMeasuredTakeAsync((_, _) => { asked++; return Task.FromResult(true); });
        Assert.Equal(2, runner.Sends);
        var second = generation.Rows.Single(row => row.Id != first.Id);
        Assert.Equal("said briefly", generation.InputFor(second.Id)!.Text);
        Assert.Equal(Fits, generation.InputFor(first.Id)!.Text);
        Assert.Equal("said briefly", generation.ReviewedInput!.Text);
        Assert.True(generation.ReviewedInputsCurrent);
    }

    [Fact]
    public void FitUiIsInlineWithKeyboardAndNarratorNames()
    {
        var source = PanelSource("RewritePanel.WordingFit.cs");
        foreach (var id in new[] { "Rewrite.FitApprove", "Rewrite.FitSkip", "Rewrite.FitStop", "Rewrite.FitProgress", "Rewrite.MeasuredMakeTake", "Rewrite.MeasuredKeep", "Rewrite.MeasuredFitApprove" })
            Assert.Contains(id, source);
        foreach (var copy in new[] { "Fitting stopped. Your latest proposal is kept.", "Reworded with the measured length: “", "session.MeasuredKeepTitle(suggestion)",
            "Make a new take with the reworded text. ", "Fitting wording, round {session.WordingFitRound} of 3", "That approval covers this reply only." })
            Assert.Contains(copy, source);
        Assert.Contains("TextWrapping = TextWrapping.Wrap", source);
        foreach (var file in new[] { "RewritePanel.WordingFit.cs", "RewritePanel.Review.cs", "RewritePanel.Takes.cs", "RewritePanel.cs" })
        {
            Assert.DoesNotContain("ContentDialog", PanelSource(file));
            Assert.DoesNotContain("Flyout", PanelSource(file));
        }
        var panel = PanelSource("RewritePanel.cs");
        Assert.Contains("words.Text != session.NewWords", panel);
        Assert.Contains("!session.WordingIsLocked", panel);
    }

    private static string PanelSource(string file) =>
        File.ReadAllText(Path.Combine(Path.GetDirectoryName(SharedResources.ResolveRoot())!, "apps/windows/src/VoxClip.App/Controls", file));

    private static async Task<bool> ProposeAsync(RewriteSession session)
    {
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        return await session.ProposeAsync(action, true);
    }

    /// <summary>Mac <c>aNewProjectsEstimateUsesTheStoredVoiceCalibration</c> at the session: a new project's phrase starts from its voice's
    /// stored calibration, written by an earlier project's takes, and its word budget aims at that voice's p80 (ADR-R43).</summary>
    [Fact]
    public async Task ANewProjectsPhraseStartsFromItsVoicesStoredCalibration()
    {
        var ct = TestContext.Current.CancellationToken;
        var root = Path.Combine(Path.GetTempPath(), "voxclip-rate-session-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new VoxClip.Core.Services.VoiceLab.VoiceLabRateCalibrationStore(root);
            foreach (var (ratio, index) in new[] { 1.3, 1.25, 1.35, 1.28, 1.32 }.Select((ratio, index) => (ratio, index)))
                await store.RecordAsync("record", "eleven_v4", "take" + index, ratio * 2, 2, ct);
            using var plain = new RewriteSession(Editor(), 10, 12, Envelope(), null);
            plain.Edit(Fits + " word11 word12");
            var uncalibrated = plain.Review!.VoiceHunks[0].Fit!.EstimateSeconds;
            Assert.Equal(1, VoiceLabWordingFit.Multiplier(plain.RateSamples("eleven_v4")));

            var calibrations = new RateCalibrations(store);
            await calibrations.LoadAsync(ct);
            using var session = new RewriteSession(Editor(), 10, 12, Envelope(), null);
            session.ConfigureRateCalibrations(calibrations);
            session.Edit(Fits + " word11 word12");
            Assert.Equal(1.3, VoiceLabWordingFit.Multiplier(session.RateSamples("eleven_v4")), 12);
            Assert.Equal(uncalibrated * 1.3, session.Review!.VoiceHunks[0].Fit!.EstimateSeconds, 9);
            Assert.InRange(session.RateSpread("eleven_v4"), VoiceLabRateCalibration.MinimumSpread, VoiceLabRateCalibration.MaximumSpread);
            // A measured take is kept in memory now and written in the background.
            calibrations.Record("record", "eleven_v4", "take9", 2.6, 2);
            await calibrations.Writes;
            Assert.Equal(6, (await store.LoadAsync("record", ct)).Samples("eleven_v4").Count);
            // The project itself saved nothing: its own samples come only from its own takes.
            Assert.Null(session.CalibratedRates());
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static JsonArray Rows(IReadOnlyList<int> ordinals, string text) =>
        new(ordinals.Select(ordinal => (JsonNode)new JsonObject { ["ordinal"] = ordinal, ["action"] = "reword", ["text"] = text }).ToArray());

    private static RewriteSession Session(Connector connector, int first = 10, int last = 12, string group = "local") =>
        new(Editor(), first, last, Envelope(), new(connector, "chosen", "Stub", group, ""), consent: _ => Task.FromResult(true));

    private static EditorViewModel Editor()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
        // Every take carries the provider's onset (ADR-R43), so a one-word change is too short only for a long word: word10 lasts 1.2 s.
        var words = Enumerable.Range(0, 80).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word, index == 10 ? 10.6 : index + 1,
            index == 10 ? 11.8 : index + 1.4, null, null, 1, null, TimingSource.Native)).ToArray();
        project = project with { Transcript = project.Transcript! with { Words = words },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } };
        return new(project, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
    }
    private static AudioEnvelope Envelope() => new(48000, 0.01, Enumerable.Repeat(0.01f, 10000).ToArray());

    /// <summary>A stub LLM: the Rewrite reply, then one scripted fit reply per round. No network.</summary>
    private sealed class Connector(string rewrite, Func<int, IReadOnlyList<int>, JsonArray> fit) : ILlmConnector
    {
        internal List<LlmRequest> FitRequests { get; } = [];
        internal bool HoldFits { get; init; }
        internal bool Billed { get; init; }
        internal TaskCompletionSource FitSent { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public ConnectorId Id => Billed ? ConnectorId.OpenAI : ConnectorId.Ollama;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(32768);
        public async Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            if (request.Tag != "voice-rewrite-fit")
                return new(null, new JsonObject { ["rewrite"] = rewrite }, model, new StopKind.Complete(), null, "fake");
            FitRequests.Add(request);
            var ordinals = System.Text.RegularExpressions.Regex.Matches(request.CachedBlock!, @"(?m)^Phrase (\d+)$").Select(match => int.Parse(match.Groups[1].Value)).ToArray();
            var rows = fit(FitRequests.Count, ordinals);
            FitSent.TrySetResult();
            if (HoldFits) await Release.Task;
            return new(null, new JsonObject { ["phrases"] = rows }, model, new StopKind.Complete(), null, "fake");
        }
    }

    /// <summary>A take runner whose every take runs 5.8 s, far longer than its slot.</summary>
    private sealed class Runner : IVoiceLabTakeRunner
    {
        internal VoiceLabTakeInput? Input;
        internal int Sends;
        private VoiceLabTakeRunQuote? pending;
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
        {
            Input = input;
            VoiceLabPreparedAction Action(VoiceLabOperation operation) => (VoiceLabPreparedAction)typeof(VoiceLabPreparedAction)
                .GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single(constructor => constructor.GetParameters().Length == 5)
                .Invoke([Guid.NewGuid(), "fixture", DateTimeOffset.UtcNow.AddHours(1),
                    new VoiceLabEstimate("elevenlabs", operation, 1, "fixture", .01m, null, "fixture"),
                    new VoiceLabReview(operation, Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, "fixture", input.ModelId,
                        "voice", null, null, input.RecordId, Pace: input.Pace)]);
            pending = new(Guid.NewGuid(), Enumerable.Range(0, 3).Select(index => new VoiceLabTakeQuote(index, (uint)index,
                Action(VoiceLabOperation.TextToSpeech), Action(VoiceLabOperation.SpeechToText))).ToArray());
            return Task.FromResult(pending);
        }
        public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default) => throw new InvalidOperationException();
        public async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
        {
            await dispatch.AuthorizeAsync(quote.Takes[0].Synthesis.Review.RequestId, ct);
            await dispatch.Start(() => Task.FromResult(true), ct);
            Sends++;
            var input = Input!;
            if (progress is not null) await progress([]);
            var trimmed = new float[278_400];
            var fit = VoiceLabRewriteFit.Hypothetical(input.Window, input.IncomingSilence, input.OutgoingSilence, 5.8, 48_000, hardJoinSmoothing: false);
            var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", input.ModelId, "voice",
                quote.Takes[0].Synthesis.Review.RequestId, null, null, input.Pace);
            var row = new VoiceLabTakeRow(receipt.ActionId, 0, 42, receipt, Quote: quote.Takes[0],
                Audio: new(48_000, trimmed, [], 0, trimmed.Length, [], 0, null, fit), Qa: new(1, 0, -3, .8, []), Score: 1);
            if (progress is not null) await progress([row]);
            return new([row], VoiceLabTakeRunEnd.Completed);
        }
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => ReferenceEquals(quote, pending);
        public Task DiscardPendingAsync() { pending = null; return Task.CompletedTask; }
        public void InvalidatePreparation() => pending = null;
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => Task.FromResult(cap);
    }
}
#endif
