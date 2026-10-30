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
            var monthlyCap = await runner.RefreshMonthlyCapAsync(request.Cap, request.Cancellation.Token).ConfigureAwait(false);
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
            if (cost?.Kind == VoiceLabCostPresentationKind.Confirm) return VoiceLabGenerationAction.ConfirmationRequired;
        }
        await ApproveAsync(prepared, true, ct).ConfigureAwait(false);
        return VoiceLabGenerationAction.Completed;
    }

    public async Task<VoiceLabTakeRunResult?> ApproveAsync(VoiceLabTakeRunQuote expected, bool approved, CancellationToken ct = default)
    {
        VoiceLabTakeInput snapshot;
        VoiceLabMonthlyCap? monthlyCap;
        long version;
        CancellationTokenSource cancellation;
        Task lease;
        lock (sync)
        {
            if (!ReferenceEquals(RequireQuote(), expected)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            snapshot = input!; monthlyCap = cap; version = revision;
            quote = null; cost = null; executing = true;
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(ct);
            active = cancellation;
            lease = serial.WaitAsync();
        }
        var entered = false;
        var completed = false;
        try
        {
            await lease.ConfigureAwait(false);
            entered = true;
            lock (sync)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                if (revision != version || !runner.IsQuoteFresh(expected)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            }
            if (!approved) { await runner.DiscardPendingAsync().ConfigureAwait(false); return null; }
            var result = await runner.ExecuteAsync(expected, true, progress =>
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
        finally
        {
            if (entered) await runner.DiscardPendingAsync().ConfigureAwait(false);
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
