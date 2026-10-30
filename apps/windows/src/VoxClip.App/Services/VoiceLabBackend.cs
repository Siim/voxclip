using VoxClip.App.ViewModels;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.Services;

internal interface IVoiceLabAccount : IDisposable
{
    Task<VoiceLabSubscription> DiscoverSubscriptionAsync(CancellationToken ct);
    Task<IReadOnlyList<VoiceLabVoice>> DiscoverVoicesAsync(CancellationToken ct);
    Task DeleteAsync(string recordId, CancellationToken ct);
}

internal sealed class VoiceLabBackend(DataLocations data, IKeyProvider keys, ILog log,
    Func<bool> enabled, Func<ElevenLabsRegion> region, Func<CancellationToken, Task> persistConsent,
    TimeProvider? timeProvider = null, Func<ElevenLabsRegion, IVoiceLabAccount>? accountFactory = null) : IVoiceLabBackend
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly VoiceConsentStore store = new(data, timeProvider);
    public bool Enabled => enabled();
    private void RequireEnabled(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Enabled) throw new VoiceLabException(VoiceLabErrorKind.ConsentRequired);
    }
    public Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct)
    {
        RequireEnabled(ct);
        var installed = false;
        try { new SpeakerModelCatalog().Entry.VerifiedFiles(SpeakerDirectory()); installed = true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceConsentException) { }
        return Task.FromResult(new VoiceLabSnapshot(store.Records(), store.Operations(), installed));
    }
    private string SpeakerDirectory() => Path.Combine(data.Models, new SpeakerModelCatalog().Entry.Id);
    public Task PersistProviderConsentAsync(CancellationToken ct)
    {
        RequireEnabled(ct);
        return persistConsent(ct);
    }
    private ElevenLabsVoiceLab Client(ElevenLabsRegion selected, CancellationToken ct)
    {
        RequireEnabled(ct);
        return new(keys, selected, log);
    }
    private IVoiceLabAccount Account(CancellationToken ct)
    {
        RequireEnabled(ct);
        return accountFactory?.Invoke(region()) ?? new AccountClient(Client(region(), ct), store, clock, () => RequireEnabled(ct));
    }
    public async Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct)
    {
        using var client = Account(ct);
        var subscription = await client.DiscoverSubscriptionAsync(ct).ConfigureAwait(false);
        if (refreshVerification)
        {
            RequireEnabled(ct);
            var voices = await client.DiscoverVoicesAsync(ct).ConfigureAwait(false);
            store.RefreshVerification(voices);
        }
        return subscription;
    }
    public async Task DeleteAsync(string recordId, CancellationToken ct)
    {
        using var client = Account(ct);
        await client.DiscoverVoicesAsync(ct).ConfigureAwait(false);
        RequireEnabled(ct);
        await client.DeleteAsync(recordId, ct).ConfigureAwait(false);
    }
    public async Task RemoveLocalAsync(string recordId, CancellationToken ct)
    {
        RequireEnabled(ct);
        var operation = store.BeginLocalRemoval(recordId, true, clock.GetUtcNow());
        var reconciler = new VoiceOperationReconciler(store, _ => throw new InvalidOperationException("Local removal must not use a client."), clock);
        await reconciler.ReconcileAsync(operation.Id, true, ct).ConfigureAwait(false);
    }
    public async Task WithdrawAsync(string recordId, CancellationToken ct)
    {
        RequireEnabled(ct);
        store.WithdrawCreation(recordId, clock.GetUtcNow());
        await ReconcileAsync(true, ct).ConfigureAwait(false);
    }
    public async Task SaveAsync(VoiceConsentRecord record, CancellationToken ct)
    {
        RequireEnabled(ct); store.Save(record);
        await ReconcileAsync(true, ct).ConfigureAwait(false);
    }
    public Task RemoveSpeakerAsync(CancellationToken ct)
    {
        RequireEnabled(ct);
        var directory = SpeakerDirectory();
        if (Directory.Exists(directory))
        {
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("The model directory is a link.");
            Directory.Delete(directory, true);
        }
        return Task.CompletedTask;
    }
    public async Task ReconcileAsync(bool force, CancellationToken ct)
    {
        RequireEnabled(ct);
        store.ReconcileAbandonedEnrollments();
        if (!store.Operations().Any(operation => !operation.Finished)) return;
        var clients = new Dictionary<ElevenLabsRegion, ElevenLabsVoiceLab>();
        try
        {
            var reconciler = new VoiceOperationReconciler(store, selected =>
            {
                RequireEnabled(ct);
                if (!clients.TryGetValue(selected, out var client)) clients.Add(selected, client = Client(selected, ct));
                return client;
            }, clock);
            await reconciler.ReconcileAsync(force: force, ct: ct).ConfigureAwait(false);
        }
        finally { foreach (var client in clients.Values) client.Dispose(); }
    }
    private sealed class AccountClient(ElevenLabsVoiceLab client, VoiceConsentStore store, TimeProvider clock, Action guard) : IVoiceLabAccount
    {
        public Task<VoiceLabSubscription> DiscoverSubscriptionAsync(CancellationToken ct) => client.DiscoverSubscriptionAsync(ct);
        public Task<IReadOnlyList<VoiceLabVoice>> DiscoverVoicesAsync(CancellationToken ct) => client.DiscoverVoicesAsync(ct);
        public Task DeleteAsync(string recordId, CancellationToken ct)
        {
            guard();
            var enrollment = new VoiceEnrollment(store, client, (_, _, _) => throw new InvalidOperationException(), clock: clock);
            return enrollment.DeleteAsync(recordId, approved: true, enabled: true, ct);
        }
        public void Dispose() => client.Dispose();
    }
}
