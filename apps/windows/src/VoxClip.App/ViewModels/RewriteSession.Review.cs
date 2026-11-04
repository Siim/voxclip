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
    private IReadOnlyList<VoiceLabAudioTag> audioTags = [];
    internal IReadOnlyList<RewriteHunkReview> PricedVoiceHunks => Review?.VoiceHunks.Where(CanPriceHunk).ToArray() ?? [];
    internal IReadOnlyList<RewriteHunkReview> BlockedVoiceHunks => Review?.VoiceHunks.Where(hunk => hunk.Fit is { Fits: false } && !CanPriceHunk(hunk) &&
        !hunk.Ordinals.All(VoicedOrdinals.Contains)).ToArray() ?? [];
    /// <summary>Mac <c>voicedOrdinals</c>: changes whose phrase has a selected passing take that fits by length (keep source or a
    /// cut), made for the phrase's wording now. Such a change is never held back by a re-estimate (a new speaking-rate
    /// calibration), and its row shows no estimate or recovery.</summary>
    internal IReadOnlySet<int> VoicedOrdinals => generationWindows.Select((window, index) => (Window: window, Hunk: PricedVoiceHunks.ElementAtOrDefault(index), Index: index))
        .Where(item => item.Hunk is not null && !item.Window.LeftOut && item.Window.Selected is { Selectable: true } selected && item.Window.LengthFits(selected) &&
            item.Window.InputFor(selected.Id)?.Text == (measuredWording.GetValueOrDefault(item.Index) ?? item.Hunk.PatchText))
        .SelectMany(item => item.Hunk!.Ordinals).ToHashSet();
    /// <summary>Whether change <paramref name="ordinal"/>'s row shows its estimate and length recovery: not once it is voiced.</summary>
    internal bool ShowsEstimate(int ordinal) => !VoicedOrdinals.Contains(ordinal);
    internal string FitFooter => BlockedVoiceHunks.Count is var count && count > 0
        ? BlockedVoiceHunks.Any(hunk => hunk.Fit is { TooLong: false })
            ? count == 1 ? "1 phrase needs wording that fits." : $"{count} phrases need wording that fits."
            : count == 1 ? "1 phrase needs a shorter wording." : $"{count} phrases need a shorter wording."
        : "Nothing paid yet.";
    /// <summary>The review footer: the fitted summary once automatic rounds fit every phrase, otherwise the fit status.</summary>
    /// <summary>Only before paid takes: after them the takes footer names the next step.</summary>
    internal string ReviewFooter => HasPaidTakes ? "" : WordingFitCompleted && BlockedVoiceHunks.Count == 0 && PricedVoiceHunks.Count > 0 ? FitFittedFooter : FitFooter;
    /// <summary>Ask for longer: fit the phrases outside their slots again, with the same consent rules as a reply.</summary>
    internal Task AskForLongerAsync()
    {
        StopWordingFit();
        return BeginAutomaticWordingFitAsync();
    }
    internal string GetPriceTitle => $"Get Price · {PricedVoiceHunks.Count} " + (PricedVoiceHunks.Count == 1 ? "phrase" : "phrases");
    internal bool CanPriceHunk(RewriteHunkReview hunk) => hunk.Fit is { } fit &&
        (HasPaidTakes && generatedVoiceHunks.Length > 0
            ? generatedVoiceHunks.Any(previous => previous.Ordinals.SequenceEqual(hunk.Ordinals))
            : fit.Fits || hunk.Ordinals.All(priceOverrides.Contains));
    internal bool PriceItAnyway(int ordinal)
    {
        StopWordingFit();
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
        StopWordingFit();
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
            hunk.PatchText!, hunk.Fit!.EstimateSeconds, hunk.Fit!.SlotSeconds)
            { MeasuredSeconds = Measured(hunk) is { Audio: { } audio } ? audio.Fit.Plan.OutputFrames / (double)audio.SampleRate : null }).ToArray();
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
    /// <summary>False while takes generate, a Rewrite is sent or wording-fit rounds run: the proposal is then read-only.</summary>
    internal bool ReviewIsCurrent => GenerationIsCurrent && !IsProposing && !IsGeneratingBatch;
    internal string ReviewIdentity => System.Text.Json.JsonSerializer.Serialize(new
    {
        Project.Id, Scope, Instruction, NewWords, Diff = Review?.Diff, Metadata = scopeHunks,
        States = changeStates.OrderBy(pair => pair.Key).ToArray(), Overrides = priceOverrides.Order().ToArray(),
        Sentences = sentenceReplacements.OrderBy(pair => pair.Key).ToArray(), Local = LocalOperations()
    });

    internal bool SetChangeIncluded(int ordinal, bool included)
    {
        StopWordingFit();
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
        StopWordingFit();
        if (!ReviewIsCurrent || Review is null || ordinals.Count == 0 || ordinals.Any(ordinal => ordinal <= 0 || ordinal > Review.Diff.Hunks.Count)) return false;
        var captured = ordinals.ToArray();
        if (DeferPaidReviewChange(() => Task.FromResult(SetChangesIncluded(captured, included)))) return false;
        foreach (var ordinal in captured) SetChangeIncluded(ordinal, included);
        return true;
    }

    internal bool EditChange(int ordinal, string text)
    {
        StopWordingFit();
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count) return false;
        if (DeferPaidReviewChange(() => Task.FromResult(EditChange(ordinal, text)))) return false;
        var hunk = Review.Diff.Hunks[ordinal - 1];
        try
        {
            var sourceIds = hunk.SourceWordIds.ToHashSet(StringComparer.Ordinal);
            var local = VoiceLabWordDiff.Diff(Source.Where(word => sourceIds.Contains(word.Id)).ToArray(), text,
                VoiceLabAudioTags.Reanchored(hunk.AudioTags, string.Join(" ", hunk.NewTokens), text));
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
        if (scopeHunks is null) return VoiceLabWordDiff.Diff(Source, NewWords, audioTags);
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

    private IReadOnlyList<VoiceLabAudioTag> ReviewAudioTags()
    {
        if (scopeHunks is null || Review is null) return audioTags;
        var result = new List<VoiceLabAudioTag>();
        var oldIndex = 0;
        var newIndex = 0;
        var next = 0;
        foreach (var operation in Review.Diff.Ops)
        {
            while (next < Review.Diff.Hunks.Count && Review.Diff.Hunks[next].SourceStartIndex == oldIndex)
            {
                result.AddRange(VoiceLabAudioTags.Shifted(Review.Diff.Hunks[next].AudioTags, newIndex));
                next++;
            }
            if (operation.Kind != VoiceLabDiffOpKind.Insert) oldIndex++;
            if (operation.Kind != VoiceLabDiffOpKind.Delete) newIndex++;
        }
        while (next < Review.Diff.Hunks.Count) result.AddRange(VoiceLabAudioTags.Shifted(Review.Diff.Hunks[next++].AudioTags, newIndex));
        return result;
    }

    internal bool AddExpression(int ordinal, string tag)
    {
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count ||
            Review.Diff.Hunks[ordinal - 1] is not { Kind: VoiceLabDiffHunkKind.Voice } hunk || !VoiceLabAudioTags.Definitions.Any(definition => definition.Tag == tag) ||
            (Review.VoiceHunks.FirstOrDefault(phrase => phrase.Ordinals.Contains(ordinal))?.RequestAudioTags.Count ?? hunk.AudioTags.Count) >= 64) return false;
        return SetExpressions(ordinal, hunk.AudioTags.Append(new(hunk.NewTokens.Count, tag)).ToArray());
    }
    internal bool RemoveExpression(int ordinal, int index)
    {
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count ||
            index < 0 || index >= Review.Diff.Hunks[ordinal - 1].AudioTags.Count) return false;
        return SetExpressions(ordinal, Review.Diff.Hunks[ordinal - 1].AudioTags.Where((_, at) => at != index).ToArray());
    }
    private bool SetExpressions(int ordinal, IReadOnlyList<VoiceLabAudioTag> annotations)
    {
        StopWordingFit();
        var captured = annotations.ToArray();
        if (DeferPaidReviewChange(() => Task.FromResult(SetExpressions(ordinal, captured)))) return false;
        if (!ReviewIsCurrent || Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count) return false;
        var proposals = scopeHunks ?? Review.Diff.Hunks.Select(change => new ScopeRewriteDiff.Hunk(change, null, [], [], false)).ToArray();
        scopeHunks = proposals.Select((proposal, index) => index == ordinal - 1 ? proposal with
            { Diff = proposal.Diff with { AudioTags = captured } } : proposal).ToArray();
        if (sentenceReplacements.TryGetValue(ordinal, out var expanded)) sentenceReplacements[ordinal] = expanded with
            { AudioTags = VoiceLabAudioTags.Shifted(captured, proposals[ordinal - 1].Diff.SourceStartIndex - expanded.SourceStartIndex) };
        InvalidateProposal();
        RefreshReview(preserveGenerations: true);
        InvalidateGenerationInputs();
        Changed?.Invoke(this, EventArgs.Empty);
        return true;
    }
}
