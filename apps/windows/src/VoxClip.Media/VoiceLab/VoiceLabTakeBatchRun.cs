using VoxClip.Core.Domain.VoiceLab;
#pragma warning disable CS1591

namespace VoxClip.Media.VoiceLab;

/// <summary>Source-ordered window runs prepared and pinned under one approval. A failed launch or fatal end discards the remainder.</summary>
public sealed class VoiceLabTakeBatchRun(IReadOnlyList<VoiceLabTakeRun> runs)
{
    public IReadOnlyList<VoiceLabTakeRun> Runs { get; } = Array.AsReadOnly(runs.ToArray());
    public async Task<VoiceLabTakeBatch> PrepareAsync(IReadOnlyList<VoiceLabTakeInput> inputs, Guid? id = null, CancellationToken ct = default)
    {
        if (inputs.Count != Runs.Count) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        VoiceLabTakeBatch.Validate(inputs);
        List<VoiceLabTakeBatch.Window> windows = [];
        try
        {
            for (int index = 0; index < Runs.Count; index++)
                windows.Add(new(inputs[index], await Runs[index].PrepareAsync(inputs[index], ct).ConfigureAwait(false)));
            return new(windows, id);
        }
        catch
        {
            foreach (var run in Runs.Take(windows.Count)) await run.CancelAsync(keepingTakes: true).ConfigureAwait(false);
            throw;
        }
    }
    public async Task ApproveAsync(VoiceLabTakeBatch batch)
    {
        if (batch.Windows.Count != Runs.Count) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        try
        {
            for (int index = 0; index < Runs.Count; index++) await Runs[index].ApproveAsync(batch.Windows[index].Quote).ConfigureAwait(false);
        }
        catch { await DiscardAsync(0).ConfigureAwait(false); throw; }
    }
    public async Task<VoiceLabTakeRunResult> ExecuteAsync(VoiceLabTakeBatch batch, int window,
        Func<IReadOnlyList<VoiceLabTakeRow>, Task>? progress = null, CancellationToken ct = default)
    {
        if (batch.Windows.Count != Runs.Count || window < 0 || window >= Runs.Count) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
        VoiceLabTakeRunResult result;
        try { result = await Runs[window].ExecuteAsync(batch.Windows[window].Quote, true, progress, ct).ConfigureAwait(false); }
        catch { await DiscardAsync(window).ConfigureAwait(false); throw; }
        if (result.End is not (VoiceLabTakeRunEnd.Completed or VoiceLabTakeRunEnd.EarlyStop)) await DiscardAsync(window).ConfigureAwait(false);
        return result;
    }
    public async Task DiscardAsync(int from)
    {
        foreach (var run in Runs.Skip(Math.Max(0, from))) await run.CancelAsync(keepingTakes: true).ConfigureAwait(false);
    }
}
