using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Media.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed partial class RewriteSession
{
    private SavedRewriteProposalStore? proposalStore;
    private SavedRewriteProposal? restoredProposal;
    private string? proposalInputs;
    private string? answeredInstruction;
    private bool ownsSavedProposal;
    private bool suppressProposalWrite;
    private int recoverableTakes;
    private string? paidVoice;
    private readonly Dictionary<Guid, decimal> journaledTakes = [];

    internal string? RestoredVoice => RestoredTakesPending > 0 ? restoredProposal?.VoiceRecordId : null;
    internal bool HasRestoredProposal => restoredProposal is not null;
    private bool HasSessionTakes => generationWindows.Any(window => window.HasPaidTakes);
    private int RestoredTakesPending => HasSessionTakes ? 0 : recoverableTakes;
    internal bool CanDiscardPaidProposal => !IsGeneratingBatch && !applyingBatch && AutoFix.Work is null &&
        generationWindows.All(window => !window.IsRunning && !window.IsPreparing);
    internal string? SavedProposalNote => restoredProposal is null ? null : RestoredTakesPending switch
    {
        0 when !HasSessionTakes && restoredProposal.PatchTakes > 0 => "Your Rewrite from before VoxClip closed is back, but its paid takes can't be put back.",
        0 => null,
        _ when RestoredVoice is { } voice && generationWindows.Any(window => window.VoiceId is { } chosen && chosen != voice) =>
            "Your paid takes are kept, but they were made with a different voice. Choose that voice to use them again.",
        1 when restoredProposal.PatchTakes == 1 => "Your paid take from before VoxClip closed is kept: Make Takes uses it again and pays only for the word checks.",
        var count when count == restoredProposal.PatchTakes => $"Your {count} paid takes from before VoxClip closed are kept: Make Takes uses them again and pays only for the word checks.",
        1 => $"1 of your {restoredProposal.PatchTakes} paid takes from before VoxClip closed is kept. Make Takes uses it again and prices new voice for the rest.",
        var count => $"{count} of your {restoredProposal.PatchTakes} paid takes from before VoxClip closed are kept. Make Takes uses them again and prices new voice for the rest.",
    };
    internal string? WaitingInstructionNote => restoredProposal is { } restored && !string.IsNullOrWhiteSpace(Instruction) &&
        Instruction != restored.Instruction && Instruction != "Fix mistakes"
            ? $"“{Instruction}” waits: Rewrite Again asks it, and asks first before your paid work goes." : null;

    internal bool ConfigureSavedProposal(string paidRoot, bool restore = true)
    {
        if (proposalStore is not null) return false;
        proposalStore = new(paidRoot, Project.Id, identityScope, identityClipId);
        Changed += SaveOnChanged;
        if (!restore || ProposalRevision != 0 || proposalStore.Load(Project, DateTimeOffset.UtcNow) is not { } saved) return false;

        var tokens = Source.Where(word => word.Kind == Core.Domain.Shared.WordKind.Word)
            .Sum(word => EditingAlgorithms.SplitWords(word.Text).Count);
        var limit = 0;
        foreach (var change in saved.Changes)
        {
            var hunk = change.Hunk;
            if (hunk.SourceStartIndex < limit || hunk.SourceEndIndex < hunk.SourceStartIndex || hunk.SourceEndIndex > tokens) return false;
            if (hunk.Kind == VoiceLabDiffHunkKind.TextOnly && hunk.SourceWordIds.Count != hunk.CorrectedTexts.Count) return false;
            limit = hunk.SourceEndIndex;
        }
        var originalWords = NewWords;
        scopeHunks = saved.Changes.Select(change => new ScopeRewriteDiff.Hunk(change.Hunk, change.InsertionAfterItemId,
            change.Lines, change.Reasons, change.CheckThis)).ToArray();
        foreach (var (change, index) in saved.Changes.Select((change, index) => (change, index)))
            changeStates[index + 1] = change.State switch { "kept" => TranscriptChangeState.Kept, "excluded" => TranscriptChangeState.Excluded, _ => TranscriptChangeState.Pending };
        fitKept.UnionWith(saved.Kept);
        priceOverrides.UnionWith(saved.PricedAnyway);
        if (saved.OwnWords is not null)
            foreach (var (index, text) in saved.OwnWords.Where(pair => pair.Key >= 0 && pair.Value is not null))
            {
                ownWords[index] = text;
                wordings[index] = PhraseWording.OwnWords;
            }
        NewWords = saved.NewWords ?? originalWords;
        RefreshReview();
        if (Review is null)
        {
            scopeHunks = null;
            changeStates.Clear(); fitKept.Clear(); priceOverrides.Clear(); ownWords.Clear(); wordings.Clear();
            NewWords = originalWords;
            RefreshReview();
            return false;
        }
        Instruction = answeredInstruction = saved.Instruction;
        WordingFitCompleted = true;
        proposalInputs = saved.Inputs;
        restoredProposal = saved;
        ownsSavedProposal = true;
        var requests = VoiceLabTakeJournalSettlement.RecoverableRequests(Project.Id, paidRoot, DateTimeOffset.UtcNow);
        recoverableTakes = Math.Min(saved.PatchTakes, saved.PatchRequests.Distinct().Count(requests.Contains));
        ProposalRevision++;
        return true;
    }

    internal void PaidTakeSaved(Guid request, string voice, decimal? usd)
    {
        if (!IsOpen || proposalStore is null) return;
        suppressProposalWrite = false;
        paidVoice = voice;
        journaledTakes.TryAdd(request, usd ?? 0);
        PersistSavedProposal();
    }

    private void SaveOnChanged(object? sender, EventArgs args) => PersistSavedProposal();

    private void PersistSavedProposal()
    {
        if (!IsOpen || suppressProposalWrite || proposalStore is not { } store || Review is not { Diff.Hunks.Count: > 0 } review) return;
        var paidRows = generationWindows.SelectMany(window => window.Rows).Where(row => row.AcceptedRequestIds.Count > 0).ToArray();
        if (restoredProposal is null && paidRows.Length == 0 && journaledTakes.Count == 0) return;
        var changes = review.Diff.Hunks.Select((hunk, index) =>
        {
            var meta = scopeHunks?.ElementAtOrDefault(index);
            var state = changeStates.GetValueOrDefault(index + 1) switch
            { TranscriptChangeState.Kept => "kept", TranscriptChangeState.Excluded => "excluded", _ => "pending" };
            return new SavedRewriteChange(hunk, meta?.InsertionAfterItemId, meta?.CheckThis ?? false, meta?.Lines ?? [], meta?.Reasons ?? [], state);
        }).ToArray();
        var requests = journaledTakes.Keys.Concat(restoredProposal?.PatchRequests ?? [])
            .Concat(paidRows.Select(row => row.Receipt?.ActionId).OfType<Guid>()).Distinct().Order().ToArray();
        var restoredRequests = restoredProposal?.PatchRequests.ToHashSet() ?? [];
        var rowsUsd = paidRows.Sum(row => row.Quote?.PricedActions.Where(action => row.AcceptedRequestIds.Contains(action.Id) &&
            !restoredRequests.Contains(action.Id) && !journaledTakes.ContainsKey(action.Id)).Sum(action => action.Estimate.Usd ?? 0) ?? 0);
        var typed = ownWords.Where(pair => Wording(pair.Key) == PhraseWording.OwnWords).OrderBy(pair => pair.Key)
            .ToDictionary(pair => pair.Key, pair => pair.Value);
        try
        {
            store.Save(new(proposalInputs ??= store.Inputs(Project), answeredInstruction ?? Instruction, changes, fitKept.Order().ToArray(),
                priceOverrides.Order().ToArray(), paidVoice ?? restoredProposal?.VoiceRecordId ?? Generation?.VoiceId,
                Math.Max(requests.Length, Math.Max(restoredProposal?.PatchTakes ?? 0, paidRows.Length)),
                (restoredProposal?.PatchUsd ?? 0) + journaledTakes.Values.Sum() + rowsUsd, requests, NewWords, typed.Count == 0 ? null : typed), DateTimeOffset.UtcNow);
            ownsSavedProposal = true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or VoiceConsentException or VoiceLabException)
        { UiError.WriteFailure(error, "Rewrite proposal save"); }
    }

    internal void ForgetSavedProposal()
    {
        if (ownsSavedProposal)
        {
            try { proposalStore?.Remove(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { UiError.WriteFailure(error, "Rewrite proposal discard"); }
        }
        ownsSavedProposal = false;
        suppressProposalWrite = true;
        restoredProposal = null;
        proposalInputs = null;
        recoverableTakes = 0;
        paidVoice = null;
        journaledTakes.Clear();
    }

    internal bool DiscardForAnotherProposal()
    {
        if (!IsOpen || !CanDiscardPaidProposal) return false;
        RetireGenerationWindows();
        ForgetSavedProposal();
        ReconcileGenerationWindows();
        KeepWorking();
        return true;
    }
}
