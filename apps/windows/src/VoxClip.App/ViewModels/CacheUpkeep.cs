using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App.ViewModels;

/// <summary>When the app keeps its cache under Settings → General → "Cache size limit" (architecture §8.2), as the Mac's
/// <c>AppModel</c> does: a background pass <see cref="CacheEvictionScheduler.LaunchDelay"/> after launch
/// (<see cref="Started"/>), after each import (<see cref="Imported"/>) and as soon as the user lowers the limit
/// (<see cref="SettingChanged"/>). Clear cache and Clear everything go through the same scheduler, so no two passes run at once.
/// The limit is read as each pass starts.</summary>
internal sealed class CacheUpkeep(CacheEvictionScheduler scheduler, Func<AppSettings> settings)
{
    internal const string LimitKey = "cache.limitGB";
    internal const string ClearCacheLabel = "Clear cache";
    internal const string ClearEverythingLabel = "Clear everything";
    internal const string LimitLabel = "Cache size limit";
    internal const string ClearHelp = "Clear cache keeps each video's waveform and its saved transcription results. Clear everything removes those too.";
    internal const string ClearedCache = "Unused cache cleared. Your video, models and edits are still here.";
    internal const string ClearedEverything = "Unused cache cleared, with waveforms and saved transcription results. Your video, models and edits are still here.";
    internal static readonly int[] LimitChoices = [2, 5, 10, 20];

    private readonly object sync = new();
    private long? limit;

    internal CacheEvictionScheduler Scheduler => scheduler;

    /// <summary>The setting in bytes, in decimal gigabytes; an unusable value is the 5 GB default.</summary>
    internal static long LimitBytes(AppSettings settings) => CacheEvictionScheduler.LimitBytes(settings.GetDouble(LimitKey));

    /// <summary>Settings have loaded: remember the limit and schedule the launch pass.</summary>
    internal void Started()
    {
        lock (sync) limit = LimitBytes(settings());
        scheduler.ScheduleAfterLaunch();
    }

    /// <summary>A video was imported and its editor holds the new project's lease: keep the cache under its limit.</summary>
    internal void Imported() => scheduler.RequestRun();

    /// <summary>A setting was saved. A lower cache limit is enforced at once, in the background; a higher one waits for the next
    /// pass.</summary>
    internal void SettingChanged(string key)
    {
        if (key != LimitKey) return;
        var next = LimitBytes(settings());
        bool lowered;
        lock (sync)
        {
            lowered = limit is { } previous && next < previous;
            limit = next;
        }
        if (lowered) scheduler.RequestRun();
    }

    /// <summary>Settings → General → Clear cache: the first pass at a limit of 0. Returns the notice to show.</summary>
    internal async Task<string> ClearCacheAsync()
    {
        await scheduler.ClearCacheAsync().ConfigureAwait(false);
        return ClearedCache;
    }

    /// <summary>Settings → General → Clear everything: both passes at a limit of 0. Returns the notice to show.</summary>
    internal async Task<string> ClearEverythingAsync()
    {
        await scheduler.ClearEverythingAsync().ConfigureAwait(false);
        return ClearedEverything;
    }
}

/// <summary>The cache lease of the project open in one editor (architecture §8.2). Every window's editor holds one, so eviction
/// never strips or removes an open project's entry, whichever window has it open; two editors of the same source hold two leases.
/// <see cref="Hold"/> leases the project's key at once and marks its entry used in the background, so least recently used
/// follows when a project was last opened; a relink moves the lease to the new key. <see cref="Dispose"/> releases it as the editor
/// closes.</summary>
internal sealed class OpenProjectCacheLease(CacheIndex cache) : IDisposable
{
    private readonly object sync = new();
    private CacheKeyLease? lease;
    private Task touches = Task.CompletedTask;

    /// <summary>The key held now, or null.</summary>
    internal string? Key { get { lock (sync) return lease?.Key; } }

    /// <summary>The last <c>lastAccessAt</c> update; each waits for the one before it.</summary>
    internal Task Touches { get { lock (sync) return touches; } }

    /// <summary>Holds <paramref name="contentKey"/>, releasing a different key held before. The same key changes nothing.</summary>
    internal void Hold(string contentKey)
    {
        lock (sync)
        {
            if (lease?.Key == contentKey) return;
            lease?.Dispose();
            lease = cache.Keys.LeaseNow(contentKey);
            var previous = touches;
            touches = Task.Run(async () =>
            {
                await previous.ConfigureAwait(false);
                try { await cache.MarkUsedAsync(contentKey, CancellationToken.None).ConfigureAwait(false); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            });
        }
    }

    /// <summary>Releases the held key.</summary>
    public void Dispose()
    {
        lock (sync)
        {
            lease?.Dispose();
            lease = null;
        }
    }
}
