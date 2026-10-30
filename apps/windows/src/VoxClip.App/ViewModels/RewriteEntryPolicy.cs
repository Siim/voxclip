namespace VoxClip.App.ViewModels;

internal enum RewriteEntry { Selection, Context, InsertWords, Overflow, Shortcut }
internal enum RewriteEntryAction { Unavailable, OpenPassage, OpenInsertion }

internal static class RewriteEntryPolicy
{
#if DEBUG
    internal static bool InternalBuild => true;
#else
    internal static bool InternalBuild => false;
#endif
    internal static bool Available(bool enabled, bool betaNoticeAccepted) =>
        VoxClip.Core.Domain.VoiceLab.VoiceLabBeta.IsAvailable(enabled, betaNoticeAccepted, InternalBuild);
    internal static bool BetweenWords(IReadOnlyList<VoxClip.Core.Domain.Shared.TimedWord> words, int after) =>
        after >= 0 && after + 1 < words.Count && words[after].Kind == VoxClip.Core.Domain.Shared.WordKind.Word &&
        words[after + 1].Kind == VoxClip.Core.Domain.Shared.WordKind.Word;

    internal static RewriteEntryAction Resolve(RewriteEntry entry, bool enabled, bool betaNoticeAccepted, bool editable, bool selection,
        bool caretBetweenWords, bool internalBuild)
    {
        if (!VoxClip.Core.Domain.VoiceLab.VoiceLabBeta.IsAvailable(enabled, betaNoticeAccepted, internalBuild) ||
            entry == RewriteEntry.InsertWords) return RewriteEntryAction.Unavailable;
        if (!editable) return RewriteEntryAction.Unavailable;
        return selection ? RewriteEntryAction.OpenPassage : RewriteEntryAction.Unavailable;
    }
}
