using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.App.ViewModels;

// Phrases settled for this Rewrite (design.md R2 "Not your voice here", ADR-R40; Mac RewriteSettledPhrases): the use-time guard refused a
// phrase's speech (voice-lab.md §6.9) and no retry can change that. Its card says the stop once with [● Say it myself] [Keep as recorded],
// the footer's next step keeps its original audio, and no priced control is offered for it again, in this plan or a later one of the same
// Rewrite. ✦ Make it postable keeps it as recorded on its own (MakeItRewriteDriver).
internal sealed partial class RewriteSession
{
    /// <summary>The driver's reason when it kept a blocked phrase as recorded (Mac <c>finishAsRecorded</c>).</summary>
    internal const string NotYourVoiceHere = "It doesn't sound like your voice here, so nothing was sent.";

    /// <summary>Change ordinals the guard settled in this Rewrite, with the stop: a later plan's phrase that carries one is blocked
    /// before anything is priced for it.</summary>
    private readonly Dictionary<int, string> guardBlocked = [];

    /// <summary>The stop for a guard refusal (Mac <c>ClipTakePlan.blockedCopy</c>).</summary>
    internal static string BlockedCopy(Exception? failure) => failure is VoiceConsentException { Kind: VoiceConsentError.SpeakerMismatch }
        ? "There isn't enough speech near this phrase to check that it's your voice. Nothing sent for this phrase."
        : "This doesn't sound like the voice owner. Voice Lab is only for your own videos. Nothing sent for this phrase.";

    /// <summary>Records every blocked phrase's changes, so a later plan of this Rewrite keeps them settled (Mac <c>rememberBlocked</c>).</summary>
    private void RememberBlocked()
    {
        for (var index = 0; index < generationWindows.Count && index < generatedVoiceHunks.Length; index++)
            if (generationWindows[index].Blocked is { } reason)
                foreach (var ordinal in generatedVoiceHunks[index].Ordinals) guardBlocked.TryAdd(ordinal, reason);
    }

    /// <summary>A new plan's phrase whose changes the guard already settled: blocked before anything is priced (Mac <c>applyRememberedBlocks</c>).</summary>
    private void ApplyRememberedBlock(RewriteGeneration window, RewriteHunkReview? hunk)
    {
        if (hunk is null) return;
        foreach (var ordinal in hunk.Ordinals)
            if (guardBlocked.TryGetValue(ordinal, out var reason)) { window.Block(reason); return; }
    }

    /// <summary>The first blocked phrase still waiting on Keep as recorded or a take of the user's own; -1 when none.</summary>
    internal int FirstWaitingOnBlock
    {
        get
        {
            for (var index = 0; index < generationWindows.Count; index++)
                if (generationWindows[index].WaitsOnBlock) return index;
            return -1;
        }
    }

    /// <summary>Keep as recorded for every blocked phrase still waiting: no take of it is used and nothing is sent (Mac
    /// <c>keepBlockedAsRecorded</c>). Returns the phrases kept.</summary>
    internal IReadOnlyList<int> KeepBlockedAsRecorded()
    {
        List<int> kept = [];
        for (var index = 0; index < generationWindows.Count; index++)
            if (generationWindows[index].WaitsOnBlock && generationWindows[index].LeaveOut()) { AutoFix.Lines.Remove(index); kept.Add(index); }
        if (kept.Count > 0) Changed?.Invoke(this, EventArgs.Empty);
        return kept;
    }

    /// <summary>Every phrase is blocked or kept as recorded and at least one was blocked: nothing is left to price.</summary>
    internal bool EveryPhraseSettled => generationWindows.Count > 0 && generationWindows.Any(window => window.Blocked is not null) &&
        generationWindows.All(window => window.Blocked is not null || window.LeftOut);
}
