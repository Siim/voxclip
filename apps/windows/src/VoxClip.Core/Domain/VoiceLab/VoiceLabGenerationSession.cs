#pragma warning disable CS1591
namespace VoxClip.Core.Domain.VoiceLab;

public interface IVoiceLabTakeRunner
{
    Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, CancellationToken ct = default);
    Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeRunQuote quote, bool approved,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default);
    Task DiscardPendingAsync();
}

public enum VoiceLabGenerationAction { Completed, ConfirmationRequired }

public sealed class VoiceLabGenerationSession(IVoiceLabTakeRunner runner)
{
    private readonly object sync = new();
    private bool busy;
    private VoiceLabTakeRunQuote? quote;
    private VoiceLabCostPresentationResult? cost;
    private IReadOnlyList<VoiceLabTakeRow> rows = Array.Empty<VoiceLabTakeRow>();
    public VoiceLabTakeRunQuote? PendingQuote { get { lock (sync) return quote; } }
    public VoiceLabCostPresentationResult? Cost { get { lock (sync) return cost; } }
    public IReadOnlyList<VoiceLabTakeRow> Rows { get { lock (sync) return rows; } }

    public Task<VoiceLabTakeRunQuote> TryAnotherAsync(VoiceLabTakeInput input, VoiceLabMonthlyCap? cap = null, CancellationToken ct = default) =>
        PrepareAsync(input, cap, ct);
    public Task<VoiceLabTakeRunQuote> GenerateAgainAsync(VoiceLabTakeInput input, VoiceLabMonthlyCap? cap = null, CancellationToken ct = default) =>
        PrepareAsync(input, cap, ct);

    public async Task<VoiceLabTakeRunQuote> PrepareAsync(VoiceLabTakeInput input, VoiceLabMonthlyCap? cap = null, CancellationToken ct = default)
    {
        lock (sync) { Enter(); quote = null; cost = null; }
        try
        {
            await runner.DiscardPendingAsync().ConfigureAwait(false);
            var prepared = await runner.PrepareAsync(input.Snapshot(), ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (prepared.Takes.Count != 3 || !prepared.Takes.Select(take => take.Index).SequenceEqual(new[] { 0, 1, 2 }))
            {
                await runner.DiscardPendingAsync().ConfigureAwait(false);
                throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
            }
            lock (sync)
            {
                quote = prepared;
                cost = VoiceLabCostPresentation.Kind(prepared.Estimate, false, "ElevenLabs", cap);
            }
            return prepared;
        }
        catch
        {
            await runner.DiscardPendingAsync().ConfigureAwait(false);
            throw;
        }
        finally { lock (sync) busy = false; }
    }

    public async Task<VoiceLabGenerationAction> ContinueAsync(CancellationToken ct = default)
    {
        VoiceLabTakeRunQuote prepared;
        lock (sync)
        {
            if (busy || quote is null) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            if (cost?.Kind == VoiceLabCostPresentationKind.Confirm) return VoiceLabGenerationAction.ConfirmationRequired;
            prepared = quote;
        }
        await ApproveAsync(true, prepared, ct).ConfigureAwait(false);
        return VoiceLabGenerationAction.Completed;
    }

    public Task<VoiceLabTakeRunResult?> ApproveAsync(bool approved, CancellationToken ct = default) => ApproveAsync(approved, null, ct);

    private async Task<VoiceLabTakeRunResult?> ApproveAsync(bool approved, VoiceLabTakeRunQuote? expected, CancellationToken ct)
    {
        VoiceLabTakeRunQuote prepared;
        lock (sync)
        {
            if (busy || quote is null || expected is not null && !ReferenceEquals(expected, quote)) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
            Enter(); prepared = quote; quote = null; cost = null;
        }
        try
        {
            if (!approved) { await runner.DiscardPendingAsync().ConfigureAwait(false); return null; }
            var result = await runner.ExecuteAsync(prepared, true, progress =>
            {
                lock (sync) rows = Array.AsReadOnly(progress.ToArray());
                return Task.CompletedTask;
            }, ct).ConfigureAwait(false);
            lock (sync) rows = Array.AsReadOnly(result.Rows.ToArray());
            return result;
        }
        finally { lock (sync) busy = false; }
    }

    private void Enter()
    {
        if (busy) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        busy = true;
    }
}
