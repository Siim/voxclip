using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

internal sealed record RewritePaidReviewChange(string Identity, Func<Task<bool>> Apply, bool Shorter);

internal sealed partial class RewriteSession
{
    internal bool HasPaidTakes => generationWindows.Any(window => window.HasPaidTakes);
    internal RewritePaidReviewChange? PendingPaidReviewChange { get; private set; }
    private bool DeferPaidReviewChange(Func<Task<bool>> apply, bool shorter = false)
    {
        if (!HasPaidTakes) return false;
        PendingPaidReviewChange = new(ReviewIdentity, apply, shorter);
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }
    internal void CancelPaidReviewChange()
    {
        PendingPaidReviewChange = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }
    internal async Task<bool> ConfirmPaidReviewChangeAsync(RewritePaidReviewChange expected)
    {
        if (!ReferenceEquals(expected, PendingPaidReviewChange) || expected.Identity != ReviewIdentity || !ReviewIsCurrent ||
            generationWindows.Any(window => window.IsRunning || window.IsPreparing)) return false;
        PendingPaidReviewChange = null;
        await StopCandidatesAsync();
        if (!ReviewIsCurrent || expected.Identity != ReviewIdentity) return false;
        RetireGenerationWindows();
        generatedReview = null;
        var applied = await expected.Apply();
        ReconcileGenerationWindows();
        Changed?.Invoke(this, EventArgs.Empty);
        return applied;
    }
    private readonly PatchRewriteService patchService = new(new LlmCatalog());
    private readonly RewriteScope? requestedScope;
    private ScopeRewritePlan? scopePlan;
    private IReadOnlyList<ScopeRewriteDiff.Hunk>? scopeHunks;
    private readonly Dictionary<int, TranscriptChangeState> changeStates = [];
    private readonly HashSet<int> priceOverrides = [];
    internal IReadOnlyList<RewriteHunkReview> PricedVoiceHunks => Review?.VoiceHunks.Where(CanPriceHunk).ToArray() ?? [];
    internal IReadOnlyList<RewriteHunkReview> BlockedVoiceHunks => Review?.VoiceHunks.Where(hunk => hunk.Fit is { Fits: false } && !CanPriceHunk(hunk)).ToArray() ?? [];
    internal string FitFooter => BlockedVoiceHunks.Count is var count && count > 0
        ? BlockedVoiceHunks.Any(hunk => hunk.Fit is { TooLong: false })
            ? count == 1 ? "1 phrase needs wording that fits." : $"{count} phrases need wording that fits."
            : count == 1 ? "1 phrase needs a shorter wording." : $"{count} phrases need a shorter wording."
        : "Nothing paid yet.";
    internal string GetPriceTitle => $"Get Price · {PricedVoiceHunks.Count} " + (PricedVoiceHunks.Count == 1 ? "phrase" : "phrases");
    internal bool CanPriceHunk(RewriteHunkReview hunk) => hunk.Fit is { } fit &&
        (HasPaidTakes && generatedVoiceHunks.Length > 0
            ? generatedVoiceHunks.Any(previous => previous.Ordinals.SequenceEqual(hunk.Ordinals))
            : fit.Fits || hunk.Ordinals.All(priceOverrides.Contains));
    internal bool PriceItAnyway(int ordinal)
    {
        if (!ReviewIsCurrent || Review is null || ordinal < 1 || ordinal > Review.Diff.Hunks.Count ||
            Review.VoiceHunks.FirstOrDefault(hunk => hunk.Ordinals.Contains(ordinal) && hunk.Fit is { Fits: false }) is not { } phrase) return false;
        if (DeferPaidReviewChange(() => Task.FromResult(PriceItAnyway(ordinal)))) return false;
        SentenceReview = null;
        InvalidateProposal();
        priceOverrides.UnionWith(phrase.Ordinals);
        RefreshReview(preserveGenerations: true);
        InvalidateGenerationInputs();
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }
    internal async Task<bool> PrepareShorterAsync(int? ordinal = null)
    {
        if (!ReviewIsCurrent || Review is null) return false;
        var feedback = ShorterFeedback(ordinal);
        if (feedback.Count == 0) return false;
        if (DeferPaidReviewChange(() => PrepareShorterFeedbackAsync(feedback), shorter: true)) return false;
        return await PrepareShorterFeedbackAsync(feedback);
    }
    internal IReadOnlyList<VoiceRewriteTimingFeedback> ShorterFeedback(int? ordinal = null)
    {
        if (Review is null) return [];
        var hunks = BlockedVoiceHunks.Where(hunk => hunk.Fit is { TooLong: true }).Concat(ordinal is { } number
            ? Review.VoiceHunks.Where(hunk => hunk.Ordinals.Contains(number)) : []).Distinct().ToArray();
        VoiceLabTakeRow? Measured(RewriteHunkReview hunk)
        {
            var index = Array.FindIndex(generatedVoiceHunks, previous => SameVoicePhrase(previous, hunk));
            var generation = generationWindows.ElementAtOrDefault(index);
            return generation?.Selected is { Audio: not null } selected ? selected : generation?.Rows
                .Where(row => row.Audio is not null).OrderByDescending(row => row.Score).FirstOrDefault();
        }
        return hunks.Where(hunk => hunk.Fit is not null && (Measured(hunk) is { Audio: { } audio }
            ? audio.Fit is VoiceLabFitResult.ChangedDuration { ResidualSeconds: > 0 }
            : hunk.Fit is not { Fits: false, TooLong: false })).Select(hunk => new VoiceRewriteTimingFeedback(
            string.Join(" ", hunk.Hunk.SourceWordIds.Select(id => Transcript.First(word => word.Id == id).Text)),
            hunk.PatchText!, Measured(hunk) is { Audio: { } audio } ? audio.Fit.Plan.OutputFrames / (double)audio.SampleRate : hunk.Fit!.EstimateSeconds,
            hunk.Fit!.SlotSeconds)).ToArray();
    }
    private async Task<bool> PrepareShorterFeedbackAsync(IReadOnlyList<VoiceRewriteTimingFeedback> feedback)
    {
        await StopCandidatesAsync();
        if (!ReviewIsCurrent) return false;
        await SetInstructionAsync(Instruction, shorterPhrases: feedback);
        return Prepared is not null;
    }
    internal int FocusedChange { get; private set; }
    internal Action<int>? RevealChange { get; set; }
    internal Action<int>? EditReviewChange { get; set; }
    internal void FocusChange(int ordinal)
    {
        if (Review is null || ordinal < 1 || ordinal > Review.Diff.Hunks.Count || FocusedChange == ordinal) return;
        FocusedChange = ordinal;
        Changed?.Invoke(this, EventArgs.Empty);
    }
    internal Func<CancellationToken, Task<bool>>? VoiceConsent { get; set; }
    internal IReadOnlyDictionary<int, TranscriptChangeState> ChangeStates => changeStates;
    internal IReadOnlyList<ScopeRewriteDiff.Hunk>? ScopeHunks => scopeHunks;
    internal IReadOnlyList<VoiceLabDiffHunk> IncludedHunks => Review?.Diff.Hunks.Where((_, index) =>
        changeStates.GetValueOrDefault(index + 1) != TranscriptChangeState.Excluded).ToArray() ?? [];
    internal bool ReviewIsCurrent => GenerationIsCurrent && !IsProposing && !IsGeneratingBatch;
    internal string ReviewIdentity => System.Text.Json.JsonSerializer.Serialize(new
    {
        Project.Id, Scope, Instruction, NewWords, Diff = Review?.Diff, Metadata = scopeHunks,
        States = changeStates.OrderBy(pair => pair.Key).ToArray(), Overrides = priceOverrides.Order().ToArray(),
        Sentences = sentenceReplacements.OrderBy(pair => pair.Key).ToArray(), Local = LocalOperations()
    });

