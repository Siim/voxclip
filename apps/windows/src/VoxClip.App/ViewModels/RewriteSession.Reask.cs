using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Re-asks from the next-step chips and the one free-text field (voice-lab.md §8.2.1, Mac <c>RewriteSession.reask</c>):
/// the session's own request is sent again with scoped feedback; only the asked phrases land, every other change, its state and
/// its take stay. While it runs the list is locked and takes cannot start; Stop, an edit or a stale reply change nothing.</summary>
internal sealed partial class RewriteSession
{
    internal const string ReaskStopped = "Stopped. Nothing changed.";
    internal const string ReaskStale = "The words changed while the AI answered. Nothing changed.";
    internal const string WithinSentenceInstruction = "Rewrite this change without changing any words outside it.";
    /// <summary>The feedback block names at most 60 phrases (Core's next-action ordinal limit).</summary>
    private const int MaximumAskedPhrases = 60;
    private CancellationTokenSource? reasking;
    /// <summary>The re-ask in flight: "Asking {AI}: “{label}”" with Stop.</summary>
    internal RewriteReask? Reasking { get; private set; }
    /// <summary>The last re-ask, which Ask again sends once more.</summary>
    internal RewriteReask? LastReask { get; private set; }
    internal string ReaskProblem { get; private set; } = "";
    internal Task ReaskWork { get; private set; } = Task.CompletedTask;
    /// <summary>The AI's suggested next steps (✦) from the latest reply, at most four.</summary>
    internal IReadOnlyList<RewriteNextAction> ReplyNextActions { get; private set; } = [];
    internal string AiName => Connector?.Name ?? "the AI";
    internal string? ReaskingLine => Reasking is { } asked ? $"Asking {AiName}: “{asked.Label}”" : null;
    /// <summary>Over the voice budget the phrases are voiced anyway (voice-lab.md §8.2, Mac <c>budgetCallout</c>): a note while
    /// a voice change is included, never a hold on takes.</summary>
    internal string? VoiceBudgetCallout => Review is { Budget: { Copy: not null } budget } && IncludedHunks.Any(hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice)
        ? $"These changes re-voice {budget.VoiceTokenCount} words, a lot for a {budget.WordItems}-word clip. Long stretches in your voice can sound stitched; Rewrite goes on." : null;

    /// <summary>Sends <paramref name="reask"/> and lands its reply. With paid takes the inline discard confirmation comes first.</summary>
    internal Task<bool> ReaskAsync(RewriteReask reask)
    {
        if (!IsOpen || Reasking is not null || IsProposing || Connector is null || Review is null || IsGeneratingBatch) return Task.FromResult(false);
        StopWordingFit();
        if (DeferPaidReviewChange(() => ReaskAsync(reask))) return Task.FromResult(false);
        var work = RunReaskAsync(reask);
        ReaskWork = work;
        return work;
    }

