using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Each voice's speaking-rate calibration across projects (ADR-R43; Mac <c>AppModel.rateCalibrations</c>), by consent record ID:
/// loaded at launch and kept current as takes are measured. Every estimate reads this cache; the store is written in the background.
/// Without a store (a harness launch) it is memory only.</summary>
internal sealed class RateCalibrations(VoiceLabRateCalibrationStore? store, Action<string>? log = null)
{
    private readonly object gate = new();
    private readonly Dictionary<string, VoiceLabVoiceCalibration> cache = new(StringComparer.Ordinal);
    private Task writes = Task.CompletedTask;

    /// <summary>The background writes so far, in order; a later write waits for the earlier ones.</summary>
    internal Task Writes { get { lock (gate) return writes; } }

    /// <summary>Loads the stored calibrations; a take measured while the store was being read is kept.</summary>
    internal async Task LoadAsync(CancellationToken ct = default)
    {
        if (store is null) return;
        var loaded = await store.AllAsync(ct).ConfigureAwait(false);
        lock (gate)
            foreach (var (id, stored) in loaded)
            {
                var merged = stored;
                if (cache.TryGetValue(id, out var current))
                    foreach (var (model, samples) in current.Models)
                        foreach (var sample in samples.Where(sample => merged.Samples(model).All(kept => kept.Id != sample.Id)))
                        {
                            var next = merged.Samples(model).Append(sample).ToArray();
                            merged = merged with { Models = new Dictionary<string, IReadOnlyList<VoiceLabRateSample>>(merged.Models, StringComparer.Ordinal)
                            { [model] = next.Skip(Math.Max(0, next.Length - VoiceLabRateCalibration.VoiceSampleLimit)).ToArray() } };
                        }
                cache[id] = merged;
            }
    }

    /// <summary>The calibration a phrase's estimate starts from: the chosen voice's, else the only stored one's.</summary>
    internal VoiceLabVoiceCalibration? For(string? recordId)
    {
        lock (gate)
        {
            if (!string.IsNullOrEmpty(recordId)) return cache.GetValueOrDefault(recordId);
            return cache.Count == 1 ? cache.Values.First() : null;
        }
    }

    /// <summary>A video's new voice starts from its anchor's measured takes (voice-lab.md §6.13; Mac <c>AppModel.seedRateCalibration</c>):
    /// <see cref="VoicePerVideo.SeededCalibration"/>, in memory now and on disk in the background. Its own takes then replace them. Nothing
    /// happens when the anchor has no calibration or the new voice already has one.</summary>
    internal void Seed(string fromRecordId, string toRecordId)
    {
        if (!VoiceLabRateCalibrationStore.IsValid(fromRecordId) || !VoiceLabRateCalibrationStore.IsValid(toRecordId) || fromRecordId == toRecordId) return;
        lock (gate)
        {
            if (!cache.TryGetValue(fromRecordId, out var anchor) || anchor.Models.Count == 0 || cache.ContainsKey(toRecordId)) return;
            var seeded = VoicePerVideo.SeededCalibration(anchor, toRecordId);
            cache[toRecordId] = seeded;
            if (store is null) return;
            writes = writes.ContinueWith(async _ =>
            {
                try { await store.SaveAsync(seeded).ConfigureAwait(false); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or VoiceLabLengthBudgetException)
                { log?.Invoke("rate calibration seed failed"); }
            }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default).Unwrap();
        }
    }

    /// <summary>One measured take for its voice and model: in memory now, on disk in the background.</summary>
    internal void Record(string recordId, string model, string take, double measured, double estimated)
    {
        if (!VoiceLabRateCalibrationStore.IsValid(recordId)) return;
        lock (gate)
        {
            var current = cache.GetValueOrDefault(recordId) ?? new VoiceLabVoiceCalibration(recordId);
            var next = current.Recording(model, take, measured, estimated);
            if (next.Equals(current)) return;
            cache[recordId] = next;
            if (store is null) return;
            writes = writes.ContinueWith(async _ =>
            {
                try { await store.RecordAsync(recordId, model, take, measured, estimated).ConfigureAwait(false); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or VoiceLabLengthBudgetException)
                { log?.Invoke("rate calibration write failed"); }
            }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default).Unwrap();
        }
    }
}