    internal bool SetChangeIncluded(int ordinal, bool included)
    {
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count) return false;
        if (DeferPaidReviewChange(() => Task.FromResult(SetChangeIncluded(ordinal, included)))) return false;
        InvalidateProposal();
        priceOverrides.Clear();
        changeStates[ordinal] = included ? TranscriptChangeState.Pending : TranscriptChangeState.Excluded;
        RefreshReview();
        InvalidateGenerationInputs();
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }

    internal bool SetChangesIncluded(IReadOnlyList<int> ordinals, bool included)
    {
        if (!ReviewIsCurrent || Review is null || ordinals.Count == 0 || ordinals.Any(ordinal => ordinal <= 0 || ordinal > Review.Diff.Hunks.Count)) return false;
        var captured = ordinals.ToArray();
        if (DeferPaidReviewChange(() => Task.FromResult(SetChangesIncluded(captured, included)))) return false;
        foreach (var ordinal in captured) SetChangeIncluded(ordinal, included);
        return true;
    }

    internal bool EditChange(int ordinal, string text)
    {
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count) return false;
        if (DeferPaidReviewChange(() => Task.FromResult(EditChange(ordinal, text)))) return false;
        var hunk = Review.Diff.Hunks[ordinal - 1];
        try
        {
            var sourceIds = hunk.SourceWordIds.ToHashSet(StringComparer.Ordinal);
            var local = VoiceLabWordDiff.Diff(Source.Where(word => sourceIds.Contains(word.Id)).ToArray(), text);
            var proposals = scopeHunks ?? Review.Diff.Hunks.Select(change => new ScopeRewriteDiff.Hunk(change, null, [], [], false)).ToArray();
            var metadata = proposals[ordinal - 1];
            var replacements = local.Hunks.Select(change => metadata with
            {
                Diff = change with { SourceStartIndex = change.SourceStartIndex + hunk.SourceStartIndex,
                    SourceEndIndex = change.SourceEndIndex + hunk.SourceStartIndex, AnchorSeconds = change.AnchorSeconds ?? hunk.AnchorSeconds }
            }).ToArray();
            var dispositions = changeStates.ToArray();
            InvalidateProposal();
            priceOverrides.Clear();
            scopeHunks = proposals.Take(ordinal - 1).Concat(replacements).Concat(proposals.Skip(ordinal)).ToArray();
            changeStates.Clear();
            foreach (var pair in dispositions.Where(pair => pair.Key != ordinal))
                changeStates[pair.Key < ordinal ? pair.Key : pair.Key + replacements.Length - 1] = pair.Value;
            NewWords = string.Join(" ", ReviewDiff().Ops.Where(operation => operation.NewToken is not null).Select(operation => operation.NewToken));
            RefreshReview();
            InvalidateGenerationInputs();
            Changed?.Invoke(this, EventArgs.Empty);
            return true;
        }
        catch (VoiceLabWordDiffException error) { reviewProblem = Refusal(error); Changed?.Invoke(this, EventArgs.Empty); return false; }
    }

    internal VoiceLabWordDiffResult ReviewDiff()
    {
        if (scopeHunks is null) return VoiceLabWordDiff.Diff(Source, NewWords);
        var tokens = Source.Where(word => word.Kind == WordKind.Word).SelectMany(word =>
            EditingAlgorithms.SplitWords(word.Text).Select(token => (Word: word, Token: token))).ToArray();
        List<VoiceLabDiffOp> operations = [];
        var cursor = 0;
        foreach (var proposal in scopeHunks)
        {
            var hunk = proposal.Diff;
            while (cursor < hunk.SourceStartIndex)
            {
                var item = tokens[cursor++];
                operations.Add(new(VoiceLabDiffOpKind.Equal, item.Word.Id, item.Token, item.Token));
            }
            var owners = hunk.SourceWordIds.ToHashSet(StringComparer.Ordinal);
            var local = VoiceLabWordDiff.Diff(Source.Where(word => owners.Contains(word.Id)).ToArray(), string.Join(" ", hunk.NewTokens));
            operations.AddRange(local.Ops);
            cursor = hunk.SourceEndIndex;
        }
        while (cursor < tokens.Length)
        {
            var item = tokens[cursor++];
            operations.Add(new(VoiceLabDiffOpKind.Equal, item.Word.Id, item.Token, item.Token));
        }
        return new(operations, scopeHunks.Select(hunk => hunk.Diff).ToArray());
    }
}