    private async Task<bool> RunReaskAsync(RewriteReask reask)
    {
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        reasking = cancellation;
        Reasking = reask; LastReask = reask; ReaskProblem = "";
        var version = revision;
        var identity = ReviewIdentity;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var reply = await SendReaskAsync(reask, cancellation.Token);
            if (cancellation.IsCancellationRequested) { ReaskProblem = ReaskStopped; return false; }
            if (!IsOpen || version != revision || identity != ReviewIdentity) { ReaskProblem = ReaskStale; return false; }
            if (reply is null) return false;
            LandReply(reask, reply);
            return true;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { if (IsOpen) ReaskProblem = ReaskStopped; return false; }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            // A connector may report a cancelled send as its own error: Stop still reads as Stop.
            if (IsOpen) ReaskProblem = cancellation.IsCancellationRequested ? ReaskStopped : Refusal(error) is { Length: > 0 } message ? message : ReaskStale;
            return false;
        }
        finally
        {
            if (ReferenceEquals(reasking, cancellation)) { reasking = null; Reasking = null; }
            cancellation.Dispose();
            if (IsOpen)
            {
                Changed?.Invoke(this, EventArgs.Empty);
                if (ReaskProblem.Length == 0) await BeginAutomaticWordingFitAsync();
            }
        }
    }

    /// <summary>Stop: the reply, if it comes, changes nothing; Ask again stays offered.</summary>
    internal void StopReask()
    {
        try { reasking?.Cancel(); } catch (ObjectDisposedException) { }
    }

    /// <summary>Lands a reply with <see cref="RewriteScopedReply"/>: a scoped re-ask changes only its phrases (replace, keep the
    /// original words, or absorb a merged one); an open one replaces the whole proposal, as a new reply does.</summary>
    private void LandReply(RewriteReask reask, RewriteReaskReply reply)
    {
        if (Review is not { } review) return;
        InvalidateProposal();
        priceOverrides.Clear();
        ReplyNextActions = reply.NextActions;
        if (reask.Ordinals.Count == 0)
        {
            changeStates.Clear();
            scopeHunks = reply.Scoped ?? reply.Hunks.Select(hunk => new ScopeRewriteDiff.Hunk(hunk, null, [], [], false)).ToArray();
        }
        else
        {
            var proposals = (scopeHunks ?? review.Diff.Hunks.Select(change => new ScopeRewriteDiff.Hunk(change, null, [], [], false))).ToList();
            var asked = reask.Ordinals.Where(ordinal => ordinal >= 1 && ordinal <= proposals.Count).Select(ordinal => ordinal - 1).ToHashSet();
            var outcomes = RewriteScopedReply.Assign(review.Diff.Hunks, asked, reply.Hunks);
            var absorbed = new HashSet<int>();
            foreach (var (index, outcome) in outcomes)
            {
                switch (outcome.Kind)
                {
                    case RewriteScopedReply.OutcomeKind.Replace:
                        proposals[index] = reply.Scoped?[outcome.Index] ?? proposals[index] with { Diff = reply.Hunks[outcome.Index] };
                        changeStates.Remove(index + 1);
                        break;
                    case RewriteScopedReply.OutcomeKind.KeepOriginal:
                        changeStates[index + 1] = TranscriptChangeState.Excluded;
                        break;
                    case RewriteScopedReply.OutcomeKind.Absorbed:
                        absorbed.Add(index);
                        break;
                }
            }
            if (absorbed.Count > 0)
            {
                var states = changeStates.ToArray();
                changeStates.Clear();
                foreach (var (ordinal, state) in states.Where(pair => !absorbed.Contains(pair.Key - 1)))
                    changeStates[ordinal - absorbed.Count(index => index < ordinal - 1)] = state;
                proposals = proposals.Where((_, index) => !absorbed.Contains(index)).ToList();
            }
            if (outcomes.Values.All(outcome => outcome.Kind == RewriteScopedReply.OutcomeKind.Conflict))
                ReaskProblem = $"{AiName}'s answer also changed other words, so nothing changed. Ask again or choose below.";
            scopeHunks = proposals;
        }
        NewWords = string.Join(" ", ReviewDiff().Ops.Where(operation => operation.NewToken is not null).Select(operation => operation.NewToken));
        RefreshReview();
        InvalidateGenerationInputs();
        ProposalRevision++;
    }

    /// <summary>The one free-text field ("Tell the AI what to do instead…"), scoped to every stuck phrase; with none, the whole Rewrite.</summary>
    internal Task<bool> TellTheAiAsync(string text)
    {
        var instruction = text.Trim();
        if (instruction.Length == 0) return Task.FromResult(false);
        return ReaskAsync(new(instruction.Length > 40 ? instruction[..40].TrimEnd() + "…" : instruction, instruction, StuckOrdinals, RewriteBlockedReason.Asked));
    }

    /// <summary>Every change a next step is about now: held back by its estimate, a placement collision (both changes), a refused
    /// sentence, or a phrase whose takes are stuck.</summary>
    internal IReadOnlyList<int> StuckOrdinals
    {
        get
        {
            var ordinals = BlockedVoiceHunks.SelectMany(hunk => hunk.Ordinals).ToList();
            if (Collision is { } collision) ordinals.AddRange([collision.Earlier, collision.Change]);
            if (SentenceRefusedOrdinal is { } refused) ordinals.Add(refused);
            for (var index = 0; index < generationWindows.Count; index++)
                if (StuckReason(index) is not null && PricedVoiceHunks.ElementAtOrDefault(index) is { } phrase) ordinals.AddRange(phrase.Ordinals);
            return ordinals.Distinct().Order().Take(MaximumAskedPhrases).ToArray();
        }
    }

    /// <summary>"Change fewer words": the shared instruction with the budget's limit, for every voice change.</summary>
    internal RewriteReask FewerWordsReask()
    {
        var limit = Math.Max(1, (int)Math.Floor((Review?.Budget.WordItems ?? 0) * 0.15));
        var ordinals = Review?.VoiceHunks.SelectMany(hunk => hunk.Ordinals).Distinct().Order().Take(MaximumAskedPhrases).ToArray() ?? [];
        return new("Change fewer words", RewriteNextActionFeedback.FewerWords(Math.Min(60, limit), new LlmCatalog()), ordinals, RewriteBlockedReason.Budget);
    }
}
