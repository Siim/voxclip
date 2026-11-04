using System.Globalization;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>One next-step chip (design.md R2): a built-in action, or ✦ an AI suggestion from the reply's <c>nextActions</c>.
/// <see cref="Invoke"/> is null for <see cref="RewriteSession.AskAgainChip"/>, which the panel sends through its approval.</summary>
internal sealed record RewriteChip(string Id, string Title, bool Ai, Func<Task>? Invoke)
{
    internal string Label => Ai ? "✦ " + Title : Title;
}

/// <summary>A stuck state's card: one plain sentence and the chips that act on it, then the free-text field.</summary>
internal sealed record RewriteNextStepCard(string Id, string Sentence, IReadOnlyList<RewriteChip> Chips);

internal enum RewriteFooterAction { None, ApplyLocal, UseTakes, ApplyTextFixes, Done, KeepFixing, StopReask, StopAutoFix }

/// <summary>The footer always names the next step: a line, and the one primary action when there is one.</summary>
internal sealed record RewriteFooterStep(string Line, string? Title, RewriteFooterAction Action);

internal sealed partial class RewriteSession
{
    internal const string AskAgainChip = "Rewrite.Chip.AskAgain";
    internal const string TellTheAiPlaceholder = "Tell the AI what to do instead…";

    /// <summary>The AI's suggestions as ✦ chips, each a scoped re-ask.</summary>
    private IEnumerable<RewriteChip> AiChips() => ReplyNextActions.Select((action, index) => new RewriteChip("Rewrite.Chip.Ai" + (index + 1), action.Label, true,
        () => ReaskAsync(new(action.Label, action.Instruction, action.Ordinals.Count > 0 ? action.Ordinals : StuckOrdinals, RewriteBlockedReason.Asked))));

    private string ChangeTime(int ordinal)
    {
        if (Review?.Diff.Hunks.ElementAtOrDefault(ordinal - 1) is not { } hunk) return "0:00";
        var start = hunk.SourceWordIds.Count > 0 ? Transcript.FirstOrDefault(word => word.Id == hunk.SourceWordIds[0])?.Start ?? 0 : hunk.AnchorSeconds ?? 0;
        var seconds = (int)Math.Floor(Math.Max(0, start));
        return (seconds / 60).ToString(CultureInfo.InvariantCulture) + ":" + (seconds % 60).ToString("00", CultureInfo.InvariantCulture);
    }

