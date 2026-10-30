using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record VoiceLabSnapshot(IReadOnlyList<VoiceConsentRecord> Records,
    IReadOnlyList<VoiceOperation> Operations, bool SpeakerInstalled = false);
internal enum VoiceLabRequestKind { Subscription, Delete, RemoveLocal, StopLooking }
internal sealed record VoiceLabRequest(VoiceLabRequestKind Kind, string? RecordId = null, Guid? OperationId = null);

internal interface IVoiceLabBackend
{
    bool Enabled { get; }
    Task<VoiceLabSnapshot> ReadAsync(CancellationToken ct);
    Task ReconcileAsync(bool force, CancellationToken ct);
    Task PersistProviderConsentAsync(CancellationToken ct);
    Task<VoiceLabSubscription> DiscoverSubscriptionAsync(bool refreshVerification, CancellationToken ct);
    Task DeleteAsync(string recordId, CancellationToken ct);
    Task RemoveLocalAsync(string recordId, CancellationToken ct);
    Task WithdrawAsync(string recordId, CancellationToken ct);
    Task SaveAsync(VoiceConsentRecord record, CancellationToken ct);
    Task RemoveSpeakerAsync(CancellationToken ct);
    Task StopLookingAsync(Guid operationId, CancellationToken ct);
}

