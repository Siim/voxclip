using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The patch budget never disables cuts or text-only corrections.</summary>
public enum VoiceLabPatchBudgetFlag
{
    /// <summary>The voice hunks are within both limits.</summary>
    Allowed,
    /// <summary>The voice hunks need the re-record message.</summary>
    ReRecordInstead
}
/// <summary>New-side spoken tokens after bridging, the transcript denominator, and the typed UI flag and copy.</summary>
public sealed record VoiceLabPatchBudgetResult(int VoiceTokenCount, int WordItems, VoiceLabPatchBudgetFlag Flag, string? Copy);

/// <summary>Pure integer patch budget, Voice Lab §8.2.</summary>
public static class VoiceLabPatchBudget
{
    /// <summary>The exact disabled copy.</summary>
    public const string DisabledCopy = "That's a lot to re-voice. Re-record these sentences instead.";

    /// <summary>Count every voice hunk's new tokens, including re-voiced bridge words, against the whole transcript.</summary>
    public static VoiceLabPatchBudgetResult Evaluate(VoiceLabWordDiffResult diff, IReadOnlyList<TimedWord> transcript)
    {
        int count = diff.Hunks.Where(hunk => hunk.Kind == VoiceLabDiffHunkKind.Voice).Sum(hunk => hunk.NewTokens.Count);
        int wordItems = transcript.Count(word => word.Kind == WordKind.Word);
        bool disabled = (long)count * 100 > 15L * wordItems || count > 60;
        return new(count, wordItems, disabled ? VoiceLabPatchBudgetFlag.ReRecordInstead : VoiceLabPatchBudgetFlag.Allowed,
            disabled ? DisabledCopy : null);
    }
}
