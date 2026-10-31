using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Media.Audio;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>With project audio, the confirmation names the project and the whole seconds that passed the speaker match.</summary>
internal sealed record VoiceCreationProject(string Name, long Seconds);
internal sealed record VoiceCreationQuote(VoiceLabCostPresentationResult Cost, object Ticket, VoiceCreationProject? Project = null);
internal sealed class VoiceCreationExpiredException : Exception;
/// <summary>Voice Lab §6.5: (a) spans of the open project's audio, or (b) a fresh read-aloud.</summary>
internal enum VoiceTrainingSource { Project, ReadAloud }
internal enum VoiceProjectAudioState { NoProject, NoTranscript, Finding, Ready, TooLittle, Unreadable }
/// <summary>The editor's open project, offered as training audio; times are read from its source media, never the edit.</summary>
internal sealed record VoiceTrainingProject(string Name, Project Project, string? MediaPath);
/// <summary>An analysed project take: the media and rate to cut from and the §6.5.1 selection.</summary>
internal sealed record VoiceProjectAudio(string Name, string MediaPath, int Rate, VoiceTrainingSpanSelection Selection);

internal interface IVoiceCreationBackend : IVoiceStatementBackend
{
    bool CreationPending { get; }
    Task SaveTrainingAsync(MicrophoneTake take, CancellationToken ct);
    /// <summary>On-device and free: one streamed decode of the take and the §6.5.1 selection. Throws when the audio can't be read.</summary>
    Task<VoiceProjectAudio> AnalyzeProjectAsync(VoiceTrainingProject project, CancellationToken ct);
    /// <summary>Prepares the clone from the read-aloud, or from the project's selected spans when <paramref name="project"/> is set.</summary>
    Task<VoiceCreationQuote> PrepareCreationAsync(string recordId, string name, VoiceProjectAudio? project, CancellationToken ct);
    bool QuoteIsFresh(VoiceCreationQuote quote);
    Task<VoiceConsentRecord> CreateAsync(VoiceCreationQuote quote, CancellationToken ct);
    Task SaveCreationRecordAsync(VoiceConsentRecord record, CancellationToken ct);
}

internal sealed partial class CreateVoiceSession
{
    internal const string ExpiredCopy = "This request expired. Choose Create voice… again. Nothing was sent.";
    internal const string UncertainCopy = "Voice creation may have completed. Reconcile the pending voice in Settings. Do not create it again.";
    internal const string ReadyCopy = "Your voice is ready.";
    internal const string VerificationRequiredCopy = "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back.";
    internal bool TrainingReady { get; private set; }
    internal bool RecordingTraining { get; private set; }
    internal bool ReturnToPane { get; private set; }
    internal string? FocusRecordId { get; private set; }
    internal VoiceConsentRecord? UnsavedRecord { get; private set; }
    internal VoiceCreationQuote? CreationConfirmation { get; private set; }
    internal bool CanTrain => backend is IVoiceCreationBackend { CreationPending: false } && !disposed && Verified &&
        !Busy && !Recording && !Activating && !leaving && !cleanupPending && !ReturnToPane && UnsavedRecord is null && CreationConfirmation is null && BlockedReason is null;
    internal bool CanRecordTraining => CanTrain && TrainingSource == VoiceTrainingSource.ReadAloud;
    internal bool CanCreate => CanTrain && (TrainingSource == VoiceTrainingSource.Project ? CanUseProject : TrainingReady);
    internal string TrainingScript => File.ReadAllText(Path.Combine(VoxClip.Core.Services.Project.SharedResources.ResolveRoot(), "voice-lab", "scripts-" + language + ".txt"));
    internal VoiceTrainingSource TrainingSource { get; private set; } = VoiceTrainingSource.ReadAloud;
    internal VoiceProjectAudioState ProjectAudio { get; private set; }
    internal VoiceProjectAudio? ProjectAnalysis { get; private set; }
    /// <summary>The project's spans failed the speaker match against this statement; only a read-aloud remains.</summary>
    internal bool ProjectMismatch { get; private set; }
    internal bool ProjectOffered => ProjectAudio is not (VoiceProjectAudioState.NoProject or VoiceProjectAudioState.NoTranscript);
    internal bool CanUseProject => ProjectAudio == VoiceProjectAudioState.Ready && !ProjectMismatch;
    internal bool CanSelectProject => ProjectAudio is VoiceProjectAudioState.Finding or VoiceProjectAudioState.Ready && !ProjectMismatch;
    internal string ProjectLine => ProjectAudio switch
    {
        VoiceProjectAudioState.NoProject => VoiceLabCopy.NoProject,
        VoiceProjectAudioState.NoTranscript => VoiceLabCopy.NoTranscript,
        VoiceProjectAudioState.Finding => VoiceLabCopy.ProjectFinding(project!.Name),
        VoiceProjectAudioState.Ready => VoiceLabCopy.ProjectFound(ProjectAnalysis!.Selection.AvailableMs / 1000, ProjectAnalysis.Name),
        VoiceProjectAudioState.TooLittle => VoiceLabCopy.ProjectTooLittle(ProjectAnalysis!.Selection.AvailableMs / 1000),
        _ => VoiceLabCopy.ProjectUnreadable
    };

