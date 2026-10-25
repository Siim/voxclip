using System.Text.Json;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Settings;

namespace VoxClip.Core.Services.Speech;

/// <summary>Closed ElevenLabs residency regions; transcription §8.1.</summary>
public enum ElevenLabsRegion
{
    /// <summary>Default ElevenLabs endpoint.</summary>
    Default,
    /// <summary>US endpoint.</summary>
    Us,
    /// <summary>EU residency endpoint.</summary>
    Eu,
    /// <summary>India residency endpoint.</summary>
    In,
    /// <summary>Singapore residency endpoint.</summary>
    Sg
}

/// <summary>Resolve the shared region setting without accepting a host from settings.</summary>
public static class ElevenLabsRegions
{
    /// <summary>Missing means Default; invalid values warn once without echoing stored data.</summary>
    public static ElevenLabsRegion FromSettings(AppSettings settings, ILog? log = null)
    {
        if (!settings.Values.TryGetValue("transcription.elevenlabs.region", out var stored)) return ElevenLabsRegion.Default;
        var region = stored.ValueKind == JsonValueKind.String ? stored.GetString() switch
        {
            "default" => ElevenLabsRegion.Default,
            "us" => ElevenLabsRegion.Us,
            "eu" => ElevenLabsRegion.Eu,
            "in" => ElevenLabsRegion.In,
            "sg" => ElevenLabsRegion.Sg,
            _ => (ElevenLabsRegion?)null
        } : null;
        if (region is { } valid) return valid;
        (log ?? new Log()).Write(LogLevel.Warn, "transcribe", "Unknown ElevenLabs region setting; using Default.");
        return ElevenLabsRegion.Default;
    }

    internal static Uri Origin(this ElevenLabsRegion region) => new(region switch
    {
        ElevenLabsRegion.Default => "https://api.elevenlabs.io",
        ElevenLabsRegion.Us => "https://api.us.elevenlabs.io",
        ElevenLabsRegion.Eu => "https://api.eu.residency.elevenlabs.io",
        ElevenLabsRegion.In => "https://api.in.residency.elevenlabs.io",
        ElevenLabsRegion.Sg => "https://api.sg.residency.elevenlabs.io",
        _ => throw new ArgumentOutOfRangeException(nameof(region))
    });
}
