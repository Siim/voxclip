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

/// <summary>The automatic resolver on Windows (voice-lab.md §8.2.2, Mac RewriteAutoFix): Get Price arms it; each stuck phrase gets
/// at most three rounds within max($0.10, quote); [Keep fixing · ≈ $y] past the cap; one Stop; paid takes are never replaced;
/// the last round keeps the original words with Undo. Stub connectors and runners only.</summary>
public sealed class RewriteAutoFixTests
{
    internal const string Reply = "a much clearer phrasing word11 word12";
    internal static readonly VoiceLabTakeQaResult Passed = new(1, 0, -3, .8, []);
    internal static readonly VoiceLabTakeQaResult WordsFailed = new(.4, 0, -3, .8, [VoiceLabTakeQaFailure.Transcript]);

    [Fact]
    public async Task ATakeTooLongIsRewordedFromItsMeasuredLengthAndRetakenBesideTheFirstTake()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "said briefly"));
        var runner = new Runner((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        Assert.True(session.AutoFix.Armed);
        Assert.Equal(2, runner.Sends);
        Assert.Equal(1, session.AutoFix.Rounds[0]);
        Assert.Equal(.06m, session.AutoFix.Spent);
        Assert.Equal(.10m, session.AutoFix.Allowance);
        Assert.Equal(2, window.Rows.Count);
        Assert.Equal(["Take 1", "Take 2"], window.Rows.Select(row => row.DisplayName));
        Assert.Equal(window.Rows[1].Id, window.SelectedTakeId);
        Assert.Equal("said briefly", window.InputFor(window.Rows[1].Id)!.Text);
        Assert.Equal(Reply.Split(' ')[0] + " much clearer phrasing", window.InputFor(window.Rows[0].Id)!.Text);
        Assert.Null(session.StuckReason(0));
        Assert.Single(connector.FitRequests);
        Assert.Equal(Reply, session.NewWords);
    }

    [Fact]
    public async Task SpendIsCappedAtTheAllowanceAndKeepFixingRaisesItThenTheLastRoundKeepsTheOriginalWords()
    {
        // Each round's wording is new and shorter: the fix loop never voices a repeat (voice-lab.md §8.2.2).
        var connector = new Connector(Reply, (request, ordinals) => Rows(ordinals, request switch { 1 => "said briefly", 2 => "so brief", _ => "brief" }));
        var runner = new Runner((_, _) => (5.8, Passed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        Assert.Equal(2, runner.Sends);
        Assert.NotNull(session.AutoFix.Capped);
        Assert.True(session.AutoFix.Capped!.Take);
        Assert.False(session.AutoFix.Running);
        Assert.True(session.AutoFix.ChoicesShown);
        Assert.Equal("Keep fixing · ≈ $0.06", session.KeepFixingTitle);
        Assert.Equal("Automatic fixes spent $0.06 of $0.10. The next fix waits for you.", session.AutoFixCapLine);
        Assert.Equal(1, session.AutoFix.Rounds[0]);
        session.KeepFixing();
        await SettleAsync(session);
        Assert.Equal(3, runner.Sends);
        Assert.Equal(.16m, session.AutoFix.Allowance);
        Assert.NotNull(session.AutoFix.Capped);
        session.KeepFixing();
        await SettleAsync(session);
        Assert.Equal(4, runner.Sends);
        Assert.Equal(3, session.AutoFix.Rounds[0]);
        Assert.Null(session.AutoFix.Capped);
        var window = session.Generation!;
        Assert.True(window.LeftOut);
        Assert.Contains(0, session.AutoFix.GaveUp);
        Assert.Equal(4, window.Rows.Count);
        Assert.Null(window.SelectedTakeId);
        Assert.Equal("Phrase 1 kept your original audio after 3 tries.", session.AutoFix.Announcement);
        Assert.Null(session.PendingPaidReviewChange);
        Assert.True(session.UndoKeepOriginal(0));
        Assert.False(window.LeftOut);
        Assert.NotNull(window.SelectedTakeId);
        Assert.Equal(4, window.Rows.Count);
        Assert.Equal(4, runner.Sends);
    }

    [Fact]
    public async Task AFailedWordCheckTriesAnotherTakeThenAsksForEasierWordsForThatPhraseAlone()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x")) { Reask = "plainly said word11 word12" };
        var runner = new Runner((_, _) => (Fit, WordsFailed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        Assert.Equal(2, runner.Sends);
        Assert.Contains(0, session.AutoFix.TriedAnother);
        var reask = Assert.Single(connector.Reasks);
        Assert.Contains("REQUESTED FIX", reask.Instruction);
        Assert.Contains(RewriteSession.ClearerInstruction, reask.Instruction);
        Assert.Contains("Phrase 1: its take failed the voice checks", reask.Instruction);
        Assert.Equal(Reply, session.NewWords);
        Assert.NotNull(session.AutoFix.Capped);
        Assert.Equal("plainly said", runner.Input!.Text);
        Assert.Equal(2, session.Generation!.Rows.Count);
    }

    [Fact]
    public async Task StopEndsTheFixesKeepsEveryTakeAndIgnoresTheLateReply()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "said briefly")) { HoldFits = true };
        var runner = new Runner((run, _) => run == 1 ? (5.8, Passed) : (Fit, Passed));
        using var session = await PricedAsync(connector, runner);
        await connector.FitSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.True(session.AutoFix.Running);
        Assert.Equal("Fixing phrase 1: asking Stub for a shorter wording…", Assert.Single(session.AutoFix.Lines).Value);
        session.StopAutoFix();
        Assert.False(session.AutoFix.Running);
        Assert.True(session.AutoFix.ChoicesShown);
        Assert.Empty(session.AutoFix.Lines);
        connector.Release.SetResult();
        await session.MeasuredWork;
        await SettleAsync(session);
        Assert.Equal(1, runner.Sends);
        Assert.Single(session.Generation!.Rows);
    }

    [Fact]
    public async Task KeepOriginalWordsWithPaidTakesKeepsThemAndUndoUsesTheBestTakeAgain()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = await PricedAsync(connector, runner);
        await SettleAsync(session);
        var window = session.Generation!;
        var take = window.SelectedTakeId;
        Assert.NotNull(take);
        Assert.True(session.KeepOriginal(0));
        Assert.Null(session.PendingPaidReviewChange);
        Assert.True(window.LeftOut);
        Assert.Single(window.Rows);
        Assert.Equal([0], session.LeftOutPhrases);
        Assert.True(session.UndoKeepOriginal(0));
        Assert.Equal(take, window.SelectedTakeId);
    }

    /// <summary>Mac <c>anOverBudgetLineIsRepairedOnceThenKeptAsRecorded</c> (ADR-R42): one free fit round, then a change still longer than its
    /// slot keeps the speaker's words, with one line, and nothing is priced that can't fit. After Stop it waits, and the footer's Keep My
    /// Words settles it: never a footer without a step forward.</summary>
    [Fact]
    public async Task AnOverBudgetLineIsRepairedOnceThenKeptAsRecorded()
    {
        const string Long = "a much much longer phrasing than this little slot could ever hold in its time";
        var connector = new Connector(Long + " word11 word12", (_, ordinals) => Rows(ordinals, Long));
        using (var session = Session(connector))
        {
            Assert.True(await ProposeAsync(session));
            Assert.Single(connector.FitRequests);
            Assert.Empty(session.BlockedVoiceHunks);
            Assert.Empty(session.PricedVoiceHunks);
            Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[1]);
            Assert.StartsWith("kept your original words · the new wording is longer than its ", session.FitRowNote(1));
            Assert.EndsWith(" s in the video", session.FitRowNote(1));
            Assert.Contains("Change 1 keeps your original words: still longer than its time in the video after a fit.", session.AutoFix.Notes);
            Assert.Equal(RewriteFooterAction.Done, session.FooterStep.Action);
        }
        var held = new Connector(Long + " word11 word12", (_, ordinals) => Rows(ordinals, Long)) { HoldFits = true };
        using var stopped = Session(held);
        var proposing = ProposeAsync(stopped);
        await held.FitSent.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        stopped.StopWordingFit();
        held.Release.SetResult();
        await proposing;
        await stopped.WordingFitWork;
        Assert.Single(stopped.BlockedVoiceHunks);
        Assert.Empty(stopped.PricedVoiceHunks);
        Assert.Equal(new RewriteFooterStep("Change 1 needs a shorter wording before takes.", "Keep My Words", RewriteFooterAction.KeepMyWords), stopped.FooterStep);
        Assert.True(stopped.KeepMyWords());
        Assert.Empty(stopped.BlockedVoiceHunks);
        Assert.Equal(TranscriptChangeState.Excluded, stopped.ChangeStates[1]);
        Assert.Equal(RewriteFooterAction.Done, stopped.FooterStep.Action);
    }

    /// <summary>Mac <c>aWordingFitThatCannotStartKeepsTheWordsAndGoesOn</c>: a fit that fails shows its problem and keeps the long change as
    /// recorded, so Rewrite goes on; nothing offers the same request again.</summary>
    [Fact]
    public async Task AWordingFitThatFailsKeepsTheWordsAndGoesOn()
    {
        const string Long = "a much much longer phrasing than this little slot could ever hold in its time";
        var connector = new Connector(Long + " word11 word12", (_, _) => throw new HttpRequestException("The stub connector could not be reached."));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        await session.WordingFitWork;
        Assert.Single(connector.FitRequests);
        Assert.NotEqual("", session.WordingFitProblem);
        Assert.True(session.WordingFitCompleted);
        Assert.Empty(session.BlockedVoiceHunks);
        Assert.Equal(TranscriptChangeState.Excluded, session.ChangeStates[1]);
        Assert.NotEqual(RewriteFooterAction.None, session.FooterStep.Action);
    }

    [Fact]
    public async Task TheApprovedPriceShowsTheAutomaticAllowanceUnderIt()
    {
        var connector = new Connector(Reply, (_, ordinals) => Rows(ordinals, "x"));
        var runner = new Runner((_, _) => (Fit, Passed));
        using var session = Session(connector);
        Assert.True(await ProposeAsync(session));
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        Assert.Equal("Automatic fixes may spend up to $0.10 more.", session.AutoFixAllowanceLine);
        Assert.False(session.AutoFix.Armed);
    }

    internal const double Fit = 0;

    internal static async Task SettleAsync(RewriteSession session)
    {
        for (var step = 0; step < 64 && (session.AutoFix.Work is { } work); step++) await work;
        Assert.Null(session.AutoFix.Work);
    }

    internal static async Task<RewriteSession> PricedAsync(Connector connector, Runner runner, Func<Connector, RewriteSession>? create = null)
    {
        var session = (create ?? (value => Session(value)))(connector);
        Assert.True(await ProposeAsync(session));
        Configure(session, runner);
        await session.DiscoverWindowsAsync();
        var batch = session.PreparedBatch!;
        session.MarkBatchEstimateShown(batch);
        Assert.True(session.CanGenerateAll);
        _ = session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult<VoiceLabMonthlyCap?>(null));
        return session;
    }

    internal static void Configure(RewriteSession session, Runner runner) =>
        session.ConfigureGenerationFactory(index => new(runner,
            _ => Task.FromResult(new RewriteGenerationChoices([new("record", "My voice")], [new("eleven_v4", "Eleven v4", ["en"], true, false, 5000, 1)])),
            (voice, model, seed, ct) => session.GenerationInputAsync(voice, model, seed, true,
                (request, _) => Task.FromResult((new VoiceLabSourceExcerpt(request.Frames, []), session.Envelope!)), ct, index),
            _ => Task.FromResult(true), _ => Task.FromResult<decimal?>(null), () => session.GenerationIsCurrent));

    internal static async Task<bool> ProposeAsync(RewriteSession session)
    {
        await session.SetInstructionAsync("Plainly");
        var action = session.Prepared!;
        session.MarkEstimateShown(action);
        return await session.ProposeAsync(action, true);
    }

    internal static JsonArray Rows(IReadOnlyList<int> ordinals, string text) =>
        new(ordinals.Select(ordinal => (JsonNode)new JsonObject { ["ordinal"] = ordinal, ["action"] = "reword", ["text"] = text }).ToArray());

    internal static RewriteSession Session(Connector connector, int first = 10, int last = 12, string group = "local", EditorViewModel? editor = null) =>
        new(editor ?? Editor(), first, last, Envelope(), new(connector, "chosen", "Stub", group, ""), consent: _ => Task.FromResult(true));

    internal static EditorViewModel Editor()
    {
        var project = ProjectSerialization.Deserialize(File.ReadAllText(Path.Combine(SharedResources.ResolveRoot(), "fixtures", "projects", "interview-take.voxclip")));
        var words = Enumerable.Range(0, 80).Select(index => new TimedWord("w" + index, "word" + index, WordKind.Word, index + 1, index + 1.4,
            null, null, 1, null, TimingSource.Native)).ToArray();
        project = project with { Transcript = project.Transcript! with { Words = words },
            Media = project.Media with { Source = project.Media.Source with { DurationSeconds = 100, Audio = new(48000, 1) } },
            Edits = project.Edits with { CutWordIds = [], CutPauseIds = [], Corrections = new Dictionary<string, string>(), Clips = [], ActiveClipId = null } };
        return new(project, now: () => new DateTimeOffset(2026, 11, 4, 0, 0, 0, TimeSpan.Zero));
    }
    internal static AudioEnvelope Envelope() => new(48000, 0.01, Enumerable.Repeat(0.01f, 10000).ToArray());

    /// <summary>A stub LLM: the Rewrite reply, scripted fit replies, and a scripted reply to a scoped re-ask. No network.</summary>
    internal sealed class Connector(string rewrite, Func<int, IReadOnlyList<int>, JsonArray> fit) : ILlmConnector
    {
        internal List<LlmRequest> FitRequests { get; } = [];
        internal List<LlmRequest> Reasks { get; } = [];
        /// <summary>The Rewrite requests sent (not fits or re-asks).</summary>
        internal List<LlmRequest> Rewrites { get; } = [];
        internal string? Reask { get; init; }
        /// <summary>The first this-many Rewrite sends fail, as a connector error would.</summary>
        internal int FailRewrites { get; set; }
        internal JsonArray? NextActions { get; set; }
        internal bool HoldFits { get; init; }
        internal bool HoldReasks { get; init; }
        internal TaskCompletionSource FitSent { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource ReaskSent { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource ReaskRelease { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public ConnectorId Id => ConnectorId.Ollama;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) =>
            Task.FromResult<IReadOnlyList<LlmModel>>([new("chosen", "Chosen", null, 32768, ModelSource.Discovered)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(32768);
        public async Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            if (request.Tag != "voice-rewrite-fit")
            {
                var reasked = request.Instruction.Contains("REQUESTED FIX", StringComparison.Ordinal);
                if (!reasked && FailRewrites > 0) { FailRewrites--; throw new HttpRequestException("The stub connector could not be reached."); }
                if (reasked)
                {
                    Reasks.Add(request);
                    ReaskSent.TrySetResult();
                    if (HoldReasks) await ReaskRelease.Task.WaitAsync(ct);
                }
                else Rewrites.Add(request);
                var reply = new JsonObject { ["rewrite"] = reasked ? Reask ?? rewrite : rewrite };
                if (NextActions is { } next) reply["nextActions"] = next.DeepClone();
                return new(null, reply, model, new StopKind.Complete(), null, "fake");
            }
            FitRequests.Add(request);
            var ordinals = System.Text.RegularExpressions.Regex.Matches(request.CachedBlock!, @"(?m)^Phrase (\d+)$").Select(match => int.Parse(match.Groups[1].Value)).ToArray();
            var rows = fit(FitRequests.Count, ordinals);
            FitSent.TrySetResult();
            if (HoldFits) await Release.Task;
            return new(null, new JsonObject { ["phrases"] = rows }, model, new StopKind.Complete(), null, "fake");
        }
    }

    /// <summary>A take runner with one take per run: <c>script(run, input)</c> gives its length (0: exactly its slot) and checks.
    /// Each take costs $0.06 as quoted (three TTS + three STT actions at $0.01).</summary>
    internal sealed class Runner(Func<int, VoiceLabTakeInput, (double Seconds, VoiceLabTakeQaResult Qa)> script) : IVoiceLabTakeRunner
    {
        internal VoiceLabTakeInput? Input;
        internal int Sends;
        /// <summary>The take's voice score by run; passing takes score 1 and failed ones 0.2 without it.</summary>
        internal Func<int, double>? Score { get; init; }
        /// <summary>The take's voice check by run (ADR-R37); null: checked on its own speech. Waiting and unmeasured takes carry no score.</summary>
        internal Func<int, VoiceLabTakeVoiceCheck>? Voice { get; init; }
        /// <summary>Holds each run after its take arrives until released, so a test can act while takes are being made.</summary>
        internal TaskCompletionSource? Hold { get; init; }
        /// <summary>A run's failure by run: the row's exception and whether the run ends fatally; null makes the scripted take.</summary>
        internal Func<int, VoiceLabTakeInput, (Exception Error, bool Fatal)?>? Fails { get; init; }
        internal TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        /// <summary>The use-time guard's refusal by execution (ADR-R40): the run ends <see cref="VoiceLabTakeRunEnd.Blocked"/> before
        /// anything is sent; null runs as scripted.</summary>
        internal Func<int, Exception?>? Blocks { get; init; }
        internal int Executions;
        /// <summary>The guard's free screen at Get Price (ADR-R41) by inputs; null leaves every phrase unchecked, as the production runner
        /// does behind the closed parity gate. A held screen waits for <see cref="ScreenHold"/>.</summary>
        internal Func<IReadOnlyList<VoiceLabTakeInput>, IReadOnlyList<VoxClip.Core.Services.VoiceLab.VoiceGuardVerdict>>? Screen { get; init; }
        internal TaskCompletionSource? ScreenHold { get; init; }
        internal int Screens;
        public async Task<IReadOnlyList<VoxClip.Core.Services.VoiceLab.VoiceGuardVerdict>> ScreenGuardAsync(IReadOnlyList<VoiceLabTakeInput> inputs, CancellationToken ct = default)
        {
            Screens++;
            if (ScreenHold is { } hold) await hold.Task.WaitAsync(ct);
            return Screen?.Invoke(inputs) ?? inputs.Select(_ => VoxClip.Core.Services.VoiceLab.VoiceGuardVerdict.Unchecked).ToArray();
        }
        /// <summary>How many quotes were prepared; a long run's later part is quoted again just before it runs.</summary>
        internal int Prepares;
        /// <summary>Each quoted action's price by prepare; null: $0.01.</summary>
        internal Func<int, decimal>? Price { get; init; }
        private VoiceLabTakeRunQuote? pending;
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
        {
            Input = input;
            Prepares++;
            var price = Price?.Invoke(Prepares) ?? .01m;
            VoiceLabPreparedAction Action(VoiceLabOperation operation) => (VoiceLabPreparedAction)typeof(VoiceLabPreparedAction)
                .GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single(constructor => constructor.GetParameters().Length == 5)
                .Invoke([Guid.NewGuid(), "fixture", DateTimeOffset.UtcNow.AddHours(1),
                    new VoiceLabEstimate("elevenlabs", operation, 1, "fixture", price, null, "fixture"),
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
            Executions++;
            if (Blocks?.Invoke(Executions) is { } refused) return new([], VoiceLabTakeRunEnd.Blocked) { Failure = refused };
            await dispatch.AuthorizeAsync(quote.Takes[0].Synthesis.Review.RequestId, ct);
            await dispatch.Start(() => Task.FromResult(true), ct);
            Sends++;
            var input = Input!;
            if (progress is not null) await progress([]);
            if (Fails?.Invoke(Sends, input) is { } failure)
            {
                // A take the provider refused, or one whose word timing couldn't be read: no audio, the row's failure, and a
                // fatal end for an account failure.
                var failed = new VoiceLabTakeRow(Guid.NewGuid(), 0, 42, Quote: quote.Takes[0], Failure: failure.Error);
                if (progress is not null) await progress([failed]);
                return new([failed], failure.Fatal ? VoiceLabTakeRunEnd.Fatal : VoiceLabTakeRunEnd.Completed);
            }
            var (seconds, qa) = script(Sends, input);
            if (seconds <= 0) seconds = input.Window.End - input.Window.Start;
            var frames = (int)Math.Round(seconds * 48_000);
            var trimmed = new float[frames];
            var fit = VoiceLabRewriteFit.Hypothetical(input.Window, input.IncomingSilence, input.OutgoingSilence, seconds, 48_000, hardJoinSmoothing: false);
            var receipt = new VoiceLabReceipt("elevenlabs", ElevenLabsRegion.Default, "fixture", input.ModelId, "voice",
                quote.Takes[0].Synthesis.Review.RequestId, null, null, input.Pace);
            var check = Voice?.Invoke(Sends) ?? VoiceLabTakeVoiceCheck.PerTake;
            if (check is not VoiceLabTakeVoiceCheck.PerTakeCheck)
                qa = qa with { SpeakerScore = Score?.Invoke(Sends), SpeakerUnmeasured = check.Evidence?.Mode == VoiceLabShortSpeechMode.Unmeasured };
            var row = new VoiceLabTakeRow(receipt.ActionId, 0, 42, receipt, Quote: quote.Takes[0],
                Audio: new(48_000, trimmed, [], 0, trimmed.Length, [], 0, null, fit), Qa: qa, Score: Score?.Invoke(Sends) ?? (qa.Verdict == VoiceLabTakeQaVerdict.Failed ? .2 : 1))
                { VoiceCheck = check };
            if (progress is not null) await progress([row]);
            Started.TrySetResult();
            if (Hold is { } hold) await hold.Task.WaitAsync(ct);
            return new([row], VoiceLabTakeRunEnd.Completed);
        }
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => ReferenceEquals(quote, pending);
        public Task DiscardPendingAsync() { pending = null; return Task.CompletedTask; }
        public void InvalidatePreparation() => pending = null;
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => Task.FromResult(cap);
    }
}
#endif