internal sealed class VoiceLabSession(IVoiceLabBackend backend, Func<Action, Task> dispatch,
    TimeProvider? timeProvider = null) : IDisposable
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private CancellationTokenSource lifetime = new();
    private CancellationTokenSource? recovery;
    private bool disposed;
    private bool loading;
    private bool forceRecoveryPending;
    private int generation;
    internal event EventHandler? Changed;
    internal bool Enabled => !disposed && backend.Enabled;
    internal IReadOnlyList<VoiceConsentRecord> Records { get; private set; } = [];
    internal IReadOnlyList<VoiceOperation> Operations { get; private set; } = [];
    internal IReadOnlySet<string> Deleting { get; private set; } = new HashSet<string>();
    internal VoiceLabSubscription? Subscription { get; private set; }
    internal VoiceLabRequest? Confirmation { get; private set; }
    internal VoiceConsentRecord? UnsavedRecord { get; private set; }
    internal string? Message { get; private set; }
    internal bool Busy { get; private set; }
    internal Task CreationRecovery { get; private set; } = Task.CompletedTask;
    internal bool SpeakerInstalled { get; private set; }
    internal IReadOnlyList<VoiceConsentRecord> VisibleRecords => Records.Where(record => record.VoiceId != "pending" &&
        !Operations.Any(operation => operation.RecordId == record.RecordId && operation.Kind == VoiceOperationKind.Create && !operation.Finished) &&
        (record.Status != VoiceConsentStatus.Deleted || Deleting.Contains(record.RecordId))).ToArray();
    internal IReadOnlyList<VoiceOperation> PendingCreations => Operations.Where(operation => operation.BlocksCreation(clock.GetUtcNow())).ToArray();
    internal string? PlanMessage => Subscription is null ? "Check your ElevenLabs account before creating a voice."
        : !Subscription.CanClone ? "Instant voice cloning needs an ElevenLabs Starter plan or higher."
        : Subscription.VoiceSlotsUsed >= Subscription.VoiceLimit ? "Your ElevenLabs account has no free voice slots." : null;
    internal string SpeakerMessage => VoiceLabCopy.SpeakerUnavailable;
    internal string CreateBlockedReason => VoiceLabCopy.SpeakerUnavailable;
    internal static string CardName(VoiceConsentRecord record)
    {
        return VoiceLabActionNames.Created(record.VoiceName, record.CreatedAt);
    }
    private void Notify() => Changed?.Invoke(this, EventArgs.Empty);
    internal void Request(VoiceLabRequest request)
    {
        if (!Enabled || Busy || loading) return;
        if (request.Kind == VoiceLabRequestKind.StopLooking && !Operations.Any(operation => operation.Id == request.OperationId && CanStopLooking(operation))) return;
        Confirmation = request;
    }
    internal static bool CanStopLooking(VoiceOperation operation) => operation.NeedsCreatorRecoveryReview && operation.RecoveryNeedsReview;
    internal async Task RefreshEnabledStateAsync()
    {
        var enabled = false;
        await dispatch(() =>
        {
            enabled = Enabled;
            if (enabled) return;
            generation++;
            recovery?.Cancel();
            lifetime.Cancel();
            lifetime.Dispose();
            lifetime = new();
            Records = []; Operations = []; Deleting = new HashSet<string>();
            Subscription = null; Confirmation = null; Message = null;
            Notify();
        });
        if (enabled) await LoadAsync();
    }
    internal Task ReconcileStartupAsync() => LoadAsync();
    internal async Task LoadAsync(bool recover = true, bool force = false)
    {
        var start = false;
        var version = 0;
        var token = CancellationToken.None;
        await dispatch(() =>
        {
            if (!Enabled || Busy || loading) return;
            if (forceRecoveryPending) { recover = true; force = true; forceRecoveryPending = false; }
            loading = true; start = true; version = generation; token = lifetime.Token;
        });
        if (!start) return;
        try { await ReloadAsync(recover, force, version, token); }
        finally
        {
            var reload = false;
            await dispatch(() => { loading = false; reload = (version != generation || forceRecoveryPending) && Enabled; Notify(); });
            if (reload) await LoadAsync();
        }
    }
    private async Task ReloadAsync(bool recover, bool force, int version, CancellationToken ct)
    {
        try
        {
            if (recover)
            {
                try { await Task.Run(() => backend.ReconcileAsync(force, ct), ct); }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
                catch (Exception)
                {
                    await dispatch(() => { if (Current(version)) Message = VoiceLabCopy.RecoveryFailed; });
                }
            }
            var snapshot = await Task.Run(() => backend.ReadAsync(ct), ct);
            await dispatch(() =>
            {
                if (!Current(version)) return;
                Records = snapshot.Records; Operations = snapshot.Operations; SpeakerInstalled = snapshot.SpeakerInstalled;
                if (recover && !Operations.Any(operation => !operation.Finished && (operation.State == VoiceOperationState.Withdrawing || operation.Failed)) &&
                    (Message == "Removing…" || Message == VoiceLabCopy.RecoveryFailed)) Message = null;
                Deleting = Operations.Where(operation => !operation.Finished &&
                    (operation.Kind == VoiceOperationKind.Delete || operation.State == VoiceOperationState.Withdrawing))
                    .Select(operation => operation.RecordId).ToHashSet(StringComparer.Ordinal);
                Notify();
                ScheduleRecovery();
            });
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception)
        {
            await dispatch(() => { if (Current(version)) { Message = VoiceLabCopy.ReadFailed; Notify(); } });
        }
    }
    internal async Task ApproveAsync(bool approved)
    {
        VoiceLabRequest? request = null;
        var refreshVerification = false;
        await dispatch(() =>
        {
            request = Confirmation; Confirmation = null;
            refreshVerification = Records.Any(record => record.Status == VoiceConsentStatus.VerificationRequired);
        });
        if (!approved || request is null) return;
        await PerformAsync(async ct =>
        {
            switch (request.Kind)
            {
                case VoiceLabRequestKind.Subscription:
                    await backend.PersistProviderConsentAsync(ct);
                    var subscription = await backend.DiscoverSubscriptionAsync(refreshVerification, ct);
                    await dispatch(() => { if (Enabled && !ct.IsCancellationRequested) Subscription = subscription; });
                    break;
                case VoiceLabRequestKind.Delete:
                    await backend.DeleteAsync(request.RecordId!, ct);
                    await SetMessageAsync(VoiceLabCopy.Deleted, ct);
                    break;
                case VoiceLabRequestKind.RemoveLocal:
                    await backend.RemoveLocalAsync(request.RecordId!, ct);
                    await SetMessageAsync(VoiceLabCopy.RemovedLocal, ct);
                    break;
                case VoiceLabRequestKind.StopLooking:
                    if (!Operations.Any(operation => operation.Id == request.OperationId && CanStopLooking(operation))) return;
                    await backend.StopLookingAsync(request.OperationId!.Value, ct);
                    await SetMessageAsync(VoiceLabCopy.StoppedLooking, ct);
                    break;
            }
        });
    }
    internal Task WithdrawOperationAsync(string recordId) => PerformAsync(async ct =>
    {
        await backend.WithdrawAsync(recordId, ct);
        await dispatch(() => { if (!ct.IsCancellationRequested && UnsavedRecord?.RecordId == recordId) UnsavedRecord = null; });
    });
    internal Task RemoveSpeakerAsync() => PerformAsync(ct => backend.RemoveSpeakerAsync(ct));
    internal Task RetryUnsavedAsync() => PerformAsync(async ct =>
    {
        if (UnsavedRecord is not { } record) return;
        await backend.SaveAsync(record, ct);
        await dispatch(() => { if (!ct.IsCancellationRequested) UnsavedRecord = null; });
        await SetMessageAsync("Consent record saved. No create request was repeated.", ct);
    });
    internal void StageUnsaved(VoiceConsentRecord record) { UnsavedRecord = record; Notify(); }
    internal void ClearUnsaved(string recordId) { if (UnsavedRecord?.RecordId == recordId) UnsavedRecord = null; }
    internal async Task CreationReturnedAsync(string text)
    {
        await LoadAsync(recover: false);
        await dispatch(() => { if (Enabled) { Message = text; forceRecoveryPending = true; Notify(); } });
        CreationRecovery = LoadAsync(force: true);
    }
    private Task SetMessageAsync(string text, CancellationToken ct) => dispatch(() => { if (Enabled && !ct.IsCancellationRequested) Message = text; });
    private async Task PerformAsync(Func<CancellationToken, Task> action)
    {
        var start = false;
        var version = 0;
        var token = CancellationToken.None;
        await dispatch(() =>
        {
            if (!Enabled || Busy || loading) return;
            Busy = true; start = true; version = generation; token = lifetime.Token;
            recovery?.Cancel(); Message = null; Notify();
        });
        if (!start) return;
        try { await Task.Run(() => action(token), token); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (VoiceCreatorMismatchException) { await SetMessageAsync(VoiceCreatorMismatchException.Explanation, token); }
        catch (Exception) { await SetMessageAsync("Couldn't finish — Retry", token); }
        finally
        {
            await ReloadAsync(false, false, version, token);
            var reload = false;
            await dispatch(() => { Busy = false; reload = (version != generation || forceRecoveryPending) && Enabled; Notify(); });
            if (reload) await LoadAsync();
        }
    }
    private bool Current(int version) => Enabled && generation == version;
    private void ScheduleRecovery()
    {
        recovery?.Cancel(); recovery?.Dispose(); recovery = null;
        var next = Operations.Where(operation => !operation.Finished && operation.NextAttemptAt.HasValue)
            .Select(operation => operation.NextAttemptAt!.Value).Order().FirstOrDefault();
        if (!Enabled || next == default) return;
        recovery = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var delay = next - clock.GetUtcNow();
        _ = RecoverLaterAsync(delay < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : delay, recovery.Token);
    }
    private async Task RecoverLaterAsync(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Task.Delay(delay, clock, ct);
            if (!ct.IsCancellationRequested) await LoadAsync();
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; generation++; recovery?.Cancel(); recovery?.Dispose();
        lifetime.Cancel(); lifetime.Dispose();
    }
}
