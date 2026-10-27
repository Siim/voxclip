using System.Text.Json;
using System.Text.Json.Serialization;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Output aspect; architecture §4.1 and project schema $defs/export.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ExportAspect>))]
public enum ExportAspect
{
    /// <summary>Normalized source dimensions.</summary>
    [JsonStringEnumMemberName("source")] Source,
    /// <summary>Landscape.</summary>
    [JsonStringEnumMemberName("16:9")] Landscape,
    /// <summary>Portrait.</summary>
    [JsonStringEnumMemberName("9:16")] Portrait,
    /// <summary>Square.</summary>
    [JsonStringEnumMemberName("1:1")] Square
}

/// <summary>Encoding quality; architecture §4.1.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ExportQuality>))]
public enum ExportQuality
{
    /// <summary>Nominal bitrate.</summary>
    [JsonStringEnumMemberName("standard")] Standard,
    /// <summary>1.5 times nominal bitrate.</summary>
    [JsonStringEnumMemberName("high")] High
}

/// <summary>Runtime frame-rate choice, number or source; architecture §4.1. Never stored in project export choices.</summary>
[JsonConverter(typeof(FrameRateJsonConverter))]
public readonly record struct FrameRate(double? FramesPerSecond)
{
    /// <summary>Preserve the source nominal rate before snapping; architecture §4.1.</summary>
    public static FrameRate Source => new(null);
}

/// <summary>Serializes a runtime source-or-number frame-rate choice without reflection; architecture §4.1.</summary>
public sealed class FrameRateJsonConverter : JsonConverter<FrameRate>
{
    /// <inheritdoc />
    public override FrameRate Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String && reader.GetString() == "source") return FrameRate.Source;
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetDouble(out var value) && double.IsFinite(value) && value > 0 && value <= 120) return new(value);
        throw new JsonException("Expected source or a positive frame rate at most 120.");
    }
    /// <inheritdoc />
    public override void Write(Utf8JsonWriter writer, FrameRate value, JsonSerializerOptions options)
    {
        if (value.FramesPerSecond is { } rate)
        {
            if (!double.IsFinite(rate) || rate <= 0 || rate > 120) throw new JsonException("Invalid frame rate.");
            writer.WriteNumberValue(rate);
        }
        else writer.WriteStringValue("source");
    }
}

/// <summary>Resolved runtime output preset; architecture §4.1. Not a persisted project object.</summary>
public sealed record ExportPreset(string Id, string Name, ExportAspect Aspect, int Width, int Height,
    FrameRate FrameRate, string VideoCodec, long VideoBitrate, long AudioBitrate, ReframeSettings Reframe, bool BurnCaptions);

/// <summary>M1 runtime centre-crop configuration; architecture §4.1.</summary>
public sealed record ReframeSettings(string Mode = "center", double Zoom = 1);

/// <summary>Pure output-size and bitrate rules; architecture §4.1.</summary>
public static class ExportPresets
{
    /// <summary>Canonical encoder settings shared by snapshot capture, export and its fingerprint.</summary>
    public static OutputSpec Output(PixelSize source, double sourceRate, ExportAspect aspect, ExportQuality quality, string codec = "h264")
    {
        var size = OutputSize(source, aspect);
        var fps = OutputFrameRate(sourceRate);
        return new(size, fps, VideoBitrate(size, aspect, quality, fps), 48_000, 2, 160_000, codec);
    }
    /// <summary>Returns even output dimensions, capped at 1920 for source aspect.</summary>
    public static PixelSize OutputSize(PixelSize source, ExportAspect aspect)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(source.Width);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(source.Height);
        var scale = Math.Min(1, 1920.0 / Math.Max(source.Width, source.Height));
        return aspect switch
        {
            ExportAspect.Landscape => new(1920, 1080), ExportAspect.Portrait => new(1080, 1920), ExportAspect.Square => new(1080, 1080),
            _ => new(Math.Max(2, (int)Math.Floor(source.Width * scale / 2 + 0.5) * 2), Math.Max(2, (int)Math.Floor(source.Height * scale / 2 + 0.5) * 2))
        };
    }
    /// <summary>Nearest supported rate; ties choose the lower rate, capped at 60.</summary>
    public static double OutputFrameRate(double sourceRate) => new double[] { 24, 25, 30, 50, 60 }.MinBy(rate => Math.Abs(rate - sourceRate));
    /// <summary>H.264 bitrate in bits/second, including quality and high-frame-rate multipliers.</summary>
    public static long VideoBitrate(PixelSize size, ExportAspect aspect, ExportQuality quality, double fps)
    {
        var bitrate = aspect == ExportAspect.Square ? 6_000_000.0 : aspect == ExportAspect.Source ? Math.Max(2_000_000, 8_000_000.0 * size.Width * size.Height / (1920 * 1080)) : 8_000_000;
        return (long)Math.Floor(bitrate * (quality == ExportQuality.High ? 1.5 : 1) * (fps >= 50 ? 1.5 : 1) + 0.5);
    }
    /// <summary>Centre-crop rectangle in oriented source pixels.</summary>
    public static RectD CenterCrop(PixelSize source, PixelSize output)
    {
        var aspect = (double)output.Width / output.Height;
        var height = Math.Min(source.Height, source.Width / aspect);
        var width = height * aspect;
        return new((source.Width - width) / 2, (source.Height - height) / 2, width, height);
    }
}
