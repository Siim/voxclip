using System.Globalization;
using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.Services;

internal sealed class RewriteGenerationBackend : IDisposable
{
    private readonly ElevenLabsVoiceLab client;
    private readonly VoiceConsentStore store;
    private readonly VoiceLabTakeStorage storage;
    private readonly VoiceLabDispatchGate gate = new();
    private readonly Func<bool> current;
    internal VoiceLabTakeRun Runner { get; }
    internal RewriteGenerationBackend(DataLocations data, IKeyProvider keys, ILog log, VoiceLabPriceCatalog prices,
        ElevenLabsRegion region, string projectId, Func<bool> current, Func<Action, Task> onUi, VoiceLabLocalTiming? localTiming = null)
    {
        this.current = current;
        store = new(data);
        client = new(keys, region, log, prices, new VoiceLabSpendLedger(data));
        storage = new(projectId, Path.Combine(data.Root, "VoiceLab"), Path.Combine(data.Root, "VoiceLabScratch"));
        Runner = new(client, store, VoiceSpeakerCheck.Unavailable,
            storage, gate,
            async ct =>
            {
                var valid = false;
                await onUi(() => valid = !ct.IsCancellationRequested && current());
                return valid;
            })
        // A take with no usable provider or word-check timing is timed on device from its own PCM (voice-lab.md §8.5).
        { LocalTiming = localTiming };
    }
    internal async Task<PreparedVoiceLabAsset?> PaidAudioAsync(Guid id, CancellationToken ct)
    {
        RequireCurrent(ct);
        return Runner.PaidAsset(id) is { } asset
            ? await VoiceLabAssets.PreparePaidAsync(asset, storage.ProjectId, storage.PaidRoot, storage.ScratchRoot, ct) : null;
    }
    internal async Task<RewriteGenerationChoices> DiscoverAsync(string language, CancellationToken ct)
    {
        RequireCurrent(ct);
        VoiceSpeakerCheck.Unavailable.ValidateAvailability();
        var models = (await client.DiscoverModelsAsync(ct)).Where(model => model.SpeechRoute is not null && model.Languages.Contains(language)).ToArray();
        RequireCurrent(ct);
        var remote = await client.ListOwnClonesAsync(ct);
        RequireCurrent(ct);
        var voices = store.ActiveVoices().Where(record => record.Language == language &&
            remote.Any(voice => voice.Id == record.VoiceId && (!voice.RequiresVerification || voice.IsVerified)))
            .Select(record => new RewriteVoice(record.RecordId, VoiceLabel(record.VoiceName, record.CreatedAt))).ToArray();
        return new(voices, models);
    }
    internal static string VoiceLabel(string name, DateTimeOffset date) =>
        name + " · consent " + date.ToString("MMM d", CultureInfo.InvariantCulture);
    private void RequireCurrent(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!current()) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
    public void Dispose() { gate.Invalidate(); client.Dispose(); }
}
