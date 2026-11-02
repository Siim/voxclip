using System.Globalization;
using SkiaSharp;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Project;
using VoxClip.Media.Thumbnails;

namespace VoxClip.App.Services;

/// <summary>Poster frames for Home tiles and sidebar rows (design §5.4.7). VoxClip's own decoder reads the scope's first
/// kept word, skipping black frames, and the JPEG is kept in the source's content-key cache entry as
/// <c>Cache/&lt;contentKey&gt;/thumbs/poster-&lt;t&gt;-&lt;px&gt;.jpg</c>, so cache eviction counts it and strips it in its first pass.
/// Home's recent projects are not open, so the entry is leased while its poster is looked up or written (architecture §8.2). When every
/// candidate is black, an empty <c>.none</c> file records that the caption card stands in. Decodes run off the UI thread,
/// two at a time, and stop when cancelled. The Windows shell is never asked: it answers MKV and WEBM with a file-type icon.
/// A cache entry that can't be written is a cache miss, reported to <paramref name="warn"/>, never an unreadable video.</summary>
internal sealed class Thumbnails(string cacheRoot, Action<string>? warn = null, Func<string, double, int, CancellationToken, Task<byte[]>>? timelineRead = null)
{
    /// <summary>Frames cover 480 × 270: a 226 × 127 Home tile at 200% scale.</summary>
    public const int CoverWidth = 480;
    public const int CoverHeight = 270;
    private readonly SemaphoreSlim decodes = new(2);
    internal const int TimelineWidth = 256;
    internal const int TimelineHeight = 144;

    internal sealed class FrameLease(string path, IDisposable lease) : IDisposable
    {
        internal string Path { get; } = path;
        private IDisposable? held = lease;
        public void Dispose() => Interlocked.Exchange(ref held, null)?.Dispose();
    }

    internal string? TimelinePathFor(string contentKey, double seconds, int rotation) => ValidKey(contentKey) && double.IsFinite(seconds) && seconds >= 0
        ? Path.Combine(cacheRoot, contentKey, "thumbs", string.Create(CultureInfo.InvariantCulture,
            $"timeline-{seconds:R}-{((rotation % 360) + 360) % 360}-{TimelineWidth}x{TimelineHeight}.jpg")) : null;

    internal async Task<FrameLease?> GetTimelineAsync(string contentKey, string mediaPath, double seconds, int rotation, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (TimelinePathFor(contentKey, seconds, rotation) is not { } target) return null;
        await decodes.WaitAsync(ct).ConfigureAwait(false);
        IDisposable? lease = null;
        try
        {
            lease = await CacheKeyRegistry.Shared(cacheRoot).LeaseAsync(contentKey, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (!File.Exists(target))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                var bytes = timelineRead is null ? await ReadTimelineJpeg(mediaPath, seconds, rotation, ct).ConfigureAwait(false)
                    : await timelineRead(mediaPath, seconds, rotation, ct).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    await File.WriteAllBytesAsync(temporary, bytes, ct).ConfigureAwait(false);
                    ct.ThrowIfCancellationRequested();
                    File.Move(temporary, target, true);
                }
                finally
                {
                    try { File.Delete(temporary); }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
                }
            }
            var result = new FrameLease(target, lease);
            lease = null;
            return result;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            CacheMiss(exception);
            return null;
        }
        finally { lease?.Dispose(); decodes.Release(); }
    }
    private static async Task<byte[]> ReadTimelineJpeg(string mediaPath, double seconds, int rotation, CancellationToken ct)
    {
        var pixels = await CurrentFrames.ReadAsync(mediaPath, seconds, rotation,
            new(TimelineWidth, TimelineHeight), new(TimelineWidth, TimelineHeight), ct, preserveSource: true).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        using var bitmap = new SKBitmap(new SKImageInfo(pixels.Width, pixels.Height, SKColorType.Bgra8888, SKAlphaType.Opaque));
        System.Runtime.InteropServices.Marshal.Copy(pixels.Pixels.ToArray(), 0, bitmap.GetPixels(), pixels.Stride * pixels.Height);
        using var image = SKImage.FromBitmap(bitmap);
        using var jpeg = image.Encode(SKEncodedImageFormat.Jpeg, 75) ?? throw new IOException("Unable to encode a timeline frame.");
        return jpeg.ToArray();
    }

    /// <summary>The cached poster frame for the source at <paramref name="mediaPath"/>, made on first use from
    /// <paramref name="candidates"/> (see <see cref="PosterFrames.Candidates"/>); null when every candidate is black, the
    /// content key is not a cache key or the cache can't take the frame (logged, and tried again next time). Decode failures
    /// propagate as <see cref="VoxClipException"/>, so the caller can show the unreadable state.</summary>
    public async Task<string?> GetAsync(string contentKey, string mediaPath, IReadOnlyList<double> candidates, int rotationDegrees, CancellationToken ct)
    {
        if (candidates.Count == 0 || PathFor(contentKey, candidates[0]) is not { } target) return null;
        using var lease = await CacheKeyRegistry.Shared(cacheRoot).LeaseAsync(contentKey, ct).ConfigureAwait(false);
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
