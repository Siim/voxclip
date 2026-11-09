using System.Globalization;
using VoxClip.Core.Domain.Frames;
using VoxClip.Core.Services.Project;

namespace VoxClip.Media.Frames;

/// <summary>The frame analyzer's cache, <c>Cache/&lt;contentKey&gt;/frames/</c> (architecture §8.2, ADR-R48), twin of the Mac
/// <c>FrameAnalysisCache</c>: <see cref="FrameAnalysisFile.FileName"/> holds one observation per source millisecond asked for, in the
/// Mac's file shape, and <c>sheet-&lt;ms&gt;.jpg</c> the frame sheet's small JPEG of that frame. Both can be made again, so the cache's
/// first eviction pass strips them with the rest of what an entry can rebuild. Folders are real folders, never links, made one level
/// at a time; the entry's key is leased while a file is written.</summary>
public sealed class FrameAnalysisCache
{
    /// <summary>The folder in a source's cache entry.</summary>
    public const string Folder = "frames";

    private readonly CacheIndex index;
    private readonly SemaphoreSlim gate = new(1, 1);

    /// <summary>The cache under <paramref name="cacheRoot"/>, or the data root's Cache folder.</summary>
    public FrameAnalysisCache(string? cacheRoot = null) => index = new CacheIndex(cacheRoot);

    /// <summary>The key a time is cached under: its millisecond, rounded half away from zero.</summary>
    public static long Millisecond(double time) => (long)Math.Round(time * 1000, MidpointRounding.AwayFromZero);

    /// <summary>The cached observations of <paramref name="contentKey"/> for one pass (a decode tolerance, such as <c>"0.250"</c>),
    /// keyed by the millisecond asked for; empty when there are none or the file is not this version's.</summary>
    public IReadOnlyDictionary<long, FrameObservation> Observations(string contentKey, string pass)
    {
        var prefix = pass + ":";
        var result = new Dictionary<long, FrameObservation>();
        foreach (var (key, value) in AllFrames(contentKey))
            if (key.StartsWith(prefix, StringComparison.Ordinal)
                && long.TryParse(key.AsSpan(prefix.Length), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var millisecond))
                result[millisecond] = value;
        return result;
    }

    /// <summary>Adds observations to the cached ones of a pass, keyed by the millisecond each was asked for.</summary>
    public async Task StoreAsync(IReadOnlyList<(double Requested, FrameObservation Observation)> observations, string contentKey, string pass,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(observations);
        if (observations.Count == 0) return;
        using var lease = await index.Keys.LeaseAsync(contentKey, ct).ConfigureAwait(false);
        // One merge at a time in this process: two lanes' passes never drop each other's frames.
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (FolderOf(contentKey, create: true) is not { } folder) return;
            var merged = new Dictionary<string, FrameObservation>(AllFrames(contentKey), StringComparer.Ordinal);
            foreach (var (requested, observation) in observations) merged[FrameAnalysisFile.Key(pass, requested)] = observation;
            await WriteAsync(Path.Combine(folder, FrameAnalysisFile.FileName), System.Text.Encoding.UTF8.GetBytes(FrameAnalysisFile.Write(merged)), ct)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        finally { gate.Release(); }
    }

    /// <summary>The cached sheet JPEG of the frame at <paramref name="time"/>, if any.</summary>
    public byte[]? SheetImage(string contentKey, double time) =>
        FolderOf(contentKey, create: false) is { } folder ? ReadRegularFile(Path.Combine(folder, SheetName(time))) : null;

    /// <summary>Caches the sheet JPEG of the frame at <paramref name="time"/>.</summary>
    public async Task StoreSheetImageAsync(byte[] jpeg, string contentKey, double time, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(jpeg);
        using var lease = await index.Keys.LeaseAsync(contentKey, ct).ConfigureAwait(false);
        try
        {
            if (FolderOf(contentKey, create: true) is { } folder) await WriteAsync(Path.Combine(folder, SheetName(time)), jpeg, ct).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private static string SheetName(double time) => "sheet-" + Millisecond(time).ToString(CultureInfo.InvariantCulture) + ".jpg";

    private IReadOnlyDictionary<string, FrameObservation> AllFrames(string contentKey)
    {
        if (FolderOf(contentKey, create: false) is not { } folder || ReadRegularFile(Path.Combine(folder, FrameAnalysisFile.FileName)) is not { } bytes)
            return new Dictionary<string, FrameObservation>();
        return FrameAnalysisFile.Read(System.Text.Encoding.UTF8.GetString(bytes));
    }

    /// <summary><c>Cache/&lt;contentKey&gt;/frames/</c>, only for a well-formed key and only through real folders.</summary>
    private string? FolderOf(string contentKey, bool create)
    {
        string entry;
        try { entry = index.EntryDirectory(contentKey); }
        catch (ArgumentException) { return null; }
        var root = Path.GetDirectoryName(entry)!;
        if (!IsRealDirectory(root))
        {
            if (!create || Path.Exists(root)) return null;
            try { Directory.CreateDirectory(root); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return null; }
        }
        var frames = Path.Combine(entry, Folder);
        foreach (var folder in new[] { entry, frames })
        {
            if (IsRealDirectory(folder)) continue;
            if (!create || Path.Exists(folder)) return null;
            try { Directory.CreateDirectory(folder); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return null; }
            if (!IsRealDirectory(folder)) return null;
        }
        return frames;
    }

    private static bool IsRealDirectory(string path)
    {
        var info = new DirectoryInfo(path);
        return info.Exists && (info.Attributes & FileAttributes.ReparsePoint) == 0 && info.LinkTarget is null;
    }

    /// <summary>A regular file's bytes, never through a link.</summary>
    private static byte[]? ReadRegularFile(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || (info.Attributes & FileAttributes.ReparsePoint) != 0) return null;
            return File.ReadAllBytes(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>Writes beside the file, then moves it into place, so a reader sees the old file or the new one.</summary>
    private static async Task WriteAsync(string path, byte[] bytes, CancellationToken ct)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            await File.WriteAllBytesAsync(temporary, bytes, ct).ConfigureAwait(false);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
