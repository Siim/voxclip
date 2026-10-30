namespace VoxClip.App.ViewModels;

internal enum RewriteEntry { Selection, Context, InsertWords, Overflow, Shortcut }
internal enum RewriteEntryAction { Unavailable, OpenPassage, OpenInsertion }

internal static class RewriteEntryPolicy
{
    /// <summary>Development builds (VOXCLIP_DEVELOPMENT: Debug, or -p:VoxClipDevelopmentBuild=true) skip the beta notice and read unset
    /// Voice Lab settings as on. Release pipelines never define it.</summary>
#if VOXCLIP_DEVELOPMENT
    internal static bool InternalBuild => true;
#else
    internal static bool InternalBuild => false;
#endif
    /// <summary>Self-checks, demo captures and native probes keep the shipped Voice Lab default, like the Mac's test sessions. Their
    /// scripts seed any Voice Lab state they need. The demo and probe options exist only in DEBUG (App.OnLaunched), so only DEBUG
    /// lists them; a Release assembly never carries their names.</summary>
    internal static bool HarnessLaunch(IReadOnlyList<string> arguments) => arguments.Any(argument => argument is "--self-check"
        or "--transcript-frame-probe"
#if DEBUG
        or "--demo-project" or "--demo-screen" or "--capture-fixture" or "--screen" or "--voice-lab-probe" or "--shell-route-probe"
        or "--restart-probe" or "--shell-probe"
#endif
        );
    /// <summary>Whether this launch reads unset Voice Lab settings as on: a development build outside the harness.</summary>
    internal static bool DevelopmentDefaults(IReadOnlyList<string> arguments) => InternalBuild && !HarnessLaunch(arguments);
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
