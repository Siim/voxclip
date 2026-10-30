using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabGenerationSessionTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static VoiceLabTakeInput Input() => new("Hello", "eleven_v3", "record", "en", 1, "source", [0.1f], 24000, [], new HashSet<string>(),
        new("first", "last", [], [], 0, 1, 0, 24000, new(VoiceLabSeamKind.Hard, 0, 0, 0), new(VoiceLabSeamKind.Hard, 1, 24000, 0)), null, null, false, true);
    private sealed class Runner : IVoiceLabTakeRunner
    {
        internal decimal? Price = 0.06m;
        internal int Sends;
        internal VoiceLabTakeInput? Input;
        internal VoiceLabTakeRunQuote? Pending;
        internal bool FailBeforeStart;
        internal bool FailPreparation;
        internal Action? Prepared;
        internal Action? Started;
        internal TaskCompletionSource? Resume;
        internal readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            if (FailPreparation) throw new VoiceLabException(VoiceLabErrorKind.MissingKey);
            Input = input;
            var gate = new VoiceLabActionGate();
            var actionIndex = 0;
            VoiceLabPreparedAction Action(VoiceLabOperation operation) => gate.Prepare(Guid.NewGuid().ToString(),
                new("elevenlabs", operation, 1, "call", Price is null ? null : actionIndex++ == 0 ? Price : 0, null, "fixture"),
                new(operation, Guid.NewGuid(), "elevenlabs", ElevenLabsRegion.Default, "/fixture", null, null, null, null, "record"));
            Pending = new(Guid.NewGuid(), Enumerable.Range(0, 3).Select(index => new VoiceLabTakeQuote(index, (uint)index,
                Action(VoiceLabOperation.TextToSpeech), Action(VoiceLabOperation.SpeechToText))).ToArray());
            Prepared?.Invoke();
            return Task.FromResult(Pending);
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
        public Task DiscardPendingAsync() { Pending = null; return Task.CompletedTask; }
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
        await session.ApproveAsync(false, Token);
        Assert.Same(kept, session.Rows); Assert.Null(session.PendingQuote); Assert.Null(runner.Pending);
        Assert.Equal(6, runner.Sends);
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ContinueAsync(Token));
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
        if (confirms) { await session.ApproveAsync(true, Token); Assert.Equal(3, runner.Sends); }
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
        await session.ApproveAsync(false, Token);
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
        Assert.Same(previous, session.Rows); Assert.Null(session.PendingQuote);
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
        await Assert.ThrowsAsync<VoiceLabException>(() => session.ApproveAsync(false, Token));
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
        Assert.Null(session.PendingQuote); Assert.Null(runner.Pending);
        Assert.Equal(3, runner.Sends);
    }
}
