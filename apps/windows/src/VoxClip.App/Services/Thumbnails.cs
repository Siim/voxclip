using System.Globalization;
using VoxClip.Core.Domain.Shared;
using VoxClip.Media.Thumbnails;

namespace VoxClip.App.Services;

/// <summary>Poster frames for Home tiles and sidebar rows (design §5.4.7). VoxClip's own decoder reads the scope's first
/// kept word, skipping black frames, and the JPEG is kept in the source's content-key cache entry as
/// <c>Cache/&lt;contentKey&gt;/thumbs/poster-&lt;t&gt;-&lt;px&gt;.jpg</c>, so cache eviction counts and removes it. When every
/// candidate is black, an empty <c>.none</c> file records that the caption card stands in. Decodes run off the UI thread,
/// two at a time, and stop when cancelled. The Windows shell is never asked: it answers MKV and WEBM with a file-type icon.
/// A cache entry that can't be written is a cache miss, reported to <paramref name="warn"/>, never an unreadable video.</summary>
internal sealed class Thumbnails(string cacheRoot, Action<string>? warn = null)
{
    /// <summary>Frames cover 480 × 270: a 226 × 127 Home tile at 200% scale.</summary>
    public const int CoverWidth = 480;
    public const int CoverHeight = 270;
    private readonly SemaphoreSlim decodes = new(2);

    /// <summary>The cached poster frame for the source at <paramref name="mediaPath"/>, made on first use from
    /// <paramref name="candidates"/> (see <see cref="PosterFrames.Candidates"/>); null when every candidate is black, the
    /// content key is not a cache key or the cache can't take the frame (logged, and tried again next time). Decode failures
    /// propagate as <see cref="VoxClipException"/>, so the caller can show the unreadable state.</summary>
    public async Task<string?> GetAsync(string contentKey, string mediaPath, IReadOnlyList<double> candidates, int rotationDegrees, CancellationToken ct)
    {
        if (candidates.Count == 0 || PathFor(contentKey, candidates[0]) is not { } target) return null;
        var none = Path.ChangeExtension(target, ".none");
        if (File.Exists(target)) return target;
        if (File.Exists(none)) return null;
        await decodes.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (File.Exists(target)) return target;
            // Only decode what the cache entry can keep.
            try { Directory.CreateDirectory(Path.GetDirectoryName(target)!); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return CacheMiss(exception); }
            var jpeg = await PosterFrames.ReadJpegAsync(mediaPath, candidates, rotationDegrees, CoverWidth, CoverHeight, ct).ConfigureAwait(false);
            var temporary = $"{target}.{Guid.NewGuid():N}.tmp";
            try
            {
                if (jpeg is null)
                {
                    await File.WriteAllBytesAsync(none, [], ct).ConfigureAwait(false);
                    return null;
                }
                await File.WriteAllBytesAsync(temporary, jpeg, ct).ConfigureAwait(false);
                File.Move(temporary, target, true);
                return target;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return CacheMiss(exception); }
            finally
            {
                try { File.Delete(temporary); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
        }
        finally { decodes.Release(); }
    }

    private string? CacheMiss(Exception exception)
    {
        warn?.Invoke($"action=Poster cache code={exception.GetType().Name}");
        return null;
    }

    /// <summary>The frames to try for the edited take (<paramref name="clipId"/> null) or one of its clips (design §5.4.7):
    /// the scope's first kept word, 1 s and 3 s later, then 10% into the scope. A take with no transcript starts at 0.</summary>
    public static IReadOnlyList<double> Candidates(Project project, string? clipId)
    {
        var duration = project.Media.Source.DurationSeconds;
        var words = project.Transcript?.Words ?? [];
        int IndexOf(string id) { for (var index = 0; index < words.Count; index++) if (words[index].Id == id) return index; return -1; }
        var (first, last) = (0, words.Count - 1);
        var range = clipId is null ? null : project.Edits.Clips.FirstOrDefault(clip => clip.Id == clipId);
        if (range is not null)
        {
            first = Math.Max(0, IndexOf(range.StartWordId));
            last = Math.Max(first, IndexOf(range.EndWordId));
        }
        var scoped = range is not null && words.Count > 0;
        var start = scoped ? words[first].Start : 0;
        var end = scoped ? words[last].End : duration;
        var cut = project.Edits.CutWordIds.ToHashSet(StringComparer.Ordinal);
        var kept = words.Skip(first).Take(last - first + 1).FirstOrDefault(word => word.Kind == WordKind.Word && !cut.Contains(word.Id));
        return PosterFrames.Candidates(kept?.Start ?? start, start, end - start, duration);
    }

    /// <summary>The poster's cache path, keyed by (content key, time rounded to 0.1 s, pixel size); null for a content key
    /// that is not 64 lowercase hex digits, so a crafted project file cannot name a folder outside the cache.</summary>
    public string? PathFor(string contentKey, double seconds) => ValidKey(contentKey)
        ? Path.Combine(cacheRoot, contentKey, "thumbs", string.Create(CultureInfo.InvariantCulture, $"poster-{Math.Round(seconds, 1, MidpointRounding.AwayFromZero):0.0}-{CoverWidth}x{CoverHeight}.jpg"))
        : null;

    private static bool ValidKey(string key) => key.Length == 64 && key.All(character => char.IsAsciiDigit(character) || character is >= 'a' and <= 'f');
}
