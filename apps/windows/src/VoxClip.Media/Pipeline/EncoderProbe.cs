using System.Text.Json;
using System.Text.Json.Serialization;
using FFmpeg.AutoGen;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Ffmpeg;

namespace VoxClip.Media.Pipeline;

/// <summary>LGPL-safe encoder discovery and adapter-keyed cache; architecture §6.6.</summary>
public sealed class EncoderProbe : IEncoderProbe
{
    private const int ConfigurationRevision = 2;
    private readonly Func<EncoderCacheKey, EncoderCacheKey> identify;
    private readonly Func<string, CancellationToken, EncoderInfo> probeEncoder;
    private readonly Func<string> cachePath;
    /// <summary>Probe only through the first success, with an adapter/driver/build-keyed cache.</summary>
    public EncoderProbe() : this(Identify, ProbeEncoder, () => Path.Combine(DataLocations.Resolve().Cache, "encoders.json")) { }
    internal EncoderProbe(Func<EncoderCacheKey, EncoderCacheKey> identify, Func<string, CancellationToken, EncoderInfo> probeEncoder, Func<string> cachePath)
    { this.identify = identify; this.probeEncoder = probeEncoder; this.cachePath = cachePath; }
    /// <summary>Ordered LGPL-safe ladder, with no GPL software fallback.</summary>
    public static IReadOnlyList<string> Ladder { get; } = Array.AsReadOnly(new[] { "h264_nvenc", "h264_qsv", "h264_amf", "h264_mf", SoftwareMediaFoundation });
    /// <summary>Distinct probe/cache identity for the OS software MFT, not a different FFmpeg codec.</summary>
    public const string SoftwareMediaFoundation = "h264_mf (software)";
    /// <inheritdoc />
    public Task<IReadOnlyList<EncoderInfo>> ProbeAsync(EncoderCacheKey key, IProgress<MediaProgress>? progress, CancellationToken ct)
        => MediaThread.Run<IReadOnlyList<EncoderInfo>>("vc-encoder-probe", () => Probe(key, ct), ct);

    private static unsafe EncoderCacheKey Identify(EncoderCacheKey key)
    {
        FfmpegLoader.InitializeAsync(CancellationToken.None).GetAwaiter().GetResult();
        return key with { FfmpegVersion = ffmpeg.av_version_info() };
    }

    internal Task<IReadOnlyList<EncoderInfo>> ProbeRemainingAsync(EncoderCacheKey key, IReadOnlySet<string> failed, CancellationToken ct)
        => MediaThread.Run<IReadOnlyList<EncoderInfo>>("vc-encoder-probe", () => Probe(key, ct, failed), ct);

    private IReadOnlyList<EncoderInfo> Probe(EncoderCacheKey key, CancellationToken ct, IReadOnlySet<string>? failed = null)
    {
        ct.ThrowIfCancellationRequested();
        var path = cachePath();
        var actualKey = identify(key);
        var results = new List<EncoderInfo>();
        try
        {
            var cache = JsonSerializer.Deserialize(File.ReadAllText(path), EncoderCacheJson.Default.EncoderCacheDocument);
            if (actualKey.AdapterLuid != "unknown" && cache?.ConfigurationRevision == ConfigurationRevision && cache.Key == actualKey && cache.Encoders is { } entries && entries.Length <= Ladder.Count &&
                entries.Any(encoder => encoder?.Available == true) &&
                entries.All(encoder => encoder is not null) && Ladder.Take(entries.Length).SequenceEqual(entries.Select(encoder => encoder.Name)))
                results.AddRange(entries);
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
        for (var index = 0; index < results.Count; index++)
            if (failed?.Contains(results[index].Name) == true) results[index] = results[index] with { Available = false };
        if (results.Any(encoder => encoder.Available)) return results;
        foreach (var name in Ladder.Skip(results.Count))
        {
            ct.ThrowIfCancellationRequested();
            if (failed?.Contains(name) == true) { results.Add(new(name, false, "The encoder failed during this export.")); continue; }
            try
            {
                var result = probeEncoder(name, ct);
                results.Add(result);
                if (result.Available) break;
            }
            catch (VoxClipException exception) when (exception.Code is not (VoxClipErrorCode.FfmpegLicenceGate or VoxClipErrorCode.SharedResourcesMissing))
            { results.Add(new(name, false, exception.Message)); }
        }
        Save(path, new(actualKey, results.ToArray()) { ConfigurationRevision = ConfigurationRevision });
        return results;
    }

    private static unsafe EncoderInfo ProbeEncoder(string name, CancellationToken ct)
    {
        using var encoder = new EncoderSession(name, new(new(1280, 720), 30, 4_000_000));
        using var frameHandle = NativeHandle.Own(Native.Frame(AVPixelFormat.AV_PIX_FMT_NV12, 1280, 720), NativeKind.Frame);
        var frame = (AVFrame*)frameHandle.Pointer;
        for (var row = 0; row < 720; row++) new Span<byte>(frame->data[0] + row * frame->linesize[0], 1280).Fill(16);
        for (var row = 0; row < 360; row++) new Span<byte>(frame->data[1] + row * frame->linesize[1], 1280).Fill(128);
        var packets = 0;
        for (var index = 0; index < 3; index++)
        { frame->pts = index; frame->duration = 1; encoder.Send(frame, packet => packets++, ct); }
        encoder.Send(null, packet => packets++, ct);
        return new(name, packets > 0, packets == 0 ? "The encoder returned no packets." : null);
    }

    internal static void Save(string path, EncoderCacheDocument document)
    {
        if (document.Key.AdapterLuid == "unknown" || !document.Encoders.Any(encoder => encoder.Available)) return;
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(temporary, JsonSerializer.Serialize(document, EncoderCacheJson.Default.EncoderCacheDocument));
            File.Move(temporary, path, true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        finally { try { File.Delete(temporary); } catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { } }
    }

    internal static void RecordFailure(EncoderCacheKey key, string name, string? cachePath = null)
    {
        var path = cachePath ?? Path.Combine(DataLocations.Resolve().Cache, "encoders.json");
        try
        {
            var cached = JsonSerializer.Deserialize(File.ReadAllText(path), EncoderCacheJson.Default.EncoderCacheDocument);
            if (cached?.Key is null || cached.Encoders is null || cached.Key.AdapterLuid != key.AdapterLuid || cached.Key.DriverVersion != key.DriverVersion) return;
            var remaining = cached.Encoders.Select(encoder => encoder.Name == name ? encoder with
                { Available = false, Reason = "The encoder failed during export; trying the next encoder." } : encoder).ToArray();
            if (remaining.Any(encoder => encoder.Available)) Save(path, cached with { Encoders = remaining });
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
    }
}

internal sealed record EncoderCacheDocument(EncoderCacheKey Key, EncoderInfo[] Encoders)
{
    public int ConfigurationRevision { get; init; }
}
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(EncoderCacheDocument))]
internal partial class EncoderCacheJson : JsonSerializerContext;
