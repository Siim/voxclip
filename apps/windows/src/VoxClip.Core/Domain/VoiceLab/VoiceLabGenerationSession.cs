#pragma warning disable CS1591
namespace VoxClip.Core.Domain.VoiceLab;

public interface IVoiceLabTakeRunner
{
    Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default);
    Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default);
    Task DiscardPendingAsync();
    void InvalidatePreparation();
    bool IsQuoteFresh(VoiceLabTakeRunQuote quote);
    Task<VoiceLabMonthlyCap?> RefreshMonthlyCapAsync(VoiceLabMonthlyCap? cap, CancellationToken ct = default);
    async Task<decimal?> ReadMonthlySpendAsync(VoiceLabMonthlyCap? fallback, CancellationToken ct = default) =>
        (await RefreshMonthlyCapAsync(fallback ?? new(decimal.MaxValue, 0), ct).ConfigureAwait(false))?.Spent;
    async Task<VoiceLabTakeRunResult> ExecuteWithDispatchAsync(VoiceLabTakeRunQuote quote, VoiceLabRunDispatch dispatch,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
    {
        await dispatch.AuthorizeAsync(ct).ConfigureAwait(false);
        return await dispatch.Start(() => ExecuteAsync(quote, true, progress, ct), ct).ConfigureAwait(false);
    }
}

public enum VoiceLabGenerationAction { Completed, ConfirmationRequired }

public sealed class VoiceLabGenerationSession(IVoiceLabTakeRunner runner)
{
    private sealed record Preparation(long Revision, VoiceLabTakeInput Input, VoiceLabMonthlyCap? Cap, CancellationTokenSource Cancellation);
    private readonly object sync = new();
    private readonly SemaphoreSlim serial = new(1, 1);
    private long revision;
    private bool executing;
    private bool preparing;
    private CancellationTokenSource? active;
    private VoiceLabTakeInput? input;
    private VoiceLabMonthlyCap? cap;
    private VoiceLabTakeRunQuote? quote;
    private VoiceLabCostPresentationResult? cost;
    private Exception? preparationFailure;
    private Guid? selectedTakeId;
    private Guid? auditionedTakeId;
    private IReadOnlyList<VoiceLabTakeRow> rows = Array.Empty<VoiceLabTakeRow>();
    public Func<CancellationToken, Task<decimal?>>? ReadMonthlyCapAsync { get; set; }
    public Func<string, CancellationToken, Task<bool>>? ConfirmCostAsync { get; set; }
    public VoiceLabTakeRunQuote? PendingQuote { get { lock (sync) { ExpireQuote(); return quote; } } }
    public VoiceLabCostPresentationResult? Cost { get { lock (sync) { ExpireQuote(); return cost; } } }
    public Exception? PreparationFailure { get { lock (sync) return preparationFailure; } }
    public bool IsPreparing { get { lock (sync) return preparing; } }
    public IReadOnlyList<VoiceLabTakeRow> Rows { get { lock (sync) return rows; } }
    public Guid? SelectedTakeId { get { lock (sync) return selectedTakeId; } }
    public Guid? AuditionedTakeId { get { lock (sync) return auditionedTakeId; } }

    public void SelectTake(Guid? id) { lock (sync) { RequireRow(id); selectedTakeId = id; } }
    public void AuditionTake(Guid? id) { lock (sync) { RequireRow(id); auditionedTakeId = id; } }
    private void RequireRow(Guid? id)
    {
        if (id.HasValue && !rows.Any(row => row.Id == id)) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
    }

