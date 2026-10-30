namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The Voice Lab beta predicate; App presentation binds this without weakening Release consent.</summary>
public static class VoiceLabBeta
{
    /// <summary>Internal builds can bypass the beta notice only when compiled with DEBUG.</summary>
    public static bool IsAvailable(bool enabled, bool betaNoticeAccepted, bool internalBuild)
    {
#if DEBUG
        return enabled && (betaNoticeAccepted || internalBuild);
#else
        return enabled && betaNoticeAccepted;
#endif
    }
}
