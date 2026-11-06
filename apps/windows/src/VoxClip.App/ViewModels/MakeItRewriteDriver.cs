using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

/// <summary>Voices one planned rewrite with Rewrite's own session and take windows (design §6.7), twin of the Mac
/// <c>MakeItRewriteDriver</c>: the planner's words are the session's reply, and the driver takes the steps a creator would, within
/// the run's budget. Each priced step is checked against the budget before it runs; the click on ✦ Make it postable is its approval.
/// It never discards a paid take, never sends the words to the AI again, and stops where the creator is needed. Rewrite already
/// chooses a take whose only problem is the join's loudness (ADR-R39); the driver names those phrases for the review.</summary>
internal sealed class MakeItRewriteDriver(EditorViewModel editor, MakeItRewriteRequest request, Func<MakeItRewriteRequest, Task<RewriteSession?>> open,
    Func<CancellationToken, Task<VoiceLabMonthlyCap?>> readCap, Action<RewriteSession>? handOff = null)
{
    /// <summary>The steps the last run took, for the smoke's log.</summary>
    internal List<string> Pressed { get; } = [];
    /// <summary>Phrases kept as recorded because the use-time guard blocked them (voice-lab.md §6.9): no click of the creator's.</summary>
    private readonly HashSet<int> keptBlocked = [];

    internal async Task<MakeItRewriteOutcome> RunAsync(CancellationToken ct)
    {
        var session = await open(request);
        if (session is null) return new(new MakeItRewriteResult.NeedsYou("Rewrite couldn't place these words. Change to try it yourself."));
        var used = false;
        // Every phrase kept its recorded audio by Rewrite's own rules: the Rewrite is complete, so it is closed, not handed back.
        var finished = false;
        List<int> joins = [];
        try
        {
            var before = editor.Project.VoiceLab.Segments.Select(segment => segment.Id).ToHashSet(StringComparer.Ordinal);
            session.Edit(request.Text);
            Pressed.Add("receive the planned words");
            if (session.Review is null) return new(new MakeItRewriteResult.NeedsYou("Rewrite couldn't place these words. Change to try it yourself."));
            // A planned change that can't fit its time in the video keeps the speaker's words with no click (ADR-R42, Mac S-make-it-long);
            // nothing is priced that can't fit.
            var voices = session.Review.VoiceHunks.Count > 0;
            if (session.BlockedVoiceHunks.Count > 0)
            {
                Pressed.Add("Keep My Words");
                session.KeepMyWords();
            }
            if (session.PricedVoiceHunks.Count == 0 && voices) return new(FinishAsRecorded(session));
            if (session.PricedVoiceHunks.Count == 0)
            {
                // Only cuts or corrections: Rewrite applies them without a voice.
                var applied = session.LocalAction is not null && session.ApplyLocalChanges();
                Pressed.Add("apply text-only changes");
                return new(applied ? new MakeItRewriteResult.Voiced([]) : new MakeItRewriteResult.NeedsYou("Rewrite is waiting for you. Change to finish it."));
            }
            await session.DiscoverWindowsAsync();
            foreach (var window in session.GenerationWindows) await window.PendingUpdate;
            ct.ThrowIfCancellationRequested();
            if (session.PreparedBatch is not { } batch) return new(new MakeItRewriteResult.NeedsYou(FirstLine(session.FooterStep.Line, "Rewrite couldn't price these words. Change to try it yourself.")));
            var usd = batch.Estimate.Usd;
            if (request.Budget is not { } budget || usd is not { } amount || amount > budget) return new(new MakeItRewriteResult.OverCap(usd));
            var cap = await readCap(ct);
            if (cap is not null && batch.Kind(cap).Kind == VoiceLabCostPresentationKind.Confirm)
                return new(new MakeItRewriteResult.NeedsYou("This would pass your monthly ElevenLabs cap. Voice it in Rewrite. Nothing was sent."));
            // A phrase the guard blocked sent nothing, so its share of the price is never counted as spent (Mac G4).
            // The batch covers the priced phrases only (a phrase settled earlier in this Rewrite is left out of it), in their order.
            var quoted = batch.Windows.Select(window => window.Quote.Estimate.Usd ?? 0m).ToArray();
            var priced = session.PricedWindows.ToArray();
            decimal Spent() => quoted.Where((_, index) => priced.ElementAtOrDefault(index)?.Blocked is null).Sum() + session.AutoFix.Spent;
            // An approved price also lets Rewrite fix stuck phrases on its own; that allowance stays inside the budget.
            session.AutoFixCeiling = Math.Max(0, budget - amount);
            session.MarkBatchEstimateShown(batch);
            Pressed.Add("Make takes · " + MakeItController.Dollars(amount));
            await session.GenerateWindowsAsync((_, _, _, _) => Task.FromResult(true), _ => Task.FromResult(cap));
            for (var round = 0; round < 32; round++)
            {
                ct.ThrowIfCancellationRequested();
                if (session.AutoFix.Work is { } work) { await work; continue; }
                if (session.AutoFix.Capped is { } capped)
                {
                    var spent = Spent();
                    if (capped.Usd is not { } next || spent + next > budget) return new(new MakeItRewriteResult.OverCap(capped.Usd), spent);
                    Pressed.Add("Keep fixing · " + MakeItController.Dollars(next));
                    session.KeepFixing();
                    continue;
                }
                joins = JoinNotes(session);
                // A phrase the guard blocked is kept as recorded with no click (Mac keepBlockedPhrases); the other phrases go on.
                if (session.KeepBlockedAsRecorded() is { Count: > 0 } blocked)
                {
                    keptBlocked.UnionWith(blocked);
                    Pressed.Add("Make it postable keeps " + string.Join(", ", blocked.Select(index => "phrase " + (index + 1))) + " as recorded (not the voice owner)");
                    continue;
                }
                var footer = session.FooterStep;
                if (footer.Action == RewriteFooterAction.UseTakes && session.CanAcceptAll)
                {
                    Pressed.Add("Use");
                    if (!await session.ApplyTakeAsync()) break;
                    var added = editor.Project.VoiceLab.Segments.Select(segment => segment.Id).Where(id => !before.Contains(id)).ToArray();
                    used = true;
                    return new(new MakeItRewriteResult.Voiced(added), Spent()) { JoinNotes = joins, KeptAsRecorded = keptBlocked.Count };
                }
                if (footer.Action == RewriteFooterAction.ChooseTake)
                {
                    Pressed.Add(footer.Title ?? "Choose take");
                    if (await session.ChooseOfferedTakeAsync()) continue;
                }
                // The free steps forward a creator would take, in the Mac order: a duration a take allows (Mac chooseDuration), then a
                // phrase that keeps its original audio (Mac keepOriginalAudio).
                if (footer.Action == RewriteFooterAction.ChooseDuration && session.ChooseDuration(footer.Phrase)) { Pressed.Add(footer.Title!); continue; }
                if (footer.Action == RewriteFooterAction.KeepOriginal && footer.Title?.StartsWith("Keep Original Audio", StringComparison.Ordinal) == true &&
                    session.KeepOriginal(footer.Phrase)) { Pressed.Add(footer.Title); continue; }
                if (footer.Action == RewriteFooterAction.KeepChangeWords && session.KeepCollidedOriginal(footer.Phrase)) { Pressed.Add(footer.Title!); continue; }
                // Every phrase keeps its audio: the text fixes apply and the Rewrite ends, nothing voiced.
                if (session.GenerationWindows.Count > 0 && session.GenerationWindows.All(window => window.LeftOut))
                {
                    finished = true;
                    return new(FinishAsRecorded(session), Spent()) { JoinNotes = joins, KeptAsRecorded = keptBlocked.Count };
                }
                return new(new MakeItRewriteResult.NeedsYou(FirstLine(footer.Line, "Rewrite is waiting for you. Change to finish it.")), Spent()) { JoinNotes = joins };
            }
            return new(new MakeItRewriteResult.NeedsYou("Rewrite is waiting for you. Change to finish it."), Spent()) { JoinNotes = joins };
        }
        finally
        {
            // Paid takes are never dropped: an unused session with paid takes stays for Change, which shows it in Rewrite.
            if (session.IsOpen && !used && !finished && session.HasPaidTakes && handOff is not null) handOff(session);
            else if (session.IsOpen) session.Dispose();
        }
    }

    /// <summary>Nothing is left to voice (Mac <c>finishAsRecorded</c>): the Rewrite's text fixes are applied as free edits when it has any,
    /// and the result says why the words stay.</summary>
    private MakeItRewriteResult FinishAsRecorded(RewriteSession session)
    {
        var reason = keptBlocked.Count > 0 ? RewriteSession.NotYourVoiceHere : session.AutoFix.Notes.LastOrDefault() ?? "Your words stay as recorded.";
        var fixes = session.TextFixCount > 0 && session.ApplyTextFixesOnly();
        Pressed.Add(fixes ? "apply text fixes; keep the words as recorded" : "keep the words as recorded");
        return new MakeItRewriteResult.KeptAsRecorded(fixes ? reason + " Its text fixes are applied." : reason);
    }

    /// <summary>The phrases whose chosen take only has a join-loudness advisory.</summary>
    private static List<int> JoinNotes(RewriteSession session) => session.GenerationWindows
        .Select((window, index) => (Index: index, Row: window.Rows.FirstOrDefault(row => row.Id == window.SelectedTakeId)))
        .Where(item => item.Row?.HasJoinAdvisory == true).Select(item => item.Index).ToList();

    private static string FirstLine(string text, string fallback)
    {
        var line = text.Split('\n')[0].Trim();
        return line.Length == 0 ? fallback : line;
    }
}
