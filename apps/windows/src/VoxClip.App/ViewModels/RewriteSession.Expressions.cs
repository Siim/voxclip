using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Per-phrase expressions once takes exist (design.md R2 "Expressions", Mac <c>updateAudioTags(_:phrase:)</c>): only that
/// phrase's tags change, its takes so far stay listed as "Before expression", a fresh quote is prepared for it alone and the
/// automatic fixes make its new take within the cap. No discard prompt; other phrases keep their paid takes. While anything
/// runs the tag shows at once with a line and is applied when it settles.</summary>
internal sealed partial class RewriteSession
{
    private readonly Dictionary<int, IReadOnlyList<VoiceLabAudioTag>> pendingExpressions = [];
    private readonly Dictionary<int, string> expressionNotes = [];
    /// <summary>Expressions can be edited now, or (with takes) shown at once and applied when the work in progress settles.</summary>
    internal bool ExpressionsEditable => IsOpen && (ReviewIsCurrent || HasPaidTakes && ReferenceEquals(Project, Editor.Project) && !Editor.IsReadOnly);
    /// <summary>The tags a change shows: a pending expression at once, else its own.</summary>
    internal IReadOnlyList<VoiceLabAudioTag> ShownAudioTags(int ordinal) => pendingExpressions.GetValueOrDefault(ordinal) ??
        Review?.Diff.Hunks.ElementAtOrDefault(ordinal - 1)?.AudioTags ?? [];
    /// <summary>Why change <paramref name="ordinal"/>'s expression isn't in its takes yet; null when it is.</summary>
    internal string? ExpressionNote(int ordinal) => expressionNotes.GetValueOrDefault(ordinal);

    internal int PendingExpressionCount => pendingExpressions.Count;
    private string? ExpressionBlocker() =>
        IsProposing || Reasking is not null ? $"The expression is added when {AiName} answers." :
        WordingIsLocked ? "The expression is added when the wording fit ends." :
        IsGeneratingBatch || AutoFix.Work is not null || generationWindows.Any(window => window.IsRunning || window.IsPreparing)
            ? "The expression is added when the current takes finish." : null;

    private bool SetPhraseExpressions(int ordinal, IReadOnlyList<VoiceLabAudioTag> tags)
    {
        if (Review is null || ordinal <= 0 || ordinal > Review.Diff.Hunks.Count) return false;
        pendingExpressions[ordinal] = tags;
        if (ExpressionBlocker() is { } blocker)
        {
            expressionNotes[ordinal] = blocker;
            Changed?.Invoke(this, EventArgs.Empty);
            return true;
        }
        ApplyPendingExpressions();
        return true;
    }

    /// <summary>Applies the expressions chosen while something ran, one change at a time, once nothing runs.</summary>
    private void ApplyPendingExpressions()
    {
        if (pendingExpressions.Count == 0 || ExpressionBlocker() is not null || Review is not { } review) return;
        var ordinal = pendingExpressions.Keys.Min();
        var tags = pendingExpressions[ordinal];
        pendingExpressions.Remove(ordinal);
        expressionNotes.Remove(ordinal);
        if (ordinal > review.Diff.Hunks.Count || tags.SequenceEqual(review.Diff.Hunks[ordinal - 1].AudioTags)) return;
        var index = PricedVoiceHunks.ToList().FindIndex(phrase => phrase.Ordinals.Contains(ordinal));
        var window = generationWindows.ElementAtOrDefault(index);
        var hadTakes = window?.Rows.Count > 0;
        var proposals = scopeHunks ?? review.Diff.Hunks.Select(change => new ScopeRewriteDiff.Hunk(change, null, [], [], false)).ToArray();
        scopeHunks = proposals.Select((proposal, at) => at == ordinal - 1 ? proposal with { Diff = proposal.Diff with { AudioTags = tags } } : proposal).ToArray();
        if (sentenceReplacements.TryGetValue(ordinal, out var expanded)) sentenceReplacements[ordinal] = expanded with
            { AudioTags = VoiceLabAudioTags.Shifted(tags, proposals[ordinal - 1].Diff.SourceStartIndex - expanded.SourceStartIndex) };
        InvalidateProposal();
        RefreshReview(preserveGenerations: true);
        if (generationWindows.ElementAtOrDefault(index) is { } phrase && ReferenceEquals(phrase, window))
        {
            phrase.MarkBeforeExpression();
            var preparing = phrase.InputsChangedAsync(preserveReview: true);
            // Takes already ran: the automatic fixes make this phrase's new take within the cap (one round).
            if (hadTakes && AutoFix.Running)
            {
                AutoFix.Rounds[index] = AutoFix.Rounds.GetValueOrDefault(index) + 1;
                RunAutoStep(index, $"Fixing phrase {index + 1}: making a take with the expression…", async () =>
                {
                    await preparing;
                    await StartAutomaticTakeAsync(index);
                });
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The phrase card's status line (Mac <c>phraseStatus</c>): it looks forward, never a list of checks.</summary>
    internal string PhraseStatus(int index)
    {
        if (generationWindows.ElementAtOrDefault(index) is not { } window) return "";
        if (AutoFix.Running && AutoFix.Lines.TryGetValue(index, out var line)) return line;
        if (window.LeftOut) return "Keeps your original words. Its takes stay listed.";
        if (PricedVoiceHunks.ElementAtOrDefault(index)?.Ordinals.Select(ExpressionNote).FirstOrDefault(note => note is not null) is { } note) return note;
        if (StuckReason(index) is { } reason)
            return reason is StuckTakeReason.Length { Selected: true } ? window.TakeDetail : StuckSentence(reason, index + 1);
        if (window.IsRunning || IsGeneratingBatch && window.Rows.Count == 0) return "Making takes…";
        if (window.Rows.Count == 0) return "Takes start after you approve the price.";
        return window.TakeDetail;
    }
}
