using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>A next step sent back to the AI (voice-lab.md §8.2.1): a ✦ chip, a built-in chip or the free-text field, scoped to
/// <see cref="Ordinals"/> (none: the whole Rewrite).</summary>
internal sealed record RewriteReask(string Label, string Instruction, IReadOnlyList<int> Ordinals, RewriteBlockedReason Reason);

/// <summary>A re-ask's checked reply: its hunks over the session's source, its tags and its own next steps.</summary>
internal sealed record RewriteReaskReply(IReadOnlyList<VoiceLabDiffHunk> Hunks, IReadOnlyList<ScopeRewriteDiff.Hunk>? Scoped,
    IReadOnlyList<VoiceLabAudioTag> AudioTags, IReadOnlyList<RewriteNextAction> NextActions);

internal sealed partial class RewriteSession
{
    /// <summary>The phrases a scoped re-ask names, with their reason (and fit figures for <see cref="RewriteBlockedReason.Fit"/>).</summary>
    private IReadOnlyList<RewriteBlockedPhrase> BlockedPhrases(RewriteReask reask)
    {
        if (Review is not { } review) return [];
        return reask.Ordinals.Where(ordinal => ordinal >= 1 && ordinal <= review.Diff.Hunks.Count).Select(ordinal =>
        {
            var hunk = review.Diff.Hunks[ordinal - 1];
            var original = string.Join(" ", hunk.SourceWordIds.Select(id => Transcript.FirstOrDefault(word => word.Id == id)?.Text ?? ""));
            var fit = review.VoiceHunks.FirstOrDefault(phrase => phrase.Ordinals.Contains(ordinal))?.Fit;
            var reason = reask.Reason == RewriteBlockedReason.Fit && fit is null ? RewriteBlockedReason.Asked : reask.Reason;
            return new RewriteBlockedPhrase(ordinal, reason, original.Length == 0 ? "(nothing)" : original,
                hunk.NewTokens.Count == 0 ? "(removed)" : string.Join(" ", hunk.NewTokens),
                reason == RewriteBlockedReason.Fit ? fit!.EstimateSeconds : null, reason == RewriteBlockedReason.Fit ? fit!.SlotSeconds : null);
        }).ToArray();
    }

    /// <summary>The voice budget's figures for a budget re-ask: words re-voiced and words in the clip.</summary>
    internal RewriteNextActionFeedback.Budget VoiceBudgetFigures => new(Review?.Budget.VoiceTokenCount ?? 0, Review?.Budget.WordItems ?? 0);

    /// <summary>Sends the session's own Rewrite request again (same instruction and connector) with the next step's feedback
    /// from <c>shared/prompts/rewrite-next-actions.json</c>, through the usual consent route and its own AI lease. Returns the
    /// checked reply, or null when it no longer applies. Nothing lands here.</summary>
    private async Task<RewriteReaskReply?> SendReaskAsync(RewriteReask reask, CancellationToken ct)
    {
        if (Connector is not { } connector || Review is null || !IsOpen) return null;
        var catalog = new LlmCatalog();
        var phrases = BlockedPhrases(reask);
        var feedback = phrases.Count == 0 ? RewriteNextActionFeedback.Open(reask.Instruction, catalog)
            : RewriteNextActionFeedback.Scoped(reask.Instruction, phrases, phrases.Any(phrase => phrase.Reason == RewriteBlockedReason.Budget) ? VoiceBudgetFigures : null, catalog);
        if ((connector.Group != "local" || requireLocalConsent) && (consent is null || !await consent(ct).WaitAsync(ct))) return null;
        using var lease = Editor.LlmRuns.TryAcquire() ?? throw new RewriteGenerationException(FitBusy);
        if (scopePlan is { } plan)
        {
            var input = plan.Request with { RequestId = Guid.NewGuid(), Feedback = feedback };
            var action = await patchService.PrepareAsync(input, connector.Connector, connector.Model, ct);
            var patch = await patchService.ProposeAsync(input, connector.Connector, connector.Model, patchService.Approve(action, true), ct);
            var hunks = ScopeRewriteDiff.Hunks(plan, patch);
            return new(hunks.Select(hunk => hunk.Diff).ToArray(), hunks, [], patch.NextActions);
        }
        if (request is not { } original) return null;
        var passage = original with { RequestId = Guid.NewGuid(), Feedback = feedback };
        var prepared = await service.PrepareAsync(passage, connector.Connector, connector.Model, ct);
        var result = await service.ProposeAsync(passage, connector.Connector, connector.Model, service.Approve(prepared, true), ct);
        var diff = VoiceLabWordDiff.Diff(Source, result.ProposedText, result.AudioTags);
        return new(diff.Hunks, null, result.AudioTags, result.NextActions);
    }
}
