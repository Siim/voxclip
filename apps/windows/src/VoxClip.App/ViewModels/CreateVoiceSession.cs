using System.Globalization;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Audio;

namespace VoxClip.App.ViewModels;

internal interface IVoiceStatementBackend : IDisposable
{
    bool Enabled { get; }
    bool SpeakerAvailable { get; }
    string? PlanMessage { get; }
    string VerificationCost { get; }
    VoiceConsentStatement Statement(string name, string language, DateOnly date);
    Task SaveStatementAsync(string recordId, MicrophoneTake take, CancellationToken ct);
    Task VerifyAsync(string recordId, VoiceConsentStatement statement, VoiceConsentAttestations attestations, CancellationToken ct);
    Task AbandonAsync(string recordId);
}

internal interface IVoiceStatementCapture : IAsyncDisposable
{
    Task StartAsync(CancellationToken ct);
    Task Completion { get; }
    MicrophoneSnapshot Snapshot { get; }
    MicrophoneTake Stop();
    void Discard();
}

internal enum VoiceCreationLeaveTrigger { Navigation, Back, Escape, Closing }

internal sealed class CreateVoiceSession(IVoiceStatementBackend backend, IVoiceStatementCapture capture,
    Func<Action, Task> dispatch, TimeProvider? timeProvider = null) : IAsyncDisposable
{
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly SemaphoreSlim cleanup = new(1, 1);
    private CancellationTokenSource? operation;
    private Task work = Task.CompletedTask;
    private bool leaving;
    private bool disposed;
    private bool cleanupPending;
    private string? recordId;
    private string displayName = "";
    private string language = "en";
    private bool ownVoice;
    private bool adult;
    private bool ownVideos;
    internal event EventHandler? Changed;
    internal event Action<string>? Announcement;
    internal VoiceConsentStatement? Statement { get; private set; }
    internal string? Message { get; private set; }
    internal MicrophoneError? MicrophoneFailure { get; private set; }
    internal bool Busy { get; private set; }
    internal bool Recording { get; private set; }
    internal bool Activating { get; private set; }
    internal bool HasStatementRecording { get; private set; }
    internal bool Verified { get; private set; }
    internal bool VerificationRequested { get; private set; }
    internal bool HasFailure { get; private set; }
    internal MicrophoneSnapshot Capture => capture.Snapshot;
    internal string VerificationCost => backend.VerificationCost;
    internal bool IsBusyForRestart => Busy || Recording || Activating || HasStatementRecording || cleanupPending || leaving;
    internal IReadOnlyList<string> GateMessages => new[]
    {
        !backend.Enabled ? "Turn on Voice Lab to create your voice." : null,
        !backend.SpeakerAvailable ? VoiceLabCopy.SpeakerUnavailable : null,
        language == "et" ? "Estonian draft — pending the user's review." : null,
        backend.PlanMessage
    }.OfType<string>().ToArray();
    internal string? BlockedReason => GateMessages.FirstOrDefault();
    internal bool InputsEditable => !Busy && !Recording && !Activating && !HasStatementRecording && !Verified && !leaving;
    internal bool CanRecord => !disposed && !Busy && !Recording && !Activating && !Verified && !cleanupPending && !leaving && BlockedReason is null && ownVoice && adult && ownVideos && ValidName();
    internal bool CanVerify => !disposed && !Busy && !Recording && !leaving && HasStatementRecording && !Verified && BlockedReason is null;
    private bool ValidName()
    {
        try { VoiceConsentText.DisplayName(displayName); return true; }
        catch (VoiceConsentException) { return false; }
    }
    private void Notify() => Changed?.Invoke(this, EventArgs.Empty);
    private void Say(string text)
    {
        Message = text;
        if (!Recording) Announcement?.Invoke(text);
    }
    internal void SetInputs(string name, string selectedLanguage, bool own, bool isAdult, bool ownVideosOnly)
    {
        if (!InputsEditable) return;
        displayName = name; language = selectedLanguage == "et" ? "et" : "en";
        ownVoice = own; adult = isAdult; ownVideos = ownVideosOnly;
        Statement = ValidName() ? backend.Statement(displayName, language, DateOnly.FromDateTime(clock.GetLocalNow().DateTime)) : null;
        Message = ValidName() || name.Length == 0 ? null : "Enter a name with 1 to 60 Unicode scalars and no control characters.";
        HasFailure = Message is not null;
        Notify();
    }
    internal Task RecordAsync()
    {
        if (!CanRecord) return Task.CompletedTask;
        operation?.Dispose(); operation = new();
        work = RecordCoreAsync(operation.Token);
        return work;
    }
    private async Task RecordCoreAsync(CancellationToken ct)
    {
        var saved = false;
        Busy = true; MicrophoneFailure = null; VerificationRequested = false; HasFailure = false;
        try
        {
            await DeleteStatementAsync();
            ct.ThrowIfCancellationRequested();
            if (BlockedReason is not null) return;
            recordId = Guid.NewGuid().ToString("D");
            Statement = backend.Statement(displayName, language, DateOnly.FromDateTime(clock.GetLocalNow().DateTime));
            var accepted = Statement;
            Say("Recording. Read the statement aloud."); Notify();
            await Task.Delay(TimeSpan.FromMilliseconds(600), clock, ct);
            ct.ThrowIfCancellationRequested();
            if (BlockedReason is not null) return;
            Activating = true; Notify();
            var started = capture.StartAsync(ct);
            var waiting = ShowWaitingAsync(started, ct);
            await started;
            await dispatch(() => { Activating = false; Recording = true; Busy = false; Message = null; Notify(); });
            await waiting;
            await capture.Completion;
            ct.ThrowIfCancellationRequested();
            if (capture.Snapshot.Failure is { } failure) throw new MicrophoneException(failure);
            var take = capture.Stop();
            await dispatch(() => { Recording = false; Busy = true; Notify(); });
            if (BlockedReason is not null) throw new OperationCanceledException(ct);
            await Task.Run(() => backend.SaveStatementAsync(recordId, take, ct), ct);
            ct.ThrowIfCancellationRequested();
            await dispatch(() =>
            {
                Statement = accepted; HasStatementRecording = true; saved = true;
                Say(string.Create(CultureInfo.InvariantCulture, $"Recording stopped, {take.Mono.Length / (double)take.Rate:0.#} seconds."));
            });
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested || !backend.Enabled) { }
        catch (Exception error)
        {
            await dispatch(() =>
            {
                Recording = false; HasFailure = true;
                MicrophoneFailure = (error as MicrophoneException)?.Error;
                Say(MicrophoneFailure is { } failure ? VoiceLabCopy.MicrophoneFailure(failure)
                    : "Record the statement clearly, in one take lasting 5–30 seconds.");
            });
        }
        finally
        {
            capture.Discard();
            if (!saved) await CleanupAfterFailureAsync();
            await dispatch(() => { Recording = false; Activating = false; Busy = false; Notify(); });
        }
    }
    private async Task ShowWaitingAsync(Task started, CancellationToken ct)
    {
        using var waiting = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var delay = Task.Delay(TimeSpan.FromSeconds(1), clock, waiting.Token);
        if (await Task.WhenAny(started, delay) == started) { waiting.Cancel(); return; }
        await dispatch(() => { if (Activating && !ct.IsCancellationRequested) { Say(VoiceLabCopy.MicrophoneWaiting); Notify(); } });
    }
    internal void StopRecording()
    {
        if (Recording) capture.Stop();
    }
    internal bool RequestVerification()
    {
        VerificationRequested = CanVerify;
        return VerificationRequested;
    }
    internal Task ApproveVerificationAsync(bool approved)
    {
        var requested = VerificationRequested;
        VerificationRequested = false;
        if (!approved || !requested || !CanVerify) return Task.CompletedTask;
        operation?.Dispose(); operation = new();
        work = VerifyCoreAsync(operation.Token);
        return work;
    }
    private async Task VerifyCoreAsync(CancellationToken ct)
    {
        Busy = true; HasFailure = false; Notify();
        try
        {
            var attestations = new VoiceConsentAttestations(ownVoice, adult, ownVideos, clock.GetUtcNow());
            await Task.Run(() => backend.VerifyAsync(recordId!, Statement!, attestations, ct), ct);
            ct.ThrowIfCancellationRequested();
            if (BlockedReason is not null) throw new OperationCanceledException(ct);
            await dispatch(() => { Verified = true; Say("Statement verified. Record your training read-aloud next."); });
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested || !backend.Enabled) { await CleanupAfterFailureAsync(); }
        catch (Exception error)
        {
            await CleanupAfterFailureAsync();
            await dispatch(() => { HasFailure = true; Say(error is VoiceConsentException { Kind: VoiceConsentError.TooManyAttempts }
                ? "Three attempts are allowed per 10 minutes. Please try again later."
                : "That didn't match the statement. Read it again, clearly, in one take."); });
        }
        finally { await dispatch(() => { Busy = false; Notify(); }); }
    }
    private async Task DeleteStatementAsync()
    {
        await cleanup.WaitAsync();
        try
        {
            if (recordId is not null) await Task.Run(() => backend.AbandonAsync(recordId));
            await dispatch(() => { recordId = null; HasStatementRecording = false; Verified = false; cleanupPending = false; });
        }
        finally { cleanup.Release(); }
    }
    private async Task CleanupAfterFailureAsync()
    {
        try { await DeleteStatementAsync(); await dispatch(() => Statement = null); }
        catch (Exception)
        {
            await dispatch(() => { cleanupPending = true; HasFailure = true; Say("The statement recording could not be removed. Retry Stop to finish cleanup."); });
        }
    }
    internal async Task<bool> TryLeaveAsync(VoiceCreationLeaveTrigger trigger, Func<VoiceCreationLeaveTrigger, Task<bool>> confirm)
    {
        if (leaving) return false;
        leaving = true;
        try
        {
            var needsConfirmation = Busy || Recording || Activating || HasStatementRecording || cleanupPending;
            if (needsConfirmation && !await confirm(trigger)) return false;
            return await AbandonAsync();
        }
        finally { leaving = false; Notify(); }
    }
    internal async Task<bool> AbandonAsync()
    {
        operation?.Cancel(); capture.Discard();
        await work;
        await CleanupAfterFailureAsync();
        if (cleanupPending) { Notify(); return false; }
        await dispatch(() => { Statement = null; Message = null; VerificationRequested = false; Notify(); });
        return true;
    }
    internal async Task GateChangedAsync()
    {
        if (!backend.Enabled) await AbandonAsync();
        Notify();
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        if (!await AbandonAsync()) throw new IOException("The statement recording could not be removed.");
        disposed = true; operation?.Dispose();
        await capture.DisposeAsync(); backend.Dispose(); cleanup.Dispose();
    }
}
