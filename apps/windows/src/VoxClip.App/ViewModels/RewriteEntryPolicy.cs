namespace VoxClip.App.ViewModels;

internal enum RewriteEntry { Selection, Context, InsertWords, Overflow, Shortcut }
internal enum RewriteEntryAction { Unavailable, TurnOnVoiceLab, OpenPassage, OpenInsertion }

internal static class RewriteEntryPolicy
{
#if DEBUG
    internal static bool BuildEnabled => true;
#else
    internal static bool BuildEnabled => false;
#endif
    internal const string EnablementCopy = "Voice Lab can clone your own voice, change your voice and re-voice a few words. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key and, for lip sync, your fal.ai or sync.so key.";

    internal static bool BetweenWords(IReadOnlyList<VoxClip.Core.Domain.Shared.TimedWord> words, int after) =>
        after >= 0 && after + 1 < words.Count && words[after].Kind == VoxClip.Core.Domain.Shared.WordKind.Word &&
        words[after + 1].Kind == VoxClip.Core.Domain.Shared.WordKind.Word;

    internal static RewriteEntryAction Resolve(RewriteEntry entry, bool voiceLab, bool editable, bool selection,
        bool caretBetweenWords, bool internalBuild)
    {
        if (!internalBuild) return RewriteEntryAction.Unavailable;
        if (!voiceLab) return entry == RewriteEntry.Overflow ? RewriteEntryAction.TurnOnVoiceLab : RewriteEntryAction.Unavailable;
        if (!editable) return RewriteEntryAction.Unavailable;
        if (entry == RewriteEntry.InsertWords)
            return caretBetweenWords ? RewriteEntryAction.OpenInsertion : RewriteEntryAction.Unavailable;
        return selection ? RewriteEntryAction.OpenPassage : RewriteEntryAction.Unavailable;
    }
}