    /// <summary>Opens the sheet with the editor's project, or none. A project with a transcript is the default source (§6.5.2), and its
    /// on-device analysis starts at once unless Voice Lab or the speaker check is closed.</summary>
    internal void OpenProject(VoiceTrainingProject? opened)
    {
        if (project is not null || disposed) return;
        project = opened;
        ProjectAudio = opened is null ? VoiceProjectAudioState.NoProject
            : opened.Project.Transcript is null ? VoiceProjectAudioState.NoTranscript : VoiceProjectAudioState.Finding;
        TrainingSource = ProjectAudio == VoiceProjectAudioState.Finding ? VoiceTrainingSource.Project : VoiceTrainingSource.ReadAloud;
        StartProjectAnalysis();
        Notify();
    }
    private void StartProjectAnalysis()
    {
        if (ProjectAudio != VoiceProjectAudioState.Finding || analysis is not null || disposed || !backend.Enabled || !backend.SpeakerAvailable ||
            backend is not IVoiceCreationBackend creation) return;
        analysis = new();
        analyzing = AnalyzeProjectCoreAsync(creation, project!, analysis.Token);
    }
    private async Task AnalyzeProjectCoreAsync(IVoiceCreationBackend creation, VoiceTrainingProject opened, CancellationToken ct)
    {
        VoiceProjectAudio? result = null;
        try { result = await Task.Run(() => creation.AnalyzeProjectAsync(opened, ct), ct); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
        catch (Exception) { }
        if (ct.IsCancellationRequested) return;
        await dispatch(() =>
        {
            ProjectAnalysis = result;
            ProjectAudio = result is null ? VoiceProjectAudioState.Unreadable
                : result.Selection.Status == VoiceTrainingSpanStatus.Ok ? VoiceProjectAudioState.Ready : VoiceProjectAudioState.TooLittle;
            if (ProjectAudio != VoiceProjectAudioState.Ready && TrainingSource == VoiceTrainingSource.Project) TrainingSource = VoiceTrainingSource.ReadAloud;
            Notify();
        });
    }
    internal bool CanChooseSource => CanTrain;
    /// <summary>The source picker and the speaker block's Record a Read-Aloud; the verified statement is kept.</summary>
    internal void SelectTrainingSource(VoiceTrainingSource source)
    {
        if (CanChooseSource && source != TrainingSource && (source == VoiceTrainingSource.ReadAloud || CanSelectProject))
        {
            TrainingSource = source;
            if (ProjectMismatch) { Message = null; HasFailure = false; }
        }
        Notify();
    }
    private void ResetTrainingSource()
    {
        ProjectMismatch = false;
        if (ProjectAudio is VoiceProjectAudioState.Finding or VoiceProjectAudioState.Ready) TrainingSource = VoiceTrainingSource.Project;
    }
    private async Task StopProjectAnalysisAsync()
    {
        analysis?.Cancel();
        try { await analyzing; }
        catch (OperationCanceledException) { }
        analysis?.Dispose();
    }

    internal Task RecordTrainingAsync()
    {
        if (!CanRecordTraining) return Task.CompletedTask;
        operation?.Dispose(); operation = new();
        work = RecordTrainingCoreAsync((IVoiceCreationBackend)backend, operation.Token);
        return work;
    }
    private async Task RecordTrainingCoreAsync(IVoiceCreationBackend creation, CancellationToken ct)
    {
        Busy = true; Activating = true; TrainingReady = false; RecordingTraining = true; HasFailure = false; Message = null; Notify();
        try
        {
            var started = capture.StartTrainingAsync(ct);
            var waiting = ShowWaitingAsync(started, ct);
            await started;
            await dispatch(() => { Activating = false; Recording = true; Busy = false; Notify(); });
            await waiting; await capture.Completion;
            ct.ThrowIfCancellationRequested();
            if (capture.Snapshot.Failure is { } failure) throw new MicrophoneException(failure);
            var take = capture.Stop();
            await dispatch(() => { Recording = false; Busy = true; Notify(); });
            if (BlockedReason is not null) throw new OperationCanceledException(ct);
            await Task.Run(() => creation.SaveTrainingAsync(take, ct), ct);
            ct.ThrowIfCancellationRequested();
            await dispatch(() => { TrainingReady = true; Say("Training recording is ready."); });
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested || !backend.Enabled) { }
        catch (Exception error)
        {
            await dispatch(() => { TrainingReady = false; HasFailure = true; MicrophoneFailure = (error as MicrophoneException)?.Error;
                Say(MicrophoneFailure is { } failure ? VoiceLabCopy.MicrophoneFailure(failure) : "Record 5–30 seconds for consent, or 60–90 seconds for the training read-aloud, with clear speech."); });
        }
        finally
        {
            capture.Discard();
            await dispatch(() => { Recording = false; RecordingTraining = false; Activating = false; Busy = false; Notify(); });
        }
    }
    internal Task PrepareCreationAsync()
    {
        if (!CanCreate) return Task.CompletedTask;
        operation?.Dispose(); operation = new();
        work = PrepareCreationCoreAsync((IVoiceCreationBackend)backend, operation.Token);
        return work;
    }
    private async Task PrepareCreationCoreAsync(IVoiceCreationBackend creation, CancellationToken ct)
    {
        var selected = TrainingSource == VoiceTrainingSource.Project ? ProjectAnalysis : null;
        Busy = true; HasFailure = false; Message = null; Notify();
        try
        {
            var quote = await Task.Run(() => creation.PrepareCreationAsync(recordId!, displayName, selected, ct), ct);
            ct.ThrowIfCancellationRequested();
            await dispatch(() => { if (BlockedReason is null && !creation.CreationPending) CreationConfirmation = quote; });
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested || !backend.Enabled) { }
        catch (VoiceConsentException error) when (selected is not null && error.Kind == VoiceConsentError.SpeakerMismatch)
        {
            await dispatch(() => { ProjectMismatch = true; HasFailure = true; Say(VoiceLabCopy.ProjectMismatch); });
        }
        catch (VoiceLabSourceAudioException) when (selected is not null)
        {
            await dispatch(() =>
            {
                ProjectAudio = VoiceProjectAudioState.Unreadable; TrainingSource = VoiceTrainingSource.ReadAloud;
                HasFailure = true; Say(VoiceLabCopy.ProjectUnreadable);
            });
        }
        catch (Exception error) { await dispatch(() => CreationError(error)); }
        finally { await dispatch(() => { Busy = false; Notify(); }); }
    }
    internal Task ApproveCreationAsync(bool approved)
    {
        var quote = CreationConfirmation; CreationConfirmation = null;
        if (!approved || quote is null || !CanCreate) { Notify(); return Task.CompletedTask; }
        operation?.Dispose(); operation = new();
        work = CreateCoreAsync((IVoiceCreationBackend)backend, quote, operation.Token);
        return work;
    }
    private async Task CreateCoreAsync(IVoiceCreationBackend creation, VoiceCreationQuote quote, CancellationToken ct)
    {
        Busy = true; HasFailure = false; Notify();
        try
        {
            if (!creation.QuoteIsFresh(quote)) throw new VoiceCreationExpiredException();
            var record = await Task.Run(() => creation.CreateAsync(quote, ct), ct);
            await dispatch(() => FinishCreation(record.RecordId, record.Status == VoiceConsentStatus.VerificationRequired ? VerificationRequiredCopy : ReadyCopy));
        }
        catch (VoiceConsentSaveException error)
        {
            await dispatch(() => { UnsavedRecord = error.Record; TrainingReady = false; HasFailure = true;
                Say($"ElevenLabs created voice {error.Record.VoiceId}, but the local consent record could not be saved. Retry saving or Remove This Voice. Do not create the voice again."); });
        }
        catch (VoiceConsentException error) when (error.Kind == VoiceConsentError.CreationPending)
        {
            await dispatch(() => FinishCreation(recordId!, UncertainCopy));
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested || !backend.Enabled) { }
        catch (Exception error) { await dispatch(() => CreationError(error)); }
        finally { capture.Discard(); await dispatch(() => { Busy = false; Notify(); }); }
    }
    private void FinishCreation(string focusId, string text)
    {
        FocusRecordId = focusId; TrainingReady = false; Verified = false; HasStatementRecording = false;
        ReturnToPane = true; Say(text);
    }
    private void CreationError(Exception error)
    {
        HasFailure = true;
        Say(error switch
        {
            VoiceCreationExpiredException => ExpiredCopy,
            VoiceConsentException { Kind: VoiceConsentError.SpeakerMismatch } => "Some of these recordings don't sound like the voice in your consent statement.",
            VoiceConsentException { Kind: VoiceConsentError.SpeakerUnavailable } => "The speaker check isn't available yet. Your voice can't be created until it is.",
            VoiceLabException { Kind: VoiceLabErrorKind.PlanUnavailable } => "Instant voice cloning needs an ElevenLabs Starter plan or higher.",
            VoiceLabException { Kind: VoiceLabErrorKind.NoVoiceSlots } => "Your ElevenLabs account has no free voice slots.",
            _ => "Couldn't finish — Retry"
        });
    }
    internal Task RetrySavingRecordAsync()
    {
        if (UnsavedRecord is not { } record || Busy || leaving) return Task.CompletedTask;
        operation?.Dispose(); operation = new();
        work = RetrySavingCoreAsync((IVoiceCreationBackend)backend, record, operation.Token);
        return work;
    }
    private async Task RetrySavingCoreAsync(IVoiceCreationBackend creation, VoiceConsentRecord record, CancellationToken ct)
    {
        Busy = true; Notify();
        try
        {
            await Task.Run(() => creation.SaveCreationRecordAsync(record, ct), ct);
            await dispatch(() => { UnsavedRecord = null; FinishCreation(record.RecordId, "Consent record saved. No create request was repeated."); });
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception) { await dispatch(() => { HasFailure = true; Say("The consent record still could not be saved. Retry saving or Remove This Voice. Do not create it again."); }); }
        finally { await dispatch(() => { Busy = false; Notify(); }); }
    }
    internal async Task RemoveUnsavedVoiceAsync()
    {
        if (UnsavedRecord is not { } record || Busy || leaving) return;
        if (await AbandonAsync()) { FinishCreation(record.RecordId, "Removing…"); Notify(); }
    }
}