    /// <summary>The cards for every stuck state now (Mac <c>.nextSteps</c>). While the automatic fixes run they wait under
    /// "Choose yourself…".</summary>
    internal IReadOnlyList<RewriteNextStepCard> NextStepCards
    {
        get
        {
            List<RewriteNextStepCard> cards = [];
            if (!IsOpen || Reasking is not null || IsProposing || WordingIsLocked) return cards;
            if (ReaskProblem.Length > 0 && LastReask is { } last)
                cards.Add(new("Rewrite.Steps.Reask", ReaskProblem, [new("Rewrite.Chip.ReaskAgain", "Ask again", false, () => ReaskAsync(last))]));
            if (Review is null || Review.Diff.Hunks.Count == 0)
            {
                // R1x: the reply failed or was refused; Ask again sends the same request.
                if (Problem.Length > 0 && Connector is not null)
                    cards.Add(new("Rewrite.Steps.Failed", Problem, [new(AskAgainChip, "Ask again", false, null)]));
                return cards;
            }
            if (VoiceBudgetCallout is { } callout && !HasPaidTakes)
                cards.Add(new("Rewrite.Steps.Budget", callout,
                [
                    new("Rewrite.Chip.ReVoiceAll", ReVoiceAllTitle, false, () => { AcceptVoiceBudget(); return Task.CompletedTask; }),
                    new("Rewrite.Chip.FewerWords", "Change fewer words", false, () => ReaskAsync(FewerWordsReask())),
                    .. TextFixCount > 0 ? [new RewriteChip("Rewrite.Chip.TextFixesOnly", "Keep text fixes only", false, () => { KeepTextFixesOnly(); return Task.CompletedTask; })] : Array.Empty<RewriteChip>(),
                    .. AiChips()
                ]));
            if (SentenceRefusedOrdinal is { } refused && SentenceProblem == SentenceUnavailable && ReviewIsCurrent)
                cards.Add(new("Rewrite.Steps.Sentence" + refused,
                    $"Change {refused} at {ChangeTime(refused)}: its whole sentence doesn't fit inside this clip.",
                [
                    new("Rewrite.Chip.LeaveOut" + refused, "Leave out this change", false, () => { CancelSurroundingSentence(); SetChangeIncluded(refused, false); return Task.CompletedTask; }),
                    new("Rewrite.Chip.ChangedWords" + refused, "Voice just the changed words", false, () => { CancelSurroundingSentence(); PriceItAnyway(refused); return Task.CompletedTask; }),
                    new("Rewrite.Chip.WithinSentence" + refused, "Rewrite without changing the sentence around it", true,
                        () => ReaskAsync(new("Rewrite inside the change", WithinSentenceInstruction, [refused], RewriteBlockedReason.Context))),
                ]));
            if (!HasPaidTakes && ReviewIsCurrent)
                foreach (var hunk in BlockedVoiceHunks)
                {
                    var ordinal = hunk.Ordinals[0];
                    var tooLong = hunk.Fit?.TooLong ?? true;
                    cards.Add(new("Rewrite.Steps.Change" + ordinal, $"Change {ordinal} needs a {(tooLong ? "shorter" : "longer")} wording before takes.",
                    [
                        new("Rewrite.Chip.Reword" + ordinal, tooLong ? "Ask for shorter" : "Ask for longer", true,
                            () => ReaskAsync(new(tooLong ? "Shorter wording" : "Longer wording", tooLong ? "Use fewer words that keep the meaning." : "Use a few more words that keep the meaning.",
                                hunk.Ordinals, RewriteBlockedReason.Fit))),
                        new("Rewrite.Chip.PriceAnyway" + ordinal, "Price it anyway", false, () => { PriceItAnyway(ordinal); return Task.CompletedTask; }),
                        new("Rewrite.Chip.KeepOriginal" + ordinal, $"Keep original words for {ordinal}", false, () => { SetChangesIncluded(hunk.Ordinals, false); return Task.CompletedTask; }),
                        .. AiChips()
                    ]));
                }
            if (HasPaidTakes && AutoFix.ChoicesShown && !IsGeneratingBatch)
                for (var index = 0; index < generationWindows.Count; index++)
                {
                    if (StuckReason(index) is not { } reason) continue;
                    var phrase = index;
                    var window = generationWindows[index];
                    var price = window.Quote?.Estimate.Usd is { } usd ? " · ≈ " + Dollars(usd) : "";
                    List<RewriteChip> chips = [];
                    if (reason is StuckTakeReason.Length length)
                        chips.Add(new("Rewrite.Chip.Fit" + (index + 1), $"Reword phrase {index + 1} to fit", true, () => ManualStepAsync(() => RewordForLengthAsync(phrase, length))));
                    if (reason is StuckTakeReason.Words)
                        chips.Add(new("Rewrite.Chip.Easier" + (index + 1), "Easier words", true, () => ManualStepAsync(() => RewordClearerAsync(phrase))));
                    if (reason is not StuckTakeReason.Length)
                        chips.Add(new("Rewrite.Chip.TryAnother" + (index + 1), "Try another" + price, false, () => ManualStepAsync(() => StartAutomaticTakeAsync(phrase))));
                    chips.Add(new("Rewrite.Chip.KeepPhrase" + (index + 1), $"Keep original words for {index + 1}", false, () => { KeepOriginal(phrase); return Task.CompletedTask; }));
                    chips.AddRange(AiChips());
                    cards.Add(new("Rewrite.Steps.Phrase" + (index + 1), StuckSentence(reason, index + 1), chips));
                }
            return cards;
        }
    }

    /// <summary>A chip the user clicked runs the resolver's own step for that phrase; its price is on the chip, so the click is
    /// the approval and no cap applies.</summary>
    private async Task ManualStepAsync(Func<Task> step)
    {
        if (!GenerationIsCurrent || AutoFix.Work is not null) return;
        manualStep = true;
        try { await step(); }
        finally { manualStep = false; Changed?.Invoke(this, EventArgs.Empty); }
    }

    /// <summary>Text fixes (cuts and corrections) among the included changes.</summary>
    internal int TextFixCount => IncludedHunks.Count(hunk => hunk.Kind != VoiceLabDiffHunkKind.Voice);
    internal string ApplyTextFixesTitle => TextFixCount == 1 ? "Apply 1 text fix" : $"Apply {TextFixCount} text fixes";
    /// <summary>Keep text fixes only: every voice change keeps its original words; cuts and corrections stay.</summary>
    internal void KeepTextFixesOnly()
    {
        if (Review is null) return;
        var voices = Review.Diff.Hunks.Select((hunk, index) => (hunk, ordinal: index + 1)).Where(item => item.hunk.Kind == VoiceLabDiffHunkKind.Voice)
            .Select(item => item.ordinal).ToArray();
        if (voices.Length > 0) SetChangesIncluded(voices, false);
    }
    /// <summary>[Apply {k} text fixes]: applies only the cuts and corrections, as one undo step, with no discard prompt; every
    /// voice change keeps its original words and paid takes stay where they were.</summary>
    internal bool ApplyTextFixesOnly()
    {
        if (!IsOpen || TextFixCount == 0 || !ReferenceEquals(Project, Editor.Project) || Editor.Busy || Editor.IsReadOnly || Editor.IsLeaving) return false;
        return Editor.ApplyBatch(LocalOperations());
    }

