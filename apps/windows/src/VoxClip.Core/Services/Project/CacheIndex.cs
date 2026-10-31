using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Media;

namespace VoxClip.Core.Services.Project;

/// <summary>Native-rate envelope metadata in architecture §8.2 meta.json.</summary>
public sealed record CacheEnvelope(int SampleRate, double FrameSeconds, int Count);

/// <summary>Recomputable cache metadata, never stored in the project, architecture §8.2.</summary>
public sealed record CacheEntry(string Schema, string ContentKey, DateTimeOffset CreatedAt, DateTimeOffset LastAccessAt, long Bytes, CacheEnvelope? Envelope);

/// <summary>Atomic cache metadata and protected LRU eviction, architecture §8.2.</summary>
public sealed class CacheIndex
{
    private const string EnvelopeFile = "envelope-10ms.f32";
    private const string TranscriptsFolder = "transcripts";
    // Files earlier builds left at the cache root instead of a source's entry, removed on sight (architecture §8.2): the
    // extraction products, Apple speech's CAF copies and the temporaries of interrupted writes on either platform.
    private static readonly string[] LegacyRootNames = ["audio-16k.wav", EnvelopeFile, "meta.json"];
    private static readonly (string Prefix, string Suffix)[] LegacyRootShapes =
        [("apple-", ".caf"), ("audio-16k-", ".partial"), ("audio-16k.wav.", ".partial"), ("envelope-", ".partial"), ("meta.json.", ".partial")];
    private readonly string root;
    private readonly TimeProvider clock;
    private readonly SemaphoreSlim gate = new(1, 1);

    /// <summary>Use the data root's Cache folder unless a separate root is supplied. <paramref name="time"/> is the clock
    /// for <c>lastAccessAt</c> and the one-hour rule of <see cref="EvictAsync(long, IReadOnlySet{string}, bool, CancellationToken)"/>;
    /// tests inject one.</summary>
    public CacheIndex(string? root = null, TimeProvider? time = null)
    {
        this.root = Path.GetFullPath(root ?? DataLocations.Resolve().Cache);
        clock = time ?? TimeProvider.System;
    }

    /// <summary>The keys in use in this cache folder, shared with every other index of the folder (architecture §8.2).</summary>
    public CacheKeyRegistry Keys => CacheKeyRegistry.Shared(root);

    /// <summary>The source's own entry, Cache/&lt;contentKey&gt;; only a lowercase SHA-256 key names one (architecture §8.2).</summary>
    public string EntryDirectory(string contentKey)
        => ValidKey(contentKey) ? Path.Combine(root, contentKey) : throw new ArgumentException("Invalid cache key.", nameof(contentKey));

