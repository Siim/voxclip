using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
#pragma warning disable CS1591

namespace VoxClip.Core.Services.VoiceLab;

public sealed class VoiceOperationReconciler
{
    private readonly VoiceConsentStore store;
    private readonly Func<ElevenLabsRegion, ElevenLabsVoiceLab> clients;
    private readonly TimeProvider clock;
    public VoiceOperationReconciler(VoiceConsentStore store, Func<ElevenLabsRegion, ElevenLabsVoiceLab> clients, TimeProvider? clock = null)
    {
        this.store = store;
        this.clients = clients;
        this.clock = clock ?? TimeProvider.System;
    }
    public async Task ReconcileAsync(Guid? operationId = null, bool force = false, CancellationToken ct = default)
    {
        await store.State.Reconciler.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            store.ReconcileAbandonedEnrollments();
            Exception? failure = null;
            foreach (var snapshot in store.Operations().Where(value => operationId is null || value.Id == operationId))
            {
                ct.ThrowIfCancellationRequested();
                if (!store.Claim(snapshot.Id)) continue;
                try { await ResumeAsync(snapshot.Id, force, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { throw; }
                catch (Exception error)
                {
                    store.ScheduleRetry(snapshot.Id, clock.GetUtcNow());
                    failure = error;
                }
                finally { store.Release(snapshot.Id); }
            }
            if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
        }
        finally { store.State.Reconciler.Release(); }
    }
    private async Task ResumeAsync(Guid id, bool force, CancellationToken ct)
    {
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var value = store.Operation(id);
            switch (value.Kind, value.State)
            {
                case (VoiceOperationKind.Create, VoiceOperationState.Intent):
                    store.Transition(id, VoiceOperationState.Withdrawing, clock.GetUtcNow());
                    break;
                case (VoiceOperationKind.Create, VoiceOperationState.Dispatched):
                    value = store.PreserveAudit(id);
                    store.DiscardStatement(value.RecordId);
                    store.DiscardUnresolvedDraft(value);
                    if (await FindRemoteAsync(value, force, ct).ConfigureAwait(false) is not { } remote) return;
                    store.Transition(id, VoiceOperationState.Withdrawing, clock.GetUtcNow(), remote.Id);
                    break;
                case (VoiceOperationKind.Create, VoiceOperationState.Created):
                    var valid = false;
                    try
                    {
                        var record = store.Load(value.RecordId);
                        valid = record.Status != VoiceConsentStatus.Deleted && VoiceConsentStore.Hash(store.Statement(value.RecordId)) == record.Statement.AudioSha256;
                    }
                    catch (Exception error) when (error is IOException or VoiceConsentException or System.Text.Json.JsonException) { }
                    if (!valid) store.Transition(id, VoiceOperationState.Withdrawing, clock.GetUtcNow());
                    else
                    {
                        store.SaveCreated(value);
                        store.Transition(id, VoiceOperationState.Saved, clock.GetUtcNow());
                    }
                    break;
                case (VoiceOperationKind.Create, VoiceOperationState.Withdrawing):
                    value = store.PreserveAudit(id);
                    store.DiscardStatement(value.RecordId);
                    store.DiscardUnresolvedDraft(value);
                    if (value.RemoteVoiceId is null && value.WasDispatched)
                    {
                        if (await FindRemoteAsync(value, force, ct).ConfigureAwait(false) is not { } found) return;
                        store.Transition(id, VoiceOperationState.Withdrawing, clock.GetUtcNow(), found.Id);
                        break;
                    }
                    if (value.RemoteVoiceId is not null) await Client(value.Region).DeleteOperationAsync(value, ct).ConfigureAwait(false);
                    ct.ThrowIfCancellationRequested();
                    store.Tombstone(value);
                    store.Transition(id, VoiceOperationState.Withdrawn, clock.GetUtcNow());
                    break;
                case (VoiceOperationKind.Delete, VoiceOperationState.Intent):
                    if (!force && value.NextAttemptAt is { } next && clock.GetUtcNow() < next) return;
                    if (!value.RemoteStateUnknown) await Client(value.Region).DeleteOperationAsync(value, ct).ConfigureAwait(false);
                    ct.ThrowIfCancellationRequested();
                    store.Transition(id, VoiceOperationState.RemoteDeleted, clock.GetUtcNow());
                    break;
                case (VoiceOperationKind.Delete, VoiceOperationState.RemoteDeleted):
                    store.DiscardStatement(value.RecordId);
                    store.Transition(id, VoiceOperationState.AudioRemoved, clock.GetUtcNow());
                    break;
                case (VoiceOperationKind.Delete, VoiceOperationState.AudioRemoved):
                    store.Tombstone(value);
                    store.Transition(id, VoiceOperationState.Tombstoned, clock.GetUtcNow());
                    break;
                case (_, VoiceOperationState.Saved or VoiceOperationState.Withdrawn or VoiceOperationState.Tombstoned):
                    store.RemoveOperation(value);
                    return;
                case (_, VoiceOperationState.Abandoned): return;
                default: throw VoiceConsentStore.Invalid();
            }
        }
    }
    private ElevenLabsVoiceLab Client(ElevenLabsRegion region)
    {
        var client = clients(region);
        return client.Region == region ? client : throw VoiceConsentStore.Invalid();
    }
    private async Task<VoiceLabVoice?> FindRemoteAsync(VoiceOperation value, bool force, CancellationToken ct)
    {
        if (!force && value.NextAttemptAt is { } next && clock.GetUtcNow() < next) return null;
        IReadOnlyList<VoiceLabVoice> voices;
        try
        {
            var client = clients(value.Region);
            if (client.Region != value.Region) throw new VoiceCreatorMismatchException();
            voices = await client.ListOwnClonesAsync(new(value.Region, value.CreatorKeyFingerprint), ct).ConfigureAwait(false);
        }
        catch (VoiceCreatorMismatchException)
        {
            store.RequireRecoveryCreatorKey(value.Id, true);
            store.ScheduleRetry(value.Id, clock.GetUtcNow());
            return null;
        }
        store.RequireRecoveryCreatorKey(value.Id, false);
        ct.ThrowIfCancellationRequested();
        var candidates = voices.Where(voice => voice.IsOwner && voice.Category == "cloned").ToArray();
        bool SameName(VoiceLabVoice voice) => value.RemoteNameSha256 is { } hash && VoiceConsentStore.Hash(System.Text.Encoding.UTF8.GetBytes(voice.Name)) == hash;
        var start = DateTimeOffset.FromUnixTimeSeconds(value.StartedAt.ToUnixTimeSeconds());
        var matches = candidates.Where(voice => voice.ConsentRecordId == value.ProviderNonce || voice.ConsentRecordId is null && SameName(voice) &&
            voice.CreatedAt is { } created && created >= start && created <= value.StartedAt.AddHours(24)).ToArray();
        var uncertain = value.RemoteNameSha256 is null && matches.Length == 0 ||
            candidates.Any(voice => SameName(voice) && !matches.Any(match => match.Id == voice.Id));
        if (matches.Length > 1 || uncertain)
        {
            store.RequireRecoveryReview(value.Id);
            store.ScheduleRetry(value.Id, clock.GetUtcNow());
            if (matches.Length > 1) throw VoiceConsentStore.Invalid();
            return null;
        }
        if (value.RecoveryNeedsReview)
        {
            store.ScheduleRetry(value.Id, clock.GetUtcNow());
            return null;
        }
        if (matches.Length == 1) return matches[0];
        if (clock.GetUtcNow() - value.StartedAt >= TimeSpan.FromHours(24))
        {
            store.Tombstone(value);
            store.Transition(value.Id, VoiceOperationState.Abandoned, clock.GetUtcNow());
        }
        else store.ScheduleRetry(value.Id, clock.GetUtcNow());
        return null;
    }
}
