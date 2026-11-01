namespace VoxClip.Core.Services.Project;

/// <summary>Keeps one data folder's cache under the "Cache size limit" setting (architecture §8.2), as the Mac's
/// <c>CacheEvictionScheduler</c>. A background pass runs <see cref="LaunchDelay"/> after launch, after each import and when the
/// user lowers the limit; Clear cache and Clear everything run here too.
/// <para>Passes never overlap: every pass takes the cache folder's eviction turn in <see cref="CacheKeyRegistry"/>, so a
/// background pass and the Clear actions wait for each other, and a request made while a pass is queued is answered by that
/// pass. Leased keys (open projects, extractions, transcriptions, waveform reads, thumbnails) are never touched. Every pass,
/// the Clear actions included, spares an entry without readable metadata while anything in it was written in the last hour
/// (<see cref="CacheIndex.EvictAsync(long, IReadOnlySet{string}, bool, CancellationToken)"/>). A failed pass is reported to
/// the warning callback and never shown: a missing entry is recomputed.</para></summary>
public sealed class CacheEvictionScheduler
{
    /// <summary>How long after launch the first pass waits, so it never competes with opening the app.</summary>
    public static TimeSpan LaunchDelay { get; } = TimeSpan.FromSeconds(30);
    /// <summary>The setting is in decimal gigabytes, as Explorer and Finder count them.</summary>
    public const long BytesPerGB = 1_000_000_000;
    /// <summary>The 5 GB default of <c>cache.limitGB</c>.</summary>
    public const long DefaultLimitBytes = 5 * BytesPerGB;

    private static readonly IReadOnlySet<string> NoProtectedKeys = new HashSet<string>(StringComparer.Ordinal);
    private readonly CacheIndex index;
    private readonly Func<long> currentLimit;
    private readonly Action<string>? warn;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly object sync = new();
    private Task? launch;
    private Task? tail;
    private bool queued;
    private int completedRuns;

    /// <summary><paramref name="limitBytes"/> is read when each background pass starts. <paramref name="delay"/> waits out the
    /// launch delay (<see cref="Task.Delay(TimeSpan, CancellationToken)"/> unless a test injects one), and
    /// <paramref name="warn"/> receives a log line for a failed pass.</summary>
    public CacheEvictionScheduler(CacheIndex index, Func<long> limitBytes, Action<string>? warn = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.index = index ?? throw new ArgumentNullException(nameof(index));
        currentLimit = limitBytes ?? throw new ArgumentNullException(nameof(limitBytes));
        this.warn = warn;
        this.delay = delay ?? ((span, ct) => Task.Delay(span, ct));
    }

    /// <summary><c>cache.limitGB</c> in bytes; an unusable value falls back to the 5 GB default.</summary>
    public static long LimitBytes(double? gigabytes) =>
        gigabytes is { } value && double.IsFinite(value) && value > 0 && value <= 1_000 ? (long)Math.Round(value * BytesPerGB) : DefaultLimitBytes;

    /// <summary>Schedules the launch pass <see cref="LaunchDelay"/> from now. Later calls return the same task.</summary>
    public Task ScheduleAfterLaunch()
    {
        lock (sync)
        {
            return launch ??= Task.Run(async () =>
            {
                try { await delay(LaunchDelay, CancellationToken.None).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                RequestRun();
            });
        }
    }

    /// <summary>Asks for a background pass now: after an import, or when the limit is lowered. A pass that is queued and has
    /// not started answers the request; one that has started is followed by another.</summary>
    public void RequestRun()
    {
        lock (sync)
        {
            if (queued) return;
            queued = true;
            var previous = tail ?? Task.CompletedTask;
            // Off the caller's thread: a pass walks the cache folder, and the caller is often the UI thread.
            tail = Task.Run(async () =>
            {
                await previous.ConfigureAwait(false);
                lock (sync) queued = false;
                await PassAsync(currentLimit, false, "background").ConfigureAwait(false);
                lock (sync) completedRuns++;
            });
        }
    }

    /// <summary>Clear cache (architecture §8.2): the first pass with a limit of 0, so every entry not in use keeps its envelope
    /// and raw transcripts. It waits for a pass that is running. A failure is only reported.</summary>
    public Task ClearCacheAsync() => Task.Run(() => PassAsync(() => 0, true, "clear"));

    /// <summary>Clear everything (architecture §8.2): both passes with a limit of 0, so every entry not in use goes, envelopes
    /// and raw transcripts with it. It waits for a pass that is running. A failure is only reported.</summary>
    public Task ClearEverythingAsync() => Task.Run(() => PassAsync(() => 0, false, "clear-everything"));

    /// <summary>Whether the launch pass has been scheduled.</summary>
    public bool LaunchScheduled { get { lock (sync) return launch is not null; } }

    /// <summary>Background passes that have finished.</summary>
    public int CompletedRuns { get { lock (sync) return completedRuns; } }

    /// <summary>Waits until no background pass is queued or running; the launch pass counts once its delay is over.</summary>
    public async Task WaitUntilIdleAsync()
    {
        while (true)
        {
            Task? current;
            lock (sync) current = tail;
            if (current is null) return;
            await current.ConfigureAwait(false);
            lock (sync) if (ReferenceEquals(tail, current)) return;
        }
    }

    // Never throws, so a queued pass always follows the one before it.
    private async Task PassAsync(Func<long> limit, bool keepEnvelopes, string name)
    {
        try { await index.EvictAsync(Math.Max(0, limit()), NoProtectedKeys, keepEnvelopes, CancellationToken.None).ConfigureAwait(false); }
        catch (Exception exception)
        {
            warn?.Invoke($"eviction=failed pass={name} code={exception.GetType().Name}");
        }
    }
}