    /// <summary>Extract transcription audio into the source's own entry, so no two sources share audio-16k.wav or
    /// envelope-10ms.f32, then record the entry in this index's meta.json format: the existing CreatedAt, LastAccessAt now,
    /// the measured bytes and the envelope (architecture §8.2). Removes the files earlier builds left at the cache root.
    /// The key is leased throughout, and an existing entry is marked used as the extraction starts, so it sorts as the most
    /// recently used. That is only an order: while the CLI extracts, the app's passes spare the entry for its *.partial
    /// temporary, or for missing metadata.</summary>
    public async Task<AudioExtractionResult> ExtractAudioAsync(IAudioExtractor extractor, MediaInfo media, string contentKey,
        IProgress<MediaProgress>? progress, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(extractor);
        var directory = EntryDirectory(contentKey);
        // Eviction never touches an entry while it is written (architecture §8.2).
        using var lease = await Keys.LeaseAsync(contentKey, ct).ConfigureAwait(false);
        // An entry is a real folder or nothing yet: never extract through a link (architecture §8.2).
        var existing = new DirectoryInfo(directory);
        if (existing.LinkTarget is not null || (existing.Exists ? (existing.Attributes & FileAttributes.ReparsePoint) != 0 : File.Exists(directory)))
            throw new IOException("Cache entries cannot be symbolic links.");
        RemoveLegacyRootFiles();
        var createdAt = (await MarkEntryUsedAsync(directory, contentKey, ct).ConfigureAwait(false))?.CreatedAt;
        var result = await extractor.ExtractAsync(new(media, contentKey, directory), progress, ct).ConfigureAwait(false);
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var now = clock.GetUtcNow();
            var entry = new CacheEntry("voxclip-cache/1", contentKey, createdAt ?? now, now, DataBytes(directory, ct),
                new CacheEnvelope(result.Envelope.SampleRate, 0.01, result.Envelope.Rms.Count));
            await AtomicFile.WriteAsync(Path.Combine(directory, "meta.json"), JsonSerializer.Serialize(entry, CacheJsonContext.Default.CacheEntry) + "\n", ct).ConfigureAwait(false);
        }
        finally { gate.Release(); }
        return result;
    }

    /// <summary>Delete the regular files at the cache root that earlier builds left there: audio-16k.wav, envelope-10ms.f32,
    /// meta.json, apple-*.caf and the *.partial temporaries of audio, envelope and metadata writes. Never links, folders or
    /// anything inside an entry.</summary>
    public void RemoveLegacyRootFiles()
    {
        try
        {
            if (!Directory.Exists(root)) return;
            foreach (var file in new DirectoryInfo(root).EnumerateFiles())
            {
                if (!IsLegacyRootFile(file.Name) || (file.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                try { file.Delete(); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    internal static bool IsLegacyRootFile(string name)
        => LegacyRootNames.Contains(name) || LegacyRootShapes.Any(shape => name.Length > shape.Prefix.Length + shape.Suffix.Length
            && name.StartsWith(shape.Prefix, StringComparison.Ordinal) && name.EndsWith(shape.Suffix, StringComparison.Ordinal));

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
            if (ValidKey(key) && await ReadEntryAsync(directory, key, ct).ConfigureAwait(false) is { } entry) result.Add(entry);
        }
        return result;
    }

    // One entry's metadata, or null when it is missing, corrupt or behind a link.
    private static async Task<CacheEntry?> ReadEntryAsync(string directory, string key, CancellationToken ct)
    {
        try
        {
            if (!Directory.Exists(directory) || (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) return null;
            var entry = JsonSerializer.Deserialize(await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), ct).ConfigureAwait(false), CacheJsonContext.Default.CacheEntry);
            return entry is not null && entry.Schema == "voxclip-cache/1" && entry.ContentKey == key && entry.Bytes >= 0
                && (entry.Envelope is null || entry.Envelope is { SampleRate: > 0, FrameSeconds: 0.01, Count: >= 0 }) ? entry : null;
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>Marks an existing entry used now, as an editor opens its project, so least-recently-used eviction goes by
    /// when it was last used rather than when it was extracted (architecture §8.2), as the Mac's <c>CacheStore.touch</c>.
    /// It waits while eviction is working on that entry. An entry without readable metadata, or with an invalid key, is left
    /// as it is.</summary>
    public async Task MarkUsedAsync(string contentKey, CancellationToken ct)
    {
        if (!ValidKey(contentKey)) return;
        using var lease = await Keys.LeaseAsync(contentKey, ct).ConfigureAwait(false);
        await MarkEntryUsedAsync(Path.Combine(root, contentKey), contentKey, ct).ConfigureAwait(false);
    }

    // Rewrites a readable entry's lastAccessAt under the gate and returns the entry as it was; null when there is none.
    private async Task<CacheEntry?> MarkEntryUsedAsync(string directory, string key, CancellationToken ct)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (await ReadEntryAsync(directory, key, ct).ConfigureAwait(false) is not { } entry) return null;
            try
            {
                await AtomicFile.WriteAsync(Path.Combine(directory, "meta.json"), JsonSerializer.Serialize(
                    entry with { LastAccessAt = clock.GetUtcNow() }, CacheJsonContext.Default.CacheEntry) + "\n", ct).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            return entry;
        }
        finally { gate.Release(); }
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
            var now = clock.GetUtcNow();
            var entry = new CacheEntry("voxclip-cache/1", contentKey, existing?.CreatedAt ?? now, now, bytes, envelope ?? existing?.Envelope);
            await AtomicFile.WriteAsync(Path.Combine(root, contentKey, "meta.json"), JsonSerializer.Serialize(entry, CacheJsonContext.Default.CacheEntry) + "\n", ct).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }

    /// <summary>Evict LRU entries until under the cap, never touching an in-use key (architecture §8.2). Entries first lose
    /// what can be made again (audio, thumbnails, faces) and keep their waveform envelope, raw transcripts and meta.json; an
    /// entry left with neither an envelope nor transcripts goes whole. Only then do whole entries go. Returns the keys whose
    /// entries were removed.</summary>
    public Task<IReadOnlyList<string>> EvictAsync(long limitBytes, IReadOnlySet<string> inUseKeys, CancellationToken ct)
        => EvictAsync(limitBytes, inUseKeys, false, ct);

    /// <summary>As the overload above, but with keepEnvelopes it stops after the first pass: "Clear cache" keeps envelopes and
    /// raw transcripts, "Clear everything" does not.
    /// <para>An entry whose key is leased in <see cref="Keys"/> or listed in <paramref name="inUseKeys"/> is never touched; it
    /// still counts towards the limit. An entry whose meta.json is missing or unreadable sorts as the least recently used,
    /// but is left alone, and counted, until an hour after anything in it was last written, and so is any entry holding a
    /// *.partial temporary written in the last hour, because either may be an extraction under way in the CLI, which holds
    /// no lease here. Passes for one cache folder run one at a time, in arrival order,
    /// whichever index runs them. Only 64-hex entry folders are evicted; the cache root keeps everything but the legacy
    /// root files (<see cref="RemoveLegacyRootFiles"/>).</para></summary>
    public async Task<IReadOnlyList<string>> EvictAsync(long limitBytes, IReadOnlySet<string> inUseKeys, bool keepEnvelopes, CancellationToken ct)
    {
        if (limitBytes < 0) throw new ArgumentOutOfRangeException(nameof(limitBytes));
        ArgumentNullException.ThrowIfNull(inUseKeys);
        var keys = Keys;
        await keys.BeginEvictionAsync(ct).ConfigureAwait(false);
        try
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            try { return await EvictUnderTurnAsync((ulong)limitBytes, inUseKeys, keepEnvelopes, keys, ct).ConfigureAwait(false); }
            finally { gate.Release(); }
        }
        finally { keys.EndEviction(); }
    }

    private async Task<IReadOnlyList<string>> EvictUnderTurnAsync(ulong limit, IReadOnlySet<string> inUseKeys, bool keepEnvelopes,
        CacheKeyRegistry keys, CancellationToken ct)
    {
        RemoveLegacyRootFiles();
        var metadata = (await ReadAsync(ct).ConfigureAwait(false)).ToDictionary(entry => entry.ContentKey, StringComparer.Ordinal);
        var entries = new List<EvictionEntry>();
        if (!Directory.Exists(root)) return [];
        var unindexedCutoff = clock.GetUtcNow().UtcDateTime - UnindexedGrace;
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
                    entry is not null || measured.LatestWrite < unindexedCutoff));
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
        var total = entries.Aggregate((UInt128)0, (sum, entry) => sum + entry.Bytes);
        var removed = new List<string>();
        var ordered = entries.OrderBy(entry => entry.LastAccessAt).ThenBy(entry => entry.ContentKey, StringComparer.Ordinal).ToArray();
        var sizes = ordered.Select(entry => entry.Bytes).ToArray();
        for (var index = 0; index < ordered.Length; index++)
        {
            ct.ThrowIfCancellationRequested();
            var entry = ordered[index];
            if (!entry.Eligible || total <= limit || !keys.TryClaim(entry.ContentKey, inUseKeys)) continue;
            var directory = Path.Combine(root, entry.ContentKey);
            try
            {
                if (HoldsPartial(directory, unindexedCutoff)) continue;
                var written = Directory.GetLastWriteTimeUtc(directory);
                foreach (var item in new DirectoryInfo(directory).EnumerateFileSystemInfos())
                {
                    if (item.Name is EnvelopeFile or TranscriptsFolder or "meta.json") continue;
                    if (item is DirectoryInfo folder && (folder.Attributes & FileAttributes.ReparsePoint) == 0) folder.Delete(true);
                    else item.Delete();
                }
                if (!HoldsKeptData(directory))
                {
                    Directory.Delete(directory, true);
                    total -= sizes[index];
                    removed.Add(entry.ContentKey);
                    continue;
                }
                if (metadata.TryGetValue(entry.ContentKey, out var meta))
                    await AtomicFile.WriteAsync(Path.Combine(directory, "meta.json"), JsonSerializer.Serialize(
                        meta with { Bytes = DataBytes(directory, ct) }, CacheJsonContext.Default.CacheEntry) + "\n", ct).ConfigureAwait(false);
                else Directory.SetLastWriteTimeUtc(directory, written); // stripping must not make an entry without metadata look fresh
                var left = Measure(directory, ct).Bytes;
                total -= sizes[index] - left;
                sizes[index] = left;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            finally { keys.EndClaim(); }
        }
        if (keepEnvelopes) return removed;
        for (var index = 0; index < ordered.Length; index++)
        {
            ct.ThrowIfCancellationRequested();
            var entry = ordered[index];
            if (!entry.Eligible || removed.Contains(entry.ContentKey) || total <= limit || !keys.TryClaim(entry.ContentKey, inUseKeys)) continue;
            try
            {
                var directory = Path.Combine(root, entry.ContentKey);
                if (HoldsPartial(directory, unindexedCutoff)) continue;
                Directory.Delete(directory, true);
                total -= sizes[index];
                removed.Add(entry.ContentKey);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            finally { keys.EndClaim(); }
        }
        return removed;
    }

    /// <summary>How long every pass leaves an entry without readable metadata, or one holding a *.partial temporary, alone after
    /// that last write (architecture §8.2).</summary>
    internal static TimeSpan UnindexedGrace { get; } = TimeSpan.FromHours(1);

    private sealed record EvictionEntry(string ContentKey, DateTimeOffset LastAccessAt, UInt128 Bytes, bool Eligible);

    private static readonly EnumerationOptions PartialSearch = new()
    {
        RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint, MatchType = MatchType.Simple, IgnoreInaccessible = true,
    };

    // Whether an entry holds a *.partial temporary written at or after the cutoff: a write under way, such as a CLI extraction
    // into an entry that already has metadata, as when it re-extracts audio a pass stripped. Checked once the entry is claimed,
    // just before it would be stripped or removed. Links are not followed.
    private static bool HoldsPartial(string directory, DateTime cutoff)
        => new DirectoryInfo(directory).EnumerateFiles("*.partial", PartialSearch).Any(file => file.LastWriteTimeUtc >= cutoff);

    // Whether a stripped entry still holds its envelope or any raw transcript.
    private static bool HoldsKeptData(string directory)
    {
        var transcripts = Path.Combine(directory, TranscriptsFolder);
        return File.Exists(Path.Combine(directory, EnvelopeFile)) || Directory.Exists(transcripts) && Directory.EnumerateFileSystemEntries(transcripts).Any();
    }

    // Bytes of an entry's data: everything but its meta.json.
    private static long DataBytes(string directory, CancellationToken ct)
    {
        var meta = new FileInfo(Path.Combine(directory, "meta.json"));
        var bytes = Measure(directory, ct).Bytes - (meta.Exists ? (ulong)meta.Length : 0UL);
        return bytes > long.MaxValue ? long.MaxValue : (long)bytes;
    }

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

/// <summary>Cache timestamps: written as RFC 3339 UTC ending in Z, read with any offset, because extractors before
/// 2026-10-27 wrote "+00:00" (architecture §8.2). A read rounds as a write does, and an instant that rounds past
/// 9999-12-31T23:59:59.999Z makes the metadata corrupt, so the entry is a cache miss rather than a failed rewrite.</summary>
internal sealed class CacheTimestampConverter : JsonConverter<DateTimeOffset>
{
    private static readonly UtcTimestampConverter Utc = new();

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => DateTimeOffset.TryParse(reader.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var value)
            && UtcTimestamp.TryRound(value, out var rounded) ? rounded : throw new JsonException("Expected an RFC3339 timestamp.");

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) => Utc.Write(writer, value, options);
}

[JsonSourceGenerationOptions(NewLine = JsonFormatting.NewLine, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true,
    RespectRequiredConstructorParameters = true, Converters = new[] { typeof(CacheTimestampConverter) })]
[JsonSerializable(typeof(CacheEntry))]
internal partial class CacheJsonContext : JsonSerializerContext;
