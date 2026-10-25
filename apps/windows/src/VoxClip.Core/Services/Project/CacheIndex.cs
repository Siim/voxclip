using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Services.Project;

/// <summary>Native-rate envelope metadata in architecture §8.2 meta.json.</summary>
public sealed record CacheEnvelope(int SampleRate, double FrameSeconds, int Count);

/// <summary>Recomputable cache metadata, never stored in the project, architecture §8.2.</summary>
public sealed record CacheEntry(string Schema, string ContentKey, DateTimeOffset CreatedAt, DateTimeOffset LastAccessAt, long Bytes, CacheEnvelope? Envelope);

/// <summary>Atomic cache metadata and protected LRU eviction, architecture §8.2.</summary>
public sealed class CacheIndex
{
    private readonly string root;
    private readonly SemaphoreSlim gate = new(1, 1);

    /// <summary>Use the data root's Cache folder unless a separate root is supplied.</summary>
    public CacheIndex(string? root = null) => this.root = Path.GetFullPath(root ?? DataLocations.Resolve().Cache);

    /// <summary>Read valid source entries; missing or corrupt metadata is a cache miss.</summary>
    public async Task<IReadOnlyList<CacheEntry>> ReadAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!Directory.Exists(root)) return [];
        var result = new List<CacheEntry>();
        foreach (var directory in Directory.EnumerateDirectories(root).Order(StringComparer.Ordinal))
        {
            ct.ThrowIfCancellationRequested();
            var key = Path.GetFileName(directory);
            if (!ValidKey(key)) continue;
            try
            {
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) continue;
                var entry = JsonSerializer.Deserialize(await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), ct).ConfigureAwait(false), CacheJsonContext.Default.CacheEntry);
                if (entry is not null && entry.Schema == "voxclip-cache/1" && entry.ContentKey == key && entry.Bytes >= 0 && (entry.Envelope is null || entry.Envelope is { SampleRate: > 0, FrameSeconds: 0.01, Count: >= 0 })) result.Add(entry);
            }
            catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { }
        }
        return result;
    }

    /// <summary>Record size and access time atomically, preserving creation time.</summary>
    public async Task TouchAsync(string contentKey, long bytes, CacheEnvelope? envelope, CancellationToken ct)
    {
        if (!ValidKey(contentKey) || bytes < 0 || envelope is not null && envelope is not { SampleRate: > 0, FrameSeconds: 0.01, Count: >= 0 }) throw new ArgumentException("Invalid cache entry.");
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var directory = Path.Combine(root, contentKey);
            if (Directory.Exists(directory) && (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Cache entries cannot be symbolic links.");
            var existing = (await ReadAsync(ct).ConfigureAwait(false)).FirstOrDefault(entry => entry.ContentKey == contentKey);
            var now = DateTimeOffset.UtcNow;
            var entry = new CacheEntry("voxclip-cache/1", contentKey, existing?.CreatedAt ?? now, now, bytes, envelope ?? existing?.Envelope);
            await AtomicFile.WriteAsync(Path.Combine(root, contentKey, "meta.json"), JsonSerializer.Serialize(entry, CacheJsonContext.Default.CacheEntry) + "\n", ct).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }

    /// <summary>Evict LRU directories until under the cap, never deleting an in-use key.</summary>
    public async Task<IReadOnlyList<string>> EvictAsync(long limitBytes, IReadOnlySet<string> inUseKeys, CancellationToken ct)
    {
        if (limitBytes < 0) throw new ArgumentOutOfRangeException(nameof(limitBytes));
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var metadata = (await ReadAsync(ct).ConfigureAwait(false)).ToDictionary(entry => entry.ContentKey, StringComparer.Ordinal);
            var entries = new List<EvictionEntry>();
            if (!Directory.Exists(root)) return [];
            foreach (var directory in Directory.EnumerateDirectories(root))
            {
                ct.ThrowIfCancellationRequested();
                var key = Path.GetFileName(directory);
                if (!ValidKey(key)) continue;
                try
                {
                    if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) continue;
                    var measured = Measure(directory, ct);
                    metadata.TryGetValue(key, out var entry);
                    entries.Add(new(key, entry?.LastAccessAt ?? DateTimeOffset.MinValue,
                        UInt128.Max(measured.Bytes, (UInt128)(ulong)(entry?.Bytes ?? 0)),
                        entry is not null || measured.LatestWrite < DateTime.UtcNow.AddHours(-1)));
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
            var total = entries.Aggregate((UInt128)0, (sum, entry) => sum + entry.Bytes);
            var removed = new List<string>();
            foreach (var entry in entries.OrderBy(entry => entry.LastAccessAt).ThenBy(entry => entry.ContentKey, StringComparer.Ordinal))
            {
                ct.ThrowIfCancellationRequested();
                if (!entry.Eligible || inUseKeys.Contains(entry.ContentKey) || total <= (ulong)limitBytes) continue;
                try
                {
                    Directory.Delete(Path.Combine(root, entry.ContentKey), true);
                    total -= entry.Bytes;
                    removed.Add(entry.ContentKey);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
            return removed;
        }
        finally { gate.Release(); }
    }

    private sealed record EvictionEntry(string ContentKey, DateTimeOffset LastAccessAt, UInt128 Bytes, bool Eligible);

    private static (UInt128 Bytes, DateTime LatestWrite) Measure(string directory, CancellationToken ct)
    {
        UInt128 bytes = 0;
        var latest = Directory.GetLastWriteTimeUtc(directory);
        var pending = new Stack<string>();
        pending.Push(directory);
        while (pending.TryPop(out var current))
            foreach (var entry in new DirectoryInfo(current).EnumerateFileSystemInfos())
            {
                ct.ThrowIfCancellationRequested();
                if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                if (entry.LastWriteTimeUtc > latest) latest = entry.LastWriteTimeUtc;
                if (entry is DirectoryInfo) pending.Push(entry.FullName);
                else if (entry is FileInfo file) bytes += (ulong)file.Length;
            }
        return (bytes, latest);
    }

    private static bool ValidKey(string key) => key.Length == 64 && key.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');
}

[JsonSourceGenerationOptions(NewLine = JsonFormatting.NewLine, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true,
    RespectRequiredConstructorParameters = true, Converters = new[] { typeof(UtcTimestampConverter) })]
[JsonSerializable(typeof(CacheEntry))]
internal partial class CacheJsonContext : JsonSerializerContext;
