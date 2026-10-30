using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

internal enum RewriteGenerationPhase { Idle, Preparing, AwaitingApproval, Generating, NonePassed, Failed, Cancelled, LengthChanged, ReadyToAccept }
internal sealed record RewriteVoice(string Id, string Label);
internal sealed record RewriteGenerationChoices(IReadOnlyList<RewriteVoice> Voices, IReadOnlyList<VoiceLabModel> Models);
internal sealed class RewriteGenerationException(string message) : Exception(message);

internal sealed partial class RewriteGeneration : IDisposable
{
    internal const string SendLine = "Sends the new words and a short audio check to ElevenLabs with your key. No video.";
    internal const string NonePassed = "These takes didn't sound right. Try different wording or re-record.";
    private readonly VoiceLabGenerationSession core;
    private readonly ObservedRunner runner;
    private readonly Func<CancellationToken, Task<RewriteGenerationChoices>> discover;
    private readonly Func<string, string, uint, CancellationToken, Task<VoiceLabTakeInput?>> buildInput;
    private readonly Func<CancellationToken, Task<bool>> consent;
    private readonly Func<bool> current;
    private readonly Func<Action, Task> onUi;
    private readonly Action? release;
    private readonly TimeProvider clock;
    private ITimer? quoteExpiry;
    private VoiceLabTakeRunQuote? timedQuote;
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? updating;
    private CancellationTokenSource? executing;
    private CancellationTokenSource? discoveringInputs;
    private VoiceLabTakeRunQuote? shownQuote;
    private VoiceLabTakeInput? pendingInput;
    private bool closed;
    private bool discovering;
    private bool confirming;
    private Task discovery = Task.CompletedTask;
    private long revision;
    private long discoveryRevision;
    private uint seed = (uint)Random.Shared.NextInt64(0, 1L << 32);
    internal RewriteGenerationPhase Phase { get; private set; }
    internal IReadOnlyList<RewriteVoice> Voices { get; private set; } = [];
    internal IReadOnlyList<VoiceLabModel> Models { get; private set; } = [];
    internal string? VoiceId { get; private set; }
    internal string? ModelId { get; private set; }
    internal string Problem { get; private set; } = "";
    internal string Announcement { get; private set; } = "";
    internal bool IsRunning => executing is not null;
    internal bool IsPreparing { get; private set; }
    internal bool HasDiscovered { get; private set; }
    internal bool HasStartedDiscovery { get; private set; }
    internal bool IsRequestingConsent { get; private set; }
    internal VoiceLabTakeRunQuote? Quote => core.PendingQuote;
    internal VoiceLabCostPresentationResult? Cost => core.Cost;
    internal IReadOnlyList<VoiceLabTakeRow> Rows => core.Rows.Where(row => !rejected.Contains(row.Id)).ToArray();
    internal Guid? SelectedTakeId => core.SelectedTakeId;
    internal Guid? AuditionedTakeId => core.AuditionedTakeId;
    internal VoiceLabTakeInput? ReviewedInput { get; private set; }
    internal bool ReviewedInputsCurrent { get; private set; }
    internal bool CanExecute => !closed && current() && !accepting && !IsRunning && !IsPreparing && !discovering &&
        Quote is { } quote && ReferenceEquals(quote, shownQuote) && Cost is not null;
    internal string ButtonTitle
    {
        get
        {
            RefreshExpiredQuote();
            return GenerationButtonTitle(Rows.Count == 0 ? "Generate Takes" : "Generate Again");
        }
    }
    internal string GenerationButtonTitle(string title) => VoiceLabCostPresentation.ButtonTitle(title, null,
        new(VoiceLabCostPresentationKind.Inline, !IsPreparing && Quote?.Estimate.Usd is > 0m and var amount ? VoiceLabCostPresentation.Format(amount) : ""));
    internal string ButtonName => Quote?.Estimate.Usd is { } amount
        ? "Generate up to 3 new takes, about " + VoiceLabCostPresentation.Format(amount).Replace("≈ ", "", StringComparison.Ordinal)
        : "Generate up to 3 new takes";
    internal string ProgressCopy => $"Generating take {Math.Min(3, Rows.Count + 1)} of 3…";
    internal Task PendingUpdate { get; private set; } = Task.CompletedTask;
    internal Task Cleanup { get; private set; } = Task.CompletedTask;
    internal event EventHandler? Changed;