    /// <summary>The footer's next step (Mac <c>takesNextStep</c>): never a state with nothing to do.</summary>
    internal RewriteFooterStep FooterStep
    {
        get
        {
            if (ReaskingLine is { } asking) return new(asking, "Stop", RewriteFooterAction.StopReask);
            if (IsProposing) return new($"Asking {AiName}…", null, RewriteFooterAction.None);
            if (WordingIsLocked) return new(WordingFitAwaitingApproval ? "Approve the wording fit above, or skip it." : "Fitting the wording to the video…", null, RewriteFooterAction.None);
            if (Review is null || Review.Diff.Hunks.Count == 0 && (Problem.Length > 0 || ProposalRevision == 0))
                return new(Problem.Length > 0 ? "Ask again, or change the instruction above." : "Describe the change, then Rewrite.", null, RewriteFooterAction.None);
            if (IncludedHunks.Count == 0) return new("Nothing is included. Your original words stay.", "Done", RewriteFooterAction.Done);
            if (LocalAction is { } local) return new($"{local} needs no new audio.", local, RewriteFooterAction.ApplyLocal);
            if (!HasPaidTakes)
            {
                if (VoiceBudgetBlocks) return new("Choose how much to re-voice above.", null, RewriteFooterAction.None);
                if (BlockedVoiceHunks.FirstOrDefault() is { } blocked)
                    return PricedVoiceHunks.Count == 0 && TextFixCount > 0
                        ? new($"Change {blocked.Ordinals[0]} needs a {(blocked.Fit?.TooLong ?? true ? "shorter" : "longer")} wording before takes. Or apply the text fixes now.", ApplyTextFixesTitle, RewriteFooterAction.ApplyTextFixes)
                        : new($"Change {blocked.Ordinals[0]} needs a {(blocked.Fit?.TooLong ?? true ? "shorter" : "longer")} wording before takes.", null, RewriteFooterAction.None);
                if (PricedVoiceHunks.Count > 0)
                    return new(Generation?.Voices.Count > 0 ? "Make the takes to hear the new words." : "Get Price to hear the new words in your voice.", null, RewriteFooterAction.None);
                return TextFixCount > 0 ? new("These changes can't be voiced here. The text fixes still apply.", ApplyTextFixesTitle, RewriteFooterAction.ApplyTextFixes)
                    : new("Nothing can be voiced here. Your original words stay.", "Done", RewriteFooterAction.Done);
            }
            if (CanAcceptAll)
                return generationWindows.All(window => window.LeftOut)
                    ? new("Every phrase keeps its original words. The text fixes still apply.", ApplyTextFixesTitle, RewriteFooterAction.ApplyTextFixes)
                    : new("Use the reviewed takes.", generationWindows.Count > 1 ? "Use Reviewed Takes" : Generation?.AcceptTitle, RewriteFooterAction.UseTakes);
            if (generationWindows.Count > 0 && generationWindows.All(window => window.LeftOut))
                return new("Every phrase keeps its original words.", "Done", RewriteFooterAction.Done);
            if (AutoFix.Running && AutoFix.Lines.Values.FirstOrDefault() is { } fixing) return new(fixing, "Stop", RewriteFooterAction.StopAutoFix);
            if (KeepFixingTitle is { } keep) return new(AutoFixCapLine ?? "", keep, RewriteFooterAction.KeepFixing);
            if (IsGeneratingBatch || generationWindows.Any(window => window.IsRunning)) return new("Making takes…", null, RewriteFooterAction.None);
            if (generationWindows.Any(window => window.IsPreparing)) return new("Checking takes…", null, RewriteFooterAction.None);
            if (AcceptanceBlocker is { } blocker) return new(blocker, null, RewriteFooterAction.None);
            for (var index = 0; index < generationWindows.Count; index++)
                if (StuckReason(index) is { } reason) return new(StuckSentence(reason, index + 1) + " Choose a next step above.", null, RewriteFooterAction.None);
            for (var index = 0; index < generationWindows.Count; index++)
            {
                var window = generationWindows[index];
                if (window.LeftOut || window.ReadyToAccept) continue;
                if (window.Rows.Any(row => window.UseAnywayCanAct(row)))
                    return new($"Listen to phrase {index + 1}'s take, then Use anyway or try another.", null, RewriteFooterAction.None);
                if (window.Rows.Count == 0) return new($"Phrase {index + 1} has no take yet. Make takes above.", null, RewriteFooterAction.None);
                return new($"Choose a take for phrase {index + 1} above, or keep its original words.", null, RewriteFooterAction.None);
            }
            return new("Checking takes…", null, RewriteFooterAction.None);
        }
    }
}
