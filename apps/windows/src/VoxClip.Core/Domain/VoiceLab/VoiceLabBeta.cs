using System.Collections.ObjectModel;
using System.Text.Json;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The Voice Lab beta predicate; App presentation binds this without weakening Release consent.</summary>
public static class VoiceLabBeta
{
    private static readonly IReadOnlyDictionary<string, JsonElement> None = new ReadOnlyDictionary<string, JsonElement>(new Dictionary<string, JsonElement>());

    /// <summary>Internal builds can bypass the beta notice only when compiled as a development build (VOXCLIP_DEVELOPMENT, which
    /// Debug defines by default).</summary>
    public static bool IsAvailable(bool enabled, bool betaNoticeAccepted, bool internalBuild)
    {
#if VOXCLIP_DEVELOPMENT
        return enabled && (betaNoticeAccepted || internalBuild);
#else
        return enabled && betaNoticeAccepted;
#endif
    }

    /// <summary>Values a development build reads for the switch and the beta notice while the settings file leaves them unset. They are
    /// never saved, and an explicit value always wins. A build without VOXCLIP_DEVELOPMENT gets none (Voice Lab §5).</summary>
    public static IReadOnlyDictionary<string, JsonElement> DevelopmentDefaults(bool internalBuild)
    {
#if VOXCLIP_DEVELOPMENT
        if (internalBuild)
        {
            using var document = JsonDocument.Parse("""{"voiceLab.enabled":true,"voiceLab.betaNoticeAccepted":true}""");
            return new ReadOnlyDictionary<string, JsonElement>(document.RootElement.EnumerateObject()
                .ToDictionary(property => property.Name, property => property.Value.Clone(), StringComparer.Ordinal));
        }
#endif
        return None;
    }
}