    internal RewriteGeneration(IVoiceLabTakeRunner takeRunner,
        Func<CancellationToken, Task<RewriteGenerationChoices>> discover,
        Func<string, string, uint, CancellationToken, Task<VoiceLabTakeInput?>> buildInput,
        Func<CancellationToken, Task<bool>> consent, Func<CancellationToken, Task<decimal?>> readMonthlyCap,
        Func<bool> current, Func<Action, Task>? onUi = null, Action? release = null, TimeProvider? timeProvider = null)
    {
        this.discover = discover; this.buildInput = buildInput; this.consent = consent;
        this.current = current; this.onUi = onUi ?? (action => { action(); return Task.CompletedTask; });
        this.release = release ?? (() => (takeRunner as IDisposable)?.Dispose());
        clock = timeProvider ?? TimeProvider.System;
        runner = new(takeRunner, ProgressAsync);
        core = new(runner) { ReadMonthlyCapAsync = readMonthlyCap };
    }

    internal Task DiscoverAsync()
    {
        if (closed || !current()) return Task.CompletedTask;
        if (discovering) return discovery;
        HasStartedDiscovery = true;
        return discovery = DiscoverCurrentAsync();
    }
    internal Task DiscoveryInputsChangedAsync()
    {
        if (closed) return Task.CompletedTask;
        discoveryRevision++;
        Cancel(discoveringInputs);
        HasDiscovered = false; Voices = []; Models = []; VoiceId = null; ModelId = null;
        var update = InputsChangedAsync();
        return HasStartedDiscovery ? DiscoverAsync() : update;
    }
    private async Task DiscoverCurrentAsync()
    {
        if (closed || discovering || !current()) return;
        discovering = true;
        Problem = ""; Announcement = "";
        Notify();
        try
        {
            IsRequestingConsent = true;
            var allowed = await consent(lifetime.Token);
            IsRequestingConsent = false;
            if (!allowed || closed || !current()) return;
            while (!closed && current())
            {
                var version = discoveryRevision;
                using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                discoveringInputs = cancellation;
                try
                {
                    var choices = await discover(cancellation.Token);
                    cancellation.Token.ThrowIfCancellationRequested();
                    if (closed || !current()) return;
                    if (version != discoveryRevision) continue;
                    Voices = choices.Voices; Models = choices.Models;
                    if (!Voices.Any(voice => voice.Id == VoiceId)) VoiceId = Voices.FirstOrDefault()?.Id;
                    if (!Models.Any(model => model.Id == ModelId)) ModelId = Models.FirstOrDefault()?.Id;
                    HasDiscovered = true;
                    break;
                }
                catch (OperationCanceledException) when (!closed && version != discoveryRevision) { }
                finally { if (ReferenceEquals(discoveringInputs, cancellation)) discoveringInputs = null; }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!closed) Fail(error); }
        finally { IsRequestingConsent = false; discovering = false; Notify(); }
        if (!closed && HasDiscovered) await InputsChangedAsync();
    }

