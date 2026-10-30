using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabGenerationSessionTests
{
    [Fact]
    public async Task CancellationDuringTheLiveCostReadCannotLaunchAndKeepsTheQuote()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        var quote = await session.UpdateInputsAsync(Input(), ct: Token);
        var method = typeof(VoiceLabGenerationSession).GetMethod("CancelAsync", Type.EmptyTypes);
        Assert.NotNull(method);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        runner.Refresh = async (cap, _) => { entered.SetResult(); await resume.Task; return cap; };
        var execution = session.ContinueAsync(Token);
        await entered.Task.WaitAsync(Token);
        var cleanup = method.CreateDelegate<Func<Task>>(session)();
        Assert.False(cleanup.IsCompleted);
        resume.SetResult();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => execution);
        await cleanup;
        Assert.Same(quote, session.PendingQuote); Assert.NotNull(session.Cost);
        Assert.Equal(0, runner.Sends);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ClickRechecksRealLedgerAgainstTheExactWholeRunQuote(bool approveDirectly)
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-c7-cap-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var ledger = new VoiceLabSpendLedger(Path.Combine(directory, "spend.json"), TimeZoneInfo.Utc);
            using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), new NoTransport(), ElevenLabsRegion.Default,
                clock: new Clock(), spend: ledger);
            var runner = new Runner { Price = 0.04m, Refresh = client.RefreshMonthlyCapAsync };
            var session = new VoiceLabGenerationSession(runner);
            await ledger.RecordAsync(new("elevenlabs", "fixture", 1, "call", 0.05m, null, "fixture"), DateTimeOffset.UnixEpoch, Token);
            var quote = await session.UpdateInputsAsync(Input(), new(0.10m, 0), Token);
            Assert.Equal(VoiceLabCostPresentationKind.Inline, session.Cost!.Kind);
            await ledger.RecordAsync(new("elevenlabs", "fixture", 1, "call", 0.03m, null, "fixture"), DateTimeOffset.UnixEpoch, Token);
            if (approveDirectly) Assert.Null(await session.ApproveAsync(quote, true, Token));
            else Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.ContinueAsync(Token));
            Assert.Equal(0, runner.Sends);
            Assert.Same(quote, session.PendingQuote);
            Assert.Contains("$0.10 limit", session.Cost!.Text);
        }
        finally { Directory.Delete(directory, true); }
    }
    [Fact]
    public async Task ConfiguredCapRefusesAnUnreadableRealLedger()
    {
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-c7-cap-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var ledger = new VoiceLabSpendLedger(Path.Combine(directory, "spend.json"), TimeZoneInfo.Utc);
            using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), new NoTransport(), ElevenLabsRegion.Default,
                clock: new Clock(), spend: ledger);
            var runner = new Runner { Price = 0.04m, Refresh = client.RefreshMonthlyCapAsync };
            var session = new VoiceLabGenerationSession(runner);
            await session.UpdateInputsAsync(Input(), new(0.10m, 0), Token);
            File.WriteAllText(ledger.FilePath, "not json");
            await Assert.ThrowsAsync<VoiceLabException>(() => session.ContinueAsync(Token));
            Assert.Equal(0, runner.Sends);
        }
        finally { Directory.Delete(directory, true); }
    }
    private sealed class NoTransport : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            throw new InvalidOperationException("Cap-only regression must not dispatch.");
    }
    [Fact]
    public async Task DecliningKeepsQuotePriceAndPriorTakesForTheNextConfirmation()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        await session.UpdateInputsAsync(Input(), ct: Token);
        await session.ContinueAsync(Token);
        var previous = session.Rows;
        session.SelectTake(previous[0].Id); session.AuditionTake(previous[1].Id);
        runner.Price = 0.60m;
        var quote = await session.UpdateInputsAsync(Input(), ct: Token);
        var cost = session.Cost;
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.ContinueAsync(Token));
        await session.ApproveAsync(quote, false, Token);
        Assert.Same(quote, session.PendingQuote);
        Assert.Equal(cost, session.Cost);
        Assert.Same(previous, session.Rows);
        Assert.Equal(previous[0].Id, session.SelectedTakeId);
        Assert.Equal(previous[1].Id, session.AuditionedTakeId);
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.ContinueAsync(Token));
        Assert.Equal(3, runner.Sends);
    }
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static VoiceLabTakeInput Input() => new("Hello", "eleven_v3", "record", "en", 1, "source", [0.1f], 24000, [], new HashSet<string>(),
        new("first", "last", [], [], 0, 1, 0, 24000, new(VoiceLabSeamKind.Hard, 0, 0, 0), new(VoiceLabSeamKind.Hard, 1, 24000, 0)), null, null, false, true);
    private sealed class Runner : IVoiceLabTakeRunner
    {
        internal decimal? Price = 0.06m;
        internal decimal? RefreshedSpent;
        internal int Sends;
        internal VoiceLabTakeInput? Input;
        internal VoiceLabTakeRunQuote? Pending;
        internal bool FailBeforeStart;
        internal bool FailPreparation;
        internal Action? Prepared;
        internal Action? Started;
        internal Func<VoiceLabMonthlyCap?, CancellationToken, Task<VoiceLabMonthlyCap?>>? Refresh;
        internal TaskCompletionSource? Resume;
        internal TaskCompletionSource? ResumePreparation;
        internal TaskCompletionSource? PreparationEntered;
        internal readonly Clock Clock = new();
        private VoiceLabActionGate? gate;
        internal readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            if (FailPreparation) throw new VoiceLabException(VoiceLabErrorKind.MissingKey);
            Input = input;
            var actions = new VoiceLabActionGate(Clock);
            gate = actions;
            var actionIndex = 0;
            VoiceLabPreparedAction Action(VoiceLabOperation operation) => actions.Prepare(Guid.NewGuid().ToString(),
                new("elevenlabs", operation, 1, "call", Price is null ? null : actionIndex++ == 0 ? Price : 0, null, "fixture"),
                new(operation, Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, "/fixture", null, null, null, null, "record"));
            Pending = new(Guid.NewGuid(), Enumerable.Range(0, 3).Select(index => new VoiceLabTakeQuote(index, (uint)index,
                Action(VoiceLabOperation.TextToSpeech), Action(VoiceLabOperation.SpeechToText))).ToArray());
            var result = Pending;
            Prepared?.Invoke();
            PreparationEntered?.TrySetResult();
            if (ResumePreparation is { } resume) await resume.Task;
            return result;
        }
        public async Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
        {
            Assert.True(approved); Assert.Same(Pending, quote); Pending = null;
            ct.ThrowIfCancellationRequested();
            if (FailBeforeStart) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            if (progress is not null) await progress([]);
            Started?.Invoke();
            Entered.TrySetResult();
            if (Resume is not null) await Resume.Task.WaitAsync(ct);
            Sends += quote.Takes.Count;
            return new(quote.Takes.Select(take => new VoiceLabTakeRow(Guid.NewGuid(), take.Index, take.Seed)).ToArray(), VoiceLabTakeRunEnd.Completed);
        }
        public async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
        {
            if (FailBeforeStart) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            await dispatch.AuthorizeAsync(ct);
            return await dispatch.Start(() => ExecuteAsync(quote, true, progress, ct), ct);
        }
        public Task DiscardPendingAsync() { Pending = null; return Task.CompletedTask; }
        public void InvalidatePreparation() => Pending = null;
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => ReferenceEquals(Pending, quote) && gate!.QuotesAreFresh(quote.Actions);
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) =>
            Refresh is { } refresh ? refresh(cap, ct) : Task.FromResult(cap is null ? null : cap with { Spent = RefreshedSpent ?? cap.Spent });
    }
    private sealed class Clock : TimeProvider
    {
        internal long Elapsed;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => Elapsed;
        public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch;
    }

    [Fact]
    public async Task InputChangesAutomaticallyRequoteAndInvalidateOldApprovalsWithoutRetiringTakes()
    {
        var runner = new Runner { Price = 0.6m };
        var session = new VoiceLabGenerationSession(runner);
        var input = Input();
        await session.UpdateInputsAsync(input, ct: Token);
        await session.ApproveAsync(session.PendingQuote!, true, Token);
        var rows = session.Rows;
        session.SelectTake(rows[0].Id); session.AuditionTake(rows[1].Id);
        VoiceLabTakeInput[] changes = [input with { Text = "Changed" }, input with { ModelId = "eleven_multilingual_v2" },
            input with { RecordId = "different-voice-and-consent" }];
        foreach (var changed in changes)
        {
            var old = session.PendingQuote!;
            Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.TryAnotherAsync(Token));
            await session.UpdateInputsAsync(changed, ct: Token);
            Assert.NotEqual(old.Id, session.PendingQuote!.Id);
            Assert.NotNull(session.Cost);
            await Assert.ThrowsAsync<VoiceLabException>(() => session.ApproveAsync(old, true, Token));
            Assert.Same(rows, session.Rows);
            Assert.Equal(rows[0].Id, session.SelectedTakeId); Assert.Equal(rows[1].Id, session.AuditionedTakeId);
            Assert.Equal(3, runner.Sends);
        }
        await session.ApproveAsync(session.PendingQuote!, false, Token);
        Assert.Same(rows, session.Rows);
        Assert.Equal(rows[0].Id, session.SelectedTakeId); Assert.Equal(rows[1].Id, session.AuditionedTakeId);
        await Assert.ThrowsAsync<VoiceLabException>(() => session.UpdateInputsAsync(input with { ProviderConsent = false }, ct: Token));
        Assert.Null(session.PendingQuote); Assert.Null(session.Cost);
        Assert.Same(rows, session.Rows);
        Assert.Equal(rows[0].Id, session.SelectedTakeId); Assert.Equal(rows[1].Id, session.AuditionedTakeId);
    }

    [Fact]
    public async Task SupersededPreparationCannotPublishAStaleQuoteEvenWhenItIgnoresCancellation()
    {
        var runner = new Runner { PreparationEntered = new(TaskCreationOptions.RunContinuationsAsynchronously),
            ResumePreparation = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var session = new VoiceLabGenerationSession(runner);
        var first = session.UpdateInputsAsync(Input(), ct: Token);
        await runner.PreparationEntered.Task.WaitAsync(Token);
        var second = session.UpdateInputsAsync(Input() with { Text = "Latest" }, ct: Token);
        Assert.Null(session.PendingQuote); Assert.Null(session.Cost);
        runner.ResumePreparation.SetResult();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        var latest = await second;
        Assert.Same(latest, session.PendingQuote);
        Assert.Equal("Latest", runner.Input!.Text);
        Assert.Equal(0, runner.Sends);
    }

    [Fact]
    public async Task InputChangeDuringRunCancelsOldApprovalAndPreparesOnlyLatestInputs()
    {
        var runner = new Runner { Resume = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var session = new VoiceLabGenerationSession(runner);
        await session.UpdateInputsAsync(Input(), ct: Token);
        var old = session.PendingQuote!;
        var run = session.ContinueAsync(Token);
        await runner.Entered.Task.WaitAsync(Token);
        var changed = session.UpdateInputsAsync(Input() with { Text = "Latest" }, ct: Token);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
        await changed;
        Assert.Equal("Latest", runner.Input!.Text);
        Assert.NotEqual(old.Id, session.PendingQuote!.Id);
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ApproveAsync(old, true, Token));
        Assert.Equal(0, runner.Sends);
    }

    [Fact]
    public async Task AutomaticRequoteRefreshesMonthlySpendAfterTheCompletedRun()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        await session.UpdateInputsAsync(Input(), new(0.10m, 0), Token);
        Assert.Equal(VoiceLabCostPresentationKind.Inline, session.Cost!.Kind);
        runner.Started = () => runner.RefreshedSpent = 0.06m;
        await session.ContinueAsync(Token);
        Assert.Equal(VoiceLabCostPresentationKind.Confirm, session.Cost!.Kind);
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.TryAnotherAsync(Token));
        Assert.Equal(3, runner.Sends);
    }
    [Fact]
    public async Task AutomaticQuoteEnforcesMonthlyCapAndExactMonotonicExpiry()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        await session.UpdateInputsAsync(Input(), new(1, 0.99m), Token);
        var old = session.PendingQuote!;
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.GenerateAgainAsync(Token));
        await session.ApproveAsync(old, true, Token);
        var rows = session.Rows;
        var next = session.PendingQuote!;
        Assert.NotEqual(old.Id, next.Id);
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.TryAnotherAsync(Token));
        runner.Clock.Elapsed = TimeSpan.FromMinutes(5).Ticks;
        Assert.Null(session.PendingQuote); Assert.Null(session.Cost);
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ApproveAsync(next, true, Token));
        await Assert.ThrowsAsync<VoiceLabException>(() => session.TryAnotherAsync(Token));
        Assert.Same(rows, session.Rows); Assert.Equal(3, runner.Sends);
    }

    [Fact]
    public async Task AutomaticRequoteFailureDoesNotHideSuccessfulRunOrRetireItsRows()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        await session.UpdateInputsAsync(Input(), ct: Token);
        runner.Started = () => runner.FailPreparation = true;
        Assert.Equal(VoiceLabGenerationAction.Completed, await session.ContinueAsync(Token));
        Assert.Equal(3, session.Rows.Count); Assert.Equal(3, runner.Sends);
        Assert.Null(session.PendingQuote); Assert.NotNull(session.PreparationFailure);
    }

    [Fact]
    public async Task CompletedRunAutomaticallyExposesFreshWholeRunPrice()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        var first = await session.PrepareAsync(Input(), ct: Token);
        await session.ContinueAsync(Token);
        var next = Assert.IsType<VoiceLabTakeRunQuote>(session.PendingQuote);
        Assert.NotEqual(first.Id, next.Id);
        Assert.Equal(3, next.Takes.Count);
        Assert.Equal(6, next.Actions.Count);
        Assert.NotNull(session.Cost);
        Assert.Equal(3, runner.Sends);
        Assert.Equal(3, session.Rows.Count);
    }
    [Fact]
    public async Task RegenerationPreparesFreshWholeRunAndPreservesPriorRowsUntilLaunch()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        var input = Input();
        var first = await session.PrepareAsync(input, ct: Token);
        Assert.Equal(0, runner.Sends);
        await session.ContinueAsync(Token);
        var previous = session.Rows;
        Assert.Equal(3, previous.Count);
        var second = await session.TryAnotherAsync(input, ct: Token);
        Assert.NotEqual(first.Id, second.Id);
        Assert.Equal(3, second.Takes.Count); Assert.Equal(6, second.Actions.Count);
        Assert.Same(previous, session.Rows);
        Assert.DoesNotContain(second.Actions, action => first.Actions.Any(old => old.Token == action.Token));
        input.Source[0] = 0.9f;
        Assert.Equal(0.1f, runner.Input!.Source[0]);
        runner.Started = () => Assert.Empty(session.Rows);
        await session.ContinueAsync(Token);
        Assert.Equal(6, runner.Sends);
        Assert.Equal(new[] { "Take 1", "Take 2", "Take 3" }, session.Rows.Select(row => row.DisplayName));
        Assert.DoesNotContain(session.Rows, row => previous.Any(old => old.Id == row.Id));
        await session.GenerateAgainAsync(input, ct: Token);
        var kept = session.Rows;
        await session.ApproveAsync(session.PendingQuote!, false, Token);
        Assert.Same(kept, session.Rows); Assert.NotNull(session.PendingQuote); Assert.NotNull(runner.Pending);
        Assert.Equal(6, runner.Sends);
        Assert.NotNull(session.Cost);
    }

    [Theory]
    [InlineData("0", false)]
    [InlineData("0.49", false)]
    [InlineData("0.50", true)]
    [InlineData("0.60", true)]
    [InlineData(null, true)]
    public async Task NextClickRunsOnlyKnownPricesBelowS14(string? price, bool confirms)
    {
        var runner = new Runner { Price = price is null ? null : decimal.Parse(price, System.Globalization.CultureInfo.InvariantCulture) };
        var session = new VoiceLabGenerationSession(runner);
        await session.TryAnotherAsync(Input(), ct: Token);
        Assert.Equal(0, runner.Sends);
        Assert.Equal(confirms ? VoiceLabGenerationAction.ConfirmationRequired : VoiceLabGenerationAction.Completed, await session.ContinueAsync(Token));
        Assert.Equal(confirms ? 0 : 3, runner.Sends);
        if (confirms) { await session.ApproveAsync(session.PendingQuote!, true, Token); Assert.Equal(3, runner.Sends); }
    }

    [Fact]
    public async Task MonthlyCapAndCancelledApprovalKeepPriorTakes()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        await session.PrepareAsync(Input(), ct: Token); await session.ContinueAsync(Token);
        var previous = session.Rows;
        await session.GenerateAgainAsync(Input(), new(1, 0.99m), Token);
        Assert.Equal(VoiceLabGenerationAction.ConfirmationRequired, await session.ContinueAsync(Token));
        Assert.Same(previous, session.Rows);
        await session.ApproveAsync(session.PendingQuote!, false, Token);
        Assert.Same(previous, session.Rows); Assert.Equal(3, runner.Sends);
    }

    [Fact]
    public async Task FailedPreparationAndPrelaunchFailureLeavePriorRowsUsable()
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        await session.PrepareAsync(Input(), ct: Token); await session.ContinueAsync(Token);
        var previous = session.Rows;
        runner.FailPreparation = true;
        await Assert.ThrowsAsync<VoiceLabException>(() => session.TryAnotherAsync(Input(), ct: Token));
        Assert.Same(previous, session.Rows); Assert.Null(session.PendingQuote);
        runner.FailPreparation = false;
        await session.TryAnotherAsync(Input(), ct: Token);
        runner.FailBeforeStart = true;
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ContinueAsync(Token));
        Assert.Same(previous, session.Rows); Assert.NotNull(session.PendingQuote); Assert.NotNull(session.Cost);
        Assert.Equal(3, runner.Sends);
    }

    [Fact]
    public async Task ConcurrentClicksCannotReplaceOrExecuteTheApprovedRun()
    {
        var runner = new Runner { Resume = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var session = new VoiceLabGenerationSession(runner);
        await session.PrepareAsync(Input(), ct: Token);
        var execution = session.ContinueAsync(Token);
        await runner.Entered.Task.WaitAsync(Token);
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ContinueAsync(Token));
        await Assert.ThrowsAsync<VoiceLabException>(() => session.TryAnotherAsync(Input(), ct: Token));
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ApproveAsync(session.PendingQuote!, false, Token));
        runner.Resume.SetResult(); await execution;
        Assert.Equal(3, runner.Sends);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancellationBeforeLaunchKeepsPriorTakesAndDiscardsTheNewQuote(bool duringPreparation)
    {
        var runner = new Runner();
        var session = new VoiceLabGenerationSession(runner);
        await session.PrepareAsync(Input(), ct: Token); await session.ContinueAsync(Token);
        var previous = session.Rows;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(Token);
        if (duringPreparation)
        {
            runner.Prepared = cancellation.Cancel;
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.TryAnotherAsync(Input(), ct: cancellation.Token));
        }
        else
        {
            await session.GenerateAgainAsync(Input(), ct: Token);
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.ContinueAsync(cancellation.Token));
        }
        Assert.Same(previous, session.Rows);
        if (duringPreparation) { Assert.Null(session.PendingQuote); Assert.Null(runner.Pending); }
        else { Assert.NotNull(session.PendingQuote); Assert.NotNull(runner.Pending); }
        Assert.Equal(3, runner.Sends);
    }
}