    public Task<VoiceLabGenerationAction> TryAnotherAsync(CancellationToken ct = default) => ContinueAsync(ct);
    public Task<VoiceLabGenerationAction> GenerateAgainAsync(CancellationToken ct = default) => ContinueAsync(ct);
    public Task<VoiceLabTakeRunQuote> TryAnotherAsync(VoiceLabTakeInput input, VoiceLabMonthlyCap? cap = null, CancellationToken ct = default) => PrepareAsync(input, cap, ct);
    public Task<VoiceLabTakeRunQuote> GenerateAgainAsync(VoiceLabTakeInput input, VoiceLabMonthlyCap? cap = null, CancellationToken ct = default) => PrepareAsync(input, cap, ct);
    public Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, VoiceLabMonthlyCap? cap = null, CancellationToken ct = default)
    {
        lock (sync) if (executing) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return UpdateInputsAsync(input, cap, ct);
    }

    public Task<VoiceLabTakeRunQuote> UpdateInputsAsync(VoiceLabTakeInput input, VoiceLabMonthlyCap? cap = null, CancellationToken ct = default)
    {
        var snapshot = input.Snapshot();
        Preparation request;
        CancellationTokenSource? retired;
        lock (sync)
        {
            retired = active;
            request = BeginPreparation(snapshot, cap, ct);
        }
        Cancel(retired);
        return PrepareCurrentAsync(request);
    }

    private Preparation BeginPreparation(VoiceLabTakeInput snapshot, VoiceLabMonthlyCap? monthlyCap, CancellationToken ct)
    {
        runner.InvalidatePreparation();
        quote = null; cost = null; preparationFailure = null; preparing = true;
        input = snapshot; cap = monthlyCap;
        active = CancellationTokenSource.CreateLinkedTokenSource(ct);
        return new(++revision, snapshot, monthlyCap, active);
    }
    private async Task<VoiceLabTakeRunQuote> PrepareCurrentAsync(Preparation request)
    {
        var entered = false;
        try
        {
            await serial.WaitAsync(request.Cancellation.Token).ConfigureAwait(false);
            entered = true;
            await runner.DiscardPendingAsync().ConfigureAwait(false);
            if (!request.Input.ProviderConsent) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            var monthlyCap = await CurrentCapAsync(request.Cancellation.Token).ConfigureAwait(false);
            var prepared = await runner.PrepareAsync(request.Input, request.Cancellation.Token).ConfigureAwait(false);
            lock (sync)
            {
                request.Cancellation.Token.ThrowIfCancellationRequested();
                if (revision != request.Revision) throw new OperationCanceledException(request.Cancellation.Token);
                if (prepared.Takes.Count != 3 || !prepared.Takes.Select(take => take.Index).SequenceEqual(new[] { 0, 1, 2 }) || !runner.IsQuoteFresh(prepared))
                    throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
                quote = prepared;
                cost = VoiceLabCostPresentation.Kind(prepared.Estimate, false, "ElevenLabs", monthlyCap);
            }
            return prepared;
        }
        catch (Exception error)
        {
            if (entered) await runner.DiscardPendingAsync().ConfigureAwait(false);
            lock (sync) if (revision == request.Revision) { quote = null; cost = null; preparationFailure = error; }
            throw;
        }
        finally
        {
            lock (sync) if (revision == request.Revision) { preparing = false; if (ReferenceEquals(active, request.Cancellation)) active = null; }
            if (entered) serial.Release();
            request.Cancellation.Dispose();
        }
    }

    public async Task<VoiceLabGenerationAction> ContinueAsync(CancellationToken ct = default)
    {
        VoiceLabTakeRunQuote prepared;
        lock (sync)
        {
            prepared = RequireQuote();
        }
        var decision = await CurrentDecisionAsync(prepared, ct).ConfigureAwait(false);
        lock (sync)
        {
            if (!ReferenceEquals(RequireQuote(), prepared)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            cost = decision;
            if (decision.Kind == VoiceLabCostPresentationKind.Confirm) return VoiceLabGenerationAction.ConfirmationRequired;
        }
        await ApproveAsync(prepared, true, ct).ConfigureAwait(false);
        lock (sync) return ReferenceEquals(quote, prepared) ? VoiceLabGenerationAction.ConfirmationRequired : VoiceLabGenerationAction.Completed;
    }

    private async Task<VoiceLabMonthlyCap?> CurrentCapAsync(CancellationToken ct)
    {
        VoiceLabMonthlyCap? fallback;
        lock (sync) fallback = cap;
        var spent = await runner.ReadMonthlySpendAsync(fallback, ct).ConfigureAwait(false);
        decimal? limit;
        if (ReadMonthlyCapAsync is { } read) limit = await read(ct).ConfigureAwait(false);
        else { lock (sync) limit = cap?.Limit; }
        ct.ThrowIfCancellationRequested();
        if (limit is null) return null;
        if (spent is null || limit < 0) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        return new(limit.Value, spent.Value);
    }
    private async Task<VoiceLabCostPresentationResult> CurrentDecisionAsync(VoiceLabTakeRunQuote expected, CancellationToken ct)
    {
        var current = await CurrentCapAsync(ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return VoiceLabCostPresentation.Kind(expected.Estimate, false, "ElevenLabs", current);
    }

    public async Task<VoiceLabTakeRunResult?> ApproveAsync(VoiceLabTakeRunQuote expected, bool approved, CancellationToken ct = default)
    {
        VoiceLabTakeInput snapshot;
        VoiceLabMonthlyCap? monthlyCap;
        long version;
        CancellationTokenSource cancellation;
        Task lease;
        VoiceLabCostPresentationResult? approvedCost;
        lock (sync)
        {
            if (!ReferenceEquals(RequireQuote(), expected)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            if (!approved) return null;
            approvedCost = cost;
            snapshot = input!; monthlyCap = cap; version = revision;
            quote = null; cost = null; executing = true;
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
            active = cancellation;
            lease = serial.WaitAsync();
        }
        var entered = false;
        var completed = false;
        var retain = false;
        var started = false;
        try
        {
            await lease.ConfigureAwait(false);
            entered = true;
            lock (sync)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                if (revision != version || !runner.IsQuoteFresh(expected)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            }
            void Validate()
            {
                cancellation.Token.ThrowIfCancellationRequested();
                if (revision != version || !snapshot.ProviderConsent || !started && !runner.IsQuoteFresh(expected))
                    throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            }
            var dispatch = new VoiceLabRunDispatch(async token =>
            {
                while (true)
                {
                    var decision = await CurrentDecisionAsync(expected, token).ConfigureAwait(false);
                    lock (sync) { Validate(); cost = decision; }
                    if (decision.Kind != VoiceLabCostPresentationKind.Confirm || decision == approvedCost) return;
                    if (ConfirmCostAsync is not { } confirm || !await confirm(decision.Text, token).ConfigureAwait(false))
                        throw new VoiceLabConfirmationRequiredException(decision);
                    lock (sync) { Validate(); approvedCost = decision; }
                }
            }, action =>
            {
                lock (sync) { Validate(); action(); started = true; }
            });
            await dispatch.AuthorizeAsync(cancellation.Token).ConfigureAwait(false);
            var result = await runner.ExecuteWithDispatchAsync(expected, dispatch, progress =>
            {
                lock (sync)
                {
                    rows = Array.AsReadOnly(progress.ToArray());
                    if (rows.Count == 0) { selectedTakeId = null; auditionedTakeId = null; }
                }
                return Task.CompletedTask;
            }, cancellation.Token).ConfigureAwait(false);
            lock (sync) rows = Array.AsReadOnly(result.Rows.ToArray());
            completed = true;
            return result;
        }
        catch (VoiceLabConfirmationRequiredException error)
        {
            lock (sync)
            {
                if (!started && revision == version && runner.IsQuoteFresh(expected))
                { retain = true; quote = expected; cost = error.Decision; }
            }
            if (!retain) throw;
            return null;
        }
        finally
        {
            if (entered && !retain) await runner.DiscardPendingAsync().ConfigureAwait(false);
            Preparation? next = null;
            lock (sync)
            {
                executing = false;
                if (ReferenceEquals(active, cancellation)) active = null;
                if (completed && revision == version)
                    next = BeginPreparation(snapshot with { Seed = unchecked(snapshot.Seed + 3) }, monthlyCap, CancellationToken.None);
            }
            if (entered) serial.Release();
            cancellation.Dispose();
            if (next is not null)
            {
                try { await PrepareCurrentAsync(next).ConfigureAwait(false); }
                catch (Exception) { }
            }
        }
    }

    private VoiceLabTakeRunQuote RequireQuote()
    {
        ExpireQuote();
        if (executing || preparing || quote is null) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        return quote;
    }
    private void ExpireQuote()
    {
        if (quote is not null && !runner.IsQuoteFresh(quote)) { quote = null; cost = null; }
    }
    private static void Cancel(CancellationTokenSource? source)
    {
        try { source?.Cancel(); }
        catch (ObjectDisposedException) { }
    }
}