    internal Task ChooseVoiceAsync(string? id)
    {
        if (id == VoiceId || !Voices.Any(voice => voice.Id == id)) return Task.CompletedTask;
        VoiceId = id; return InputsChangedAsync();
    }
    internal Task ChooseModelAsync(string? id)
    {
        if (id == ModelId || !Models.Any(model => model.Id == id)) return Task.CompletedTask;
        ModelId = id; return InputsChangedAsync();
    }
    internal Task InputsChangedAsync(bool preserveReview = false)
    {
        if (closed) return Task.CompletedTask;
        StopQuoteExpiry();
        Cancel(updating); Cancel(executing);
        runner.InvalidatePreparation();
        shownQuote = null; revision++;
        pendingInput = null;
        if (!preserveReview) ReviewedInputsCurrent = false;
        Problem = ""; Announcement = "";
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        updating = cancellation;
        IsPreparing = !discovering && VoiceId is not null && ModelId is not null && current();
        if (Rows.Count == 0) Phase = IsPreparing ? RewriteGenerationPhase.Preparing : RewriteGenerationPhase.Idle;
        Notify();
        return PendingUpdate = PrepareAsync(revision, cancellation);
    }
    private async Task PrepareAsync(long version, CancellationTokenSource cancellation)
    {
        try
        {
            await core.CancelAsync();
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsPreparing || VoiceId is null || ModelId is null) return;
            var input = await buildInput(VoiceId, ModelId, seed, cancellation.Token);
            if (closed || revision != version || !current()) return;
            if (input is null) { Phase = Rows.Count == 0 ? RewriteGenerationPhase.Idle : ReviewPhase(); return; }
            pendingInput = input.Snapshot();
            await core.UpdateInputsAsync(input, ct: cancellation.Token);
            if (revision == version && Rows.Count == 0) Phase = RewriteGenerationPhase.AwaitingApproval;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!closed && revision == version) Fail(error); }
        finally
        {
            if (ReferenceEquals(updating, cancellation)) { updating = null; IsPreparing = false; TrackQuoteExpiry(); Notify(); }
            cancellation.Dispose();
        }
    }
    internal void MarkEstimateShown(VoiceLabTakeRunQuote quote)
    {
        if (closed || IsPreparing || !ReferenceEquals(Quote, quote) || ReferenceEquals(shownQuote, quote)) return;
        shownQuote = quote; Notify();
    }
    internal async Task GenerateAsync(Func<string, CancellationToken, Task<bool>> confirm)
    {
        if (closed || accepting || IsRunning || IsPreparing || !current()) return;
        if (Quote is null) { await InputsChangedAsync(preserveReview: true); return; }
        if (!CanExecute) return;
        var version = revision;
        var quote = Quote!;
        if (pendingInput is { } input) pendingInput = input with { Seed = quote.Takes[0].Seed };
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        executing = cancellation;
        runStarted = false;
        var declinedAtDispatch = false;
        core.ConfirmCostAsync = async (copy, token) =>
        {
            var approved = await ConfirmAsync(copy, confirm, token);
            if (!approved) declinedAtDispatch = true;
            return approved;
        };
        Problem = ""; Notify();
        try
        {
            var action = await core.ContinueAsync(cancellation.Token);
            if (action == VoiceLabGenerationAction.ConfirmationRequired)
            {
                if (declinedAtDispatch) return;
                if (core.Cost is not { } cost || !await ConfirmAsync(cost.Text, confirm, cancellation.Token)) return;
                cancellation.Token.ThrowIfCancellationRequested();
                if (closed || revision != version || !current()) return;
                if (!ReferenceEquals(Quote, quote)) { await InputsChangedAsync(preserveReview: true); return; }
                await core.ApproveAsync(quote, true, cancellation.Token);
            }
            if (closed || revision != version) return;
            if (!ReferenceEquals(Quote, quote))
            {
                seed = unchecked(seed + 3);
                shownQuote = null;
                ReviewedInputsCurrent = ReviewedInput is not null && ReferenceEquals(ReviewedInput, pendingInput);
                if (runStarted && runner.Result is { } completed) FinishTakes(completed);
            }
            if (runner.Result is { End: VoiceLabTakeRunEnd.Fatal } result)
                Fail(result.Rows.LastOrDefault()?.Failure ?? new VoiceLabException(VoiceLabErrorKind.ProviderFailure));
            if (core.PreparationFailure is { } error) Fail(error);
        }
        catch (OperationCanceledException) { if (!closed && revision == version) Phase = runStarted ? RewriteGenerationPhase.Cancelled : ReviewPhase(); }
        catch (VoiceLabException error) when (error.Kind == VoiceLabErrorKind.ConsentRequired && !closed && revision == version && Quote is null)
        { await InputsChangedAsync(); }
        catch (Exception error) when (error is not OutOfMemoryException) { if (!closed && revision == version) Fail(error); }
        finally
        {
            if (ReferenceEquals(executing, cancellation)) executing = null;
            cancellation.Dispose(); TrackQuoteExpiry(); Notify();
        }
        if (!closed && takes is not null && BestTakeId is { } best && autoplayed.Add(best)) await PlayTakeAsync(best);
    }
    private void TrackQuoteExpiry()
    {
        if (closed || IsRunning || IsPreparing) return;
        var quote = Quote;
        if (quote is null && timedQuote is not null)
        {
            if (Problem.Length == 0) RefreshExpiredQuote();
            else StopQuoteExpiry();
            return;
        }
        if (ReferenceEquals(quote, timedQuote))
        {
            if (quote is not null) quoteExpiry?.Change(QuoteFreshnessDelay(quote), Timeout.InfiniteTimeSpan);
            return;
        }
        StopQuoteExpiry();
        if (quote is null) return;
        timedQuote = quote;
        quoteExpiry = clock.CreateTimer(_ => { _ = onUi(RefreshExpiredQuote); }, null,
            QuoteFreshnessDelay(quote), Timeout.InfiniteTimeSpan);
    }
    private TimeSpan QuoteFreshnessDelay(VoiceLabTakeRunQuote quote) =>
        TimeSpan.FromTicks(Math.Clamp((quote.ExpiresAt - clock.GetUtcNow()).Ticks, 0, TimeSpan.FromSeconds(30).Ticks));
    private void RefreshExpiredQuote()
    {
        if (closed || !current() || IsRunning || IsPreparing || discovering || timedQuote is not { } quote) return;
        if (clock.GetUtcNow() >= quote.ExpiresAt || !runner.IsQuoteFresh(quote)) _ = InputsChangedAsync(preserveReview: true);
        else quoteExpiry?.Change(QuoteFreshnessDelay(quote), Timeout.InfiniteTimeSpan);
    }
    private void StopQuoteExpiry()
    {
        quoteExpiry?.Dispose(); quoteExpiry = null; timedQuote = null;
    }
    private async Task<bool> ConfirmAsync(string copy, Func<string, CancellationToken, Task<bool>> confirm, CancellationToken ct)
    {
        var approved = false;
        Task<bool>? pending = null;
        await onUi(() =>
        {
            if (closed || confirming || ct.IsCancellationRequested || !current()) return;
            confirming = true;
            pending = confirm(copy, ct);
        });
        if (pending is null) return false;
        try { approved = await pending.WaitAsync(ct); }
        finally { await onUi(() => confirming = false); }
        return approved && !ct.IsCancellationRequested && !closed;
    }
    internal async Task CancelAsync()
    {
        Cancel(executing);
        await core.CancelAsync();
        if (!closed) { Phase = runStarted ? RewriteGenerationPhase.Cancelled : ReviewPhase(); Notify(); }
    }
    internal void SelectTake(Guid id) => _ = SelectTakeAsync(id);
    internal void AuditionTake(Guid? id) { core.AuditionTake(id); Notify(); }
    private RewriteGenerationPhase ReviewPhase() => core.SelectedTakeId is { } selected && Rows.FirstOrDefault(row => row.Id == selected) is { } row
        ? row.Fits || VideoChoice is not null ? RewriteGenerationPhase.ReadyToAccept : RewriteGenerationPhase.LengthChanged
        : Rows.Count == 0 ? RewriteGenerationPhase.Idle : RewriteGenerationPhase.NonePassed;
    private async Task ProgressAsync()
    {
        await onUi(() =>
        {
            if (closed || executing is null || executing.IsCancellationRequested) return;
            Phase = RewriteGenerationPhase.Generating;
            if (core.Rows.Count == 0)
            {
                runStarted = true; rejected.Clear(); BestTakeId = null; VideoChoice = null;
                reviewEnd = null;
                ReviewedInput = pendingInput;
            }
            if (Rows.LastOrDefault() is { Selectable: true } row) Announcement = TakeRowPresentation.Ready(row.Index);
            Notify();
        });
        if (core.Rows.Count == 0 && takes is not null) await takes.Audition.InvalidateAsync();
    }
    private void Fail(Exception error)
    {
        Problem = RewriteSession.Refusal(error);
        Announcement = Problem;
        if (runStarted || !Rows.Any(row => row.Selectable)) Phase = RewriteGenerationPhase.Failed;
    }
    private void Notify() { if (!closed) Changed?.Invoke(this, EventArgs.Empty); }
    private static void Cancel(CancellationTokenSource? source)
    {
        try { source?.Cancel(); } catch (ObjectDisposedException) { }
    }
    public void Dispose()
    {
        if (closed) return;
        StopQuoteExpiry();
        closed = true; revision++; Cancel(updating); Cancel(executing); Cancel(discoveringInputs); lifetime.Cancel(); shownQuote = null;
        Cleanup = RetireAsync();
    }
    private async Task RetireAsync()
    {
        try
        {
            if (takes is not null)
            {
                takes.Audition.Changed -= AuditionChanged;
                await takes.Audition.SelectionChangedAsync(null);
                await takes.Audition.InvalidateAsync();
                await takes.Audition.DisposeAsync();
            }
            await core.InvalidateAsync(); await discovery; await PendingUpdate;
        }
        finally { release?.Invoke(); lifetime.Dispose(); }
    }
    private sealed class ObservedRunner(IVoiceLabTakeRunner inner, Func<Task> changed) : IVoiceLabTakeRunner
    {
        internal VoiceLabTakeRunResult? Result { get; private set; }
        public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default) => inner.PrepareAsync(input, ct);
        public Task DiscardPendingAsync() => inner.DiscardPendingAsync();
        public void InvalidatePreparation() => inner.InvalidatePreparation();
        public Task InvalidateAsync() => inner.InvalidateAsync();
        public bool IsQuoteFresh(VoiceLabTakeRunQuote quote) => inner.IsQuoteFresh(quote);
        public Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => inner.RefreshMonthlyCapAsync(cap, ct);
        public Task<decimal?> ReadMonthlySpendAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default) => inner.ReadMonthlySpendAsync(cap, ct);
        public Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved, Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default) =>
            inner.ExecuteAsync(quote, approved, progress, ct);
        public async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
            Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
        {
            Result = null;
            return Result = await inner.ExecuteWithDispatchAsync(quote, dispatch, async rows =>
                { if (progress is not null) await progress(rows); await changed(); }, ct);
        }
    }
}
