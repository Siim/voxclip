using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Settings;

namespace VoxClip.Core.Services.Speech;

/// <summary>Closed ElevenLabs residency regions; transcription §8.1.</summary>
[JsonConverter(typeof(ElevenLabsRegionJsonConverter))]
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

/// <summary>Exact settings raw values on write, with legacy numeric regions accepted only on read.</summary>
public sealed class ElevenLabsRegionJsonConverter : JsonConverter<ElevenLabsRegion>
{
    /// <inheritdoc />
    public override ElevenLabsRegion Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetInt32(out var numeric) && numeric is >= 0 and <= 4)
            return (ElevenLabsRegion)numeric;
        if (reader.TokenType != JsonTokenType.String) throw new JsonException("Invalid ElevenLabs region");
        return reader.GetString() switch
        {
            "default" => ElevenLabsRegion.Default,
            "us" => ElevenLabsRegion.Us,
            "eu" => ElevenLabsRegion.Eu,
            "in" => ElevenLabsRegion.In,
            "sg" => ElevenLabsRegion.Sg,
            _ => throw new JsonException("Invalid ElevenLabs region")
        };
    }

    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, ElevenLabsRegion value, JsonSerializerOptions options) => writer.WriteStringValue(value switch
    {
        ElevenLabsRegion.Default => "default",
        ElevenLabsRegion.Us => "us",
        ElevenLabsRegion.Eu => "eu",
        ElevenLabsRegion.In => "in",
        ElevenLabsRegion.Sg => "sg",
        _ => throw new JsonException("Invalid ElevenLabs region")
    });
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

    /// <summary>Data-residency hosts serve separate Enterprise workspaces with their own keys.</summary>
    public static bool IsResidency(this ElevenLabsRegion region) => region is ElevenLabsRegion.Eu or ElevenLabsRegion.In or ElevenLabsRegion.Sg;

    /// <summary>Appended to a 400, 401 or key error from a residency host; empty elsewhere.</summary>
    public static string ResidencyHint(this ElevenLabsRegion region) =>
        region.IsResidency() ? $"ElevenLabs {region.ToString().ToUpperInvariant()} residency needs a key from a data-residency workspace; most accounts use Region: Default" : "";

    /// <summary>The fixed HTTPS origin for display and all ElevenLabs calls; transcription §8.1.</summary>
    public static Uri BaseUri(this ElevenLabsRegion region) => new(region switch
    {
        ElevenLabsRegion.Default => "https://api.elevenlabs.io",
        ElevenLabsRegion.Us => "https://api.us.elevenlabs.io",
        ElevenLabsRegion.Eu => "https://api.eu.residency.elevenlabs.io",
        ElevenLabsRegion.In => "https://api.in.residency.elevenlabs.io",
        ElevenLabsRegion.Sg => "https://api.sg.residency.elevenlabs.io",
        _ => throw new ArgumentOutOfRangeException(nameof(region))
    });
}
