using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record WholeClipSelection(Project Edited, WholeClipRevoicePlan? Plan, WholeClipVoiceRecovery Recovery,
    int Revision, IReadOnlyList<EditOperation> Operations)
{
    internal string ClipId => Recovery.ClipId;
    internal string RecordId => Recovery.RecordId;
    internal string Identity => Recovery.Identity;
}

internal sealed record WholeClipOffer(WholeClipSelection Selection, WholeClipLipsync Model, decimal VoicePrice, WholeClipPictureApproval Picture,
    string Disclosure, Func<WholeClipOffer, IProgress<string>, CancellationToken, Task<VoiceLabEditCommand.AcceptWholeClip>> Execute);

internal sealed partial class RewriteSession
{
    private Func<WholeClipSelection, WholeClipLipsync, CancellationToken, Task<WholeClipOffer>>? wholeClipPrice;
    private Func<Project, string, bool, CancellationToken, Task>? wholeClipPreview;
    private Func<string, string, SavedWholeClipVoice?>? wholeClipRestore;
    private Action<string>? wholeClipValidateUse;
    private CancellationTokenSource? wholeClipWork;
    private readonly VoiceLabDispatchGate wholeClipGate = new();
    private WholeClipSelection? wholeClipSelection;
    private WholeClipSelection? sendingWholeClip;
    internal WholeClipOffer? WholeClipPrice { get; private set; }
    internal VoiceLabEditCommand.AcceptWholeClip? WholeClipReview { get; private set; }
    internal SavedWholeClipVoice? WholeClipVoice { get; private set; }
    internal string WholeClipStatus { get; private set; } = "";
    internal bool WholeClipBusy => wholeClipWork is not null;
    internal bool OffersWholeClip => Scope.ClipId is not null && (IncludedHunks.Any(hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice) || WholeClipVoice is not null);
    internal bool CanRestoreWholeClip => wholeClipRestore is not null && Scope.ClipId is not null && GenerationIsCurrent;
    internal string? WholeClipScriptText => WholeClipPrice?.Selection.Recovery.Script ?? wholeClipSelection?.Recovery.Script;
    internal string? WholeClipBlocked => !VoiceSpeakerCheck.WindowsNativeParityVerified ? "The Windows voice check isn't available yet."
        : wholeClipPrice is null || Envelope is null ? "Read the clip's audio before revoicing it."
        : !GenerationIsCurrent ? "The Rewrite or clip changed. Open Rewrite again to continue."
        : IsGeneratingBatch || AutoFix.Work is not null || GenerationWindows.Any(window => window.IsRunning || window.IsPreparing)
            ? "Wait for the other takes to finish."
        : WholeClipVoice is not null && wholeClipSelection is { } saved && !WholeClipCurrent(saved) ? "The clip or voice changed. Go back to the saved voice's settings to continue."
        : WholeClipVoice is null && Generation?.VoiceId is null ? "Check the price for your voice first."
        : null;
    internal bool WholeClipReviewCurrent => wholeClipSelection is { } selection && WholeClipCurrent(selection) && !WholeClipBusy;
    internal bool WholeClipCurrent(WholeClipSelection selection) => GenerationIsCurrent && revision == selection.Revision &&
        (Generation?.VoiceId == selection.RecordId || selection.Plan is null && Generation?.VoiceId is null) &&
        Editor.Project.Edits.ActiveClipId == selection.ClipId && WholeClipBaseKey(Editor.Project, selection.ClipId) == selection.Recovery.BaseKey;
    internal VoiceLabDispatchBinding WholeClipBinding() => wholeClipGate.Capture();
    private static string WholeClipBaseKey(Project project, string clipId) => System.Convert.ToHexStringLower(
        System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(ProjectVoiceTakeIdentity.IdentityKey(project, RewriteScope.Clip(clipId), clipId))));

    internal void ConfigureWholeClip(Func<WholeClipSelection, WholeClipLipsync, CancellationToken, Task<WholeClipOffer>> price,
        Func<string, string, SavedWholeClipVoice?> restore, Action<string> validateUse, Func<Project, string, bool, CancellationToken, Task> preview)
    {
        wholeClipPrice = price;
        wholeClipRestore = restore;
        wholeClipValidateUse = validateUse;
        wholeClipPreview = preview;
    }

    private void CheckWholeClipCurrent()
    {
        if (sendingWholeClip is { } selection && !WholeClipCurrent(selection)) InvalidateWholeClip();
    }

    internal void InvalidateWholeClip()
    {
        wholeClipGate.Invalidate();
        wholeClipWork?.Cancel();
        WholeClipPrice = null;
    }

    internal void KeepWholeClipVoice(WholeClipSelection selection, SavedWholeClipVoice saved)
    {
        wholeClipSelection = selection;
        WholeClipVoice = saved;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    internal Task PriceWholeClipAsync(WholeClipLipsync model) => WorkWholeClipAsync(async (progress, ct) =>
    {
        if (WholeClipBlocked is not null || wholeClipPrice is null || Scope.ClipId is not { } clipId || Envelope is not { } envelope) return;
        WholeClipPrice = null;
        progress.Report("Checking the whole-clip price…");
        var selection = wholeClipSelection;
        if (selection is null || WholeClipVoice is null || !WholeClipCurrent(selection))
        {
            if (Generation?.VoiceId is not { } recordId) return;
            var basis = Editor.Project;
            var operations = LocalOperations();
            var edited = Editor.ProjectWithLocalOperations(basis, operations);
            var plan = WholeClipRevoicePlan.Create(edited, clipId, envelope, IncludedHunks.Where(hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice).ToArray());
            var identity = plan.Identity(recordId, edited.Media.Source.ContentKey, synthesisModel, edited.Edits.PauseThresholdSeconds);
            selection = new(edited, plan, new(WholeClipBaseKey(basis, clipId), identity, clipId, recordId, plan.Script.Text), revision, operations);
        }
        var quote = await wholeClipPrice(selection, model, ct);
        if (!WholeClipCurrent(selection)) return;
        WholeClipPrice = quote;
        WholeClipStatus = "";
    });

    internal Task RestoreWholeClipAsync() => WorkWholeClipAsync((_, _) =>
    {
        if (!CanRestoreWholeClip || Scope.ClipId is not { } clipId) return Task.CompletedTask;
        var basis = Editor.Project;
        var saved = wholeClipRestore?.Invoke(basis.Id, WholeClipBaseKey(basis, clipId));
        if (saved?.Recovery is not { } info || info.ClipId != clipId || saved.SegmentIds.Any(id => basis.VoiceLab.Segments.Any(segment => segment.Id == id)))
        {
            WholeClipStatus = "No unused whole-clip voice matches this clip as edited.";
            return Task.CompletedTask;
        }
        if (Generation?.VoiceId is { } selected && selected != info.RecordId)
        {
            WholeClipStatus = "Choose the voice the saved clip was made with. Nothing was sent.";
            return Task.CompletedTask;
        }
        var savedEdits = ProjectVoiceTakeIdentity.RewriteInputs(saved.Draft, RewriteScope.Clip(clipId), clipId).Edits;
        var addedCuts = savedEdits.CutWordIds.Except(basis.Edits.CutWordIds, StringComparer.Ordinal).ToArray();
        List<EditOperation> operations = [];
        if (addedCuts.Length > 0) operations.Add(new EditOperation.SetWordCuts(addedCuts, true));
        foreach (var (id, text) in savedEdits.Corrections)
            if (basis.Edits.Corrections.GetValueOrDefault(id) != text) operations.Add(new EditOperation.Correct(id, text));
        var edited = Editor.ProjectWithLocalOperations(basis, operations);
        KeepWholeClipVoice(new(edited, null, info, revision, operations), saved);
        WholeClipStatus = "Your voice is saved. Play it before continuing lip sync.";
        return Task.CompletedTask;
    });

    internal Task MakeWholeClipAsync() => WorkWholeClipAsync(async (progress, ct) =>
    {
        if (WholeClipPrice is not { } price || WholeClipBlocked is not null || !WholeClipCurrent(price.Selection)) return;
        WholeClipPrice = null;
        sendingWholeClip = price.Selection;
        var result = await price.Execute(price, progress, ct);
        if (!WholeClipCurrent(price.Selection)) return;
        wholeClipSelection = price.Selection;
        WholeClipReview = result;
        WholeClipStatus = "Lip sync is ready. Compare it with the original before you use it.";
    });

    internal Task PlayWholeClipAsync(bool original, bool voiceOnly = false) => WorkWholeClipAsync(async (_, ct) =>
    {
        if (wholeClipSelection is not { } selection || !WholeClipCurrent(selection) || wholeClipPreview is null) return;
        var clipId = selection.ClipId;
        var edited = Editor.ProjectWithLocalOperations(Editor.Project, selection.Operations);
        if (original) await wholeClipPreview(Editor.Project, clipId, false, ct);
        else if (!voiceOnly && WholeClipReview is { } result) await wholeClipPreview(result.ApplyingTo(edited), clipId, false, ct);
        else if (WholeClipVoice is { } saved)
            await wholeClipPreview(WholeClipRevoiceDraft.Voice(edited, clipId, saved.Voice(selection.RecordId)), clipId, true, ct);
    });

    internal void ApplyWholeClip(bool voiceOnly)
    {
        if (!WholeClipReviewCurrent || wholeClipSelection is not { } selection || Scope.ClipId is not { } clipId) return;
        try { wholeClipValidateUse?.Invoke(selection.RecordId); }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            WholeClipStatus = "Consent for the saved voice couldn't be verified. Your paid work is saved.";
            Changed?.Invoke(this, EventArgs.Empty);
            return;
        }
        bool applied;
        if (!voiceOnly && WholeClipReview is { } result)
            applied = Editor.ApplyVoiceLab(result, Editor.Project, selection.Operations);
        else if (WholeClipVoice is { } saved)
            applied = Editor.ApplyVoiceLab(new VoiceLabEditCommand.AcceptWholeClipVoice(saved.Voice(selection.RecordId), clipId), Editor.Project, selection.Operations);
        else return;
        if (applied) Dispose();
        else { WholeClipStatus = "This take can't go into the clip as edited. Your paid work is saved."; Changed?.Invoke(this, EventArgs.Empty); }
    }

    private async Task WorkWholeClipAsync(Func<IProgress<string>, CancellationToken, Task> work)
    {
        if (WholeClipBusy || !IsOpen) return;
        using var token = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        wholeClipWork = token;
        var progress = new Progress<string>(line =>
        {
            if (!ReferenceEquals(wholeClipWork, token) || token.IsCancellationRequested) return;
            WholeClipStatus = line;
            Changed?.Invoke(this, EventArgs.Empty);
        });
        Changed?.Invoke(this, EventArgs.Empty);
        try { await work(progress, token.Token); }
        catch (OperationCanceledException) { WholeClipStatus = "Stopped. Any paid voice and lip sync are saved."; }
        catch (FalLipsyncException error)
        {
            WholeClipStatus = error.Code switch
            {
                FalLipsyncError.MissingKey => "Add a fal.ai key in Settings → Providers & Keys to lip sync the clip.",
                FalLipsyncError.ApprovalRequired => "The lip-sync price or account changed. Check the price again. Your voice is saved if it was made.",
                FalLipsyncError.SubmissionUnconfirmed => "fal.ai may have accepted the request. Check your fal.ai account. VoxClip won't send it again.",
                _ => "fal.ai couldn't finish the lip sync. Your voice and any paid picture are saved.",
            };
        }
        catch (VoiceLabException error) { WholeClipStatus = error.Detail ?? "The voice step couldn't finish. Any paid takes are saved."; }
        catch (RewriteGenerationException error) { WholeClipStatus = error.Message; }
        catch (Exception error) when (error is not OutOfMemoryException)
        { WholeClipStatus = "Whole-clip revoice couldn't finish. Your edits and any paid work are saved."; }
        finally { sendingWholeClip = null; wholeClipWork = null; Changed?.Invoke(this, EventArgs.Empty); }
    }
}
