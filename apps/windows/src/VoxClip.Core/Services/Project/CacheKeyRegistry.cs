namespace VoxClip.Core.Services.Project;

/// <summary>The content keys in use in one cache folder (architecture §8.2), as the Mac's <c>CacheKeyRegistry</c>. Everything
/// that reads or writes a cache entry holds a lease on its key while it works: each editor's open project, extraction,
/// transcription and language detection, waveform reads and thumbnail posters. Eviction never strips or removes a leased
/// entry, though it still counts towards the limit. Every <see cref="CacheIndex"/> of a folder shares its registry, so
/// eviction also runs one pass at a time there, whichever index runs it: a background pass, Clear cache or Clear
/// everything.</summary>
public sealed class CacheKeyRegistry
{
    private static readonly Dictionary<string, CacheKeyRegistry> Folders =
        new(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
    private readonly object sync = new();
    private readonly Dictionary<string, int> leases = new(StringComparer.Ordinal);
    private readonly List<TaskCompletionSource> leaseWaiters = [];
    private readonly LinkedList<TaskCompletionSource> evictionWaiters = new();
    // The entry eviction is stripping or removing now; a lease on it waits until that is done.
    private string? evicting;
    private bool evictionRunning;

    private CacheKeyRegistry() { }

    /// <summary>The registry of the cache folder at <paramref name="cacheRoot"/>, the same for every caller in this
    /// process.</summary>
    public static CacheKeyRegistry Shared(string cacheRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(cacheRoot);
        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(cacheRoot));
        lock (Folders)
        {
            if (Folders.TryGetValue(path, out var existing)) return existing;
            var registry = new CacheKeyRegistry();
            Folders[path] = registry;
            return registry;
        }
    }

    /// <summary>Marks <paramref name="key"/> in use until the lease is disposed. If eviction is stripping or removing that
    /// entry right now, this waits until it has finished, so the holder finds the entry whole or gone and recomputes a
    /// missing one. A cancelled wait releases the lease and throws.</summary>
    public async Task<CacheKeyLease> LeaseAsync(string key, CancellationToken ct = default)
    {
        var lease = LeaseNow(key);
        TaskCompletionSource? waiter = null;
        lock (sync)
        {
            if (evicting == key)
            {
                waiter = new(TaskCreationOptions.RunContinuationsAsynchronously);
                leaseWaiters.Add(waiter);
            }
        }
        if (waiter is null) return lease;
        try { await waiter.Task.WaitAsync(ct).ConfigureAwait(false); }
        catch
        {
            lease.Dispose();
            throw;
        }
        return lease;
    }

    /// <summary>Marks <paramref name="key"/> in use at once, for a holder that cannot wait, such as a project as it opens.
    /// An eviction that is already working on that entry finishes it.</summary>
    public CacheKeyLease LeaseNow(string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        lock (sync) leases[key] = leases.GetValueOrDefault(key) + 1;
        return new(this, key);
    }

    /// <summary>Whether any holder has <paramref name="key"/> leased.</summary>
    public bool IsLeased(string key) { lock (sync) return leases.ContainsKey(key); }

    /// <summary>The keys leased now.</summary>
    public IReadOnlySet<string> LeasedKeys { get { lock (sync) return leases.Keys.ToHashSet(StringComparer.Ordinal); } }

    internal void Release(string key)
    {
        lock (sync)
        {
            if (!leases.TryGetValue(key, out var count)) return;
            if (count > 1) leases[key] = count - 1;
            else leases.Remove(key);
        }
    }

    /// <summary>Takes the folder's eviction turn, waiting in arrival order while another pass has it.</summary>
    internal async Task BeginEvictionAsync(CancellationToken ct)
    {
        TaskCompletionSource waiter;
        LinkedListNode<TaskCompletionSource> node;
        lock (sync)
        {
            ct.ThrowIfCancellationRequested();
            if (!evictionRunning) { evictionRunning = true; return; }
            waiter = new(TaskCreationOptions.RunContinuationsAsynchronously);
            node = evictionWaiters.AddLast(waiter);
        }
        using (ct.Register(() =>
        {
            lock (sync)
            {
                // A turn handed over just before the cancellation stays with this pass, which ends it as usual.
                if (node.List is null) return;
                evictionWaiters.Remove(node);
            }
            waiter.TrySetCanceled(ct);
        }))
            await waiter.Task.ConfigureAwait(false);
    }

    /// <summary>Hands the eviction turn to the next waiting pass, if any.</summary>
    internal void EndEviction()
    {
        TaskCompletionSource? next;
        lock (sync)
        {
            if (evictionWaiters.First is not { } first) { evictionRunning = false; return; }
            next = first.Value;
            evictionWaiters.RemoveFirst();
        }
        next.TrySetResult();
    }

    /// <summary>Passes waiting for the eviction turn.</summary>
    internal int WaitingEvictions { get { lock (sync) return evictionWaiters.Count; } }

    /// <summary>Claims an entry for eviction unless it is leased or in <paramref name="protectedKeys"/>. Until
    /// <see cref="EndClaim"/>, a new <see cref="LeaseAsync"/> on it waits.</summary>
    internal bool TryClaim(string key, IReadOnlySet<string> protectedKeys)
    {
        lock (sync)
        {
            if (leases.ContainsKey(key) || protectedKeys.Contains(key)) return false;
            evicting = key;
            return true;
        }
    }

    internal void EndClaim()
    {
        TaskCompletionSource[] waiters;
        lock (sync)
        {
            evicting = null;
            waiters = [.. leaseWaiters];
            leaseWaiters.Clear();
        }
        foreach (var waiter in waiters) waiter.TrySetResult();
    }
}

/// <summary>One holder's use of a cache key (architecture §8.2). Dispose it when the work ends; a lease that is never
/// disposed is released when it is collected, as the Mac's lease is when its last reference goes.</summary>
public sealed class CacheKeyLease : IDisposable
{
    private readonly CacheKeyRegistry registry;
    private int released;

    internal CacheKeyLease(CacheKeyRegistry registry, string key)
    {
        this.registry = registry;
        Key = key;
    }

    /// <summary>The leased content key.</summary>
    public string Key { get; }

    /// <summary>Releases the lease; later calls do nothing.</summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref released, 1) == 0) registry.Release(Key);
        GC.SuppressFinalize(this);
    }

    /// <summary>Releases a lease its holder dropped without disposing it.</summary>
    ~CacheKeyLease()
    {
        if (Interlocked.Exchange(ref released, 1) == 0) registry.Release(Key);
    }
}
