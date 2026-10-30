using System.Runtime.ExceptionServices;
using System.Text.Json;
using VoxClip.Core.Services.Settings;

namespace VoxClip.App.Services;

/// <summary>Serializes accepted settings changes and drains them before an immediate-exit update.</summary>
internal sealed class SettingsWriteQueue(ISettingsStore store)
{
#if DEBUG
    internal Func<string, Task>? DebugBeforeSave { get; set; }
    internal Func<Task>? DebugBeforeFlush { get; set; }
#endif
    private readonly object sync = new();
    private readonly SemaphoreSlim writes = new(1, 1);
    private AppSettings current = new("voxclip-settings/1");
    private TaskCompletionSource? drained;
    private ExceptionDispatchInfo? writeFailure;
    private readonly HashSet<string> failedKeys = new(StringComparer.Ordinal);
    private int accepted;
    private bool frozen;

    internal AppSettings Current { get { lock (sync) return current; } }
    internal bool IsFrozen { get { lock (sync) return frozen; } }
    internal event Action<string>? Changed;

    internal void Initialize(AppSettings settings)
    {
        lock (sync)
        {
            if (accepted != 0 || frozen) throw new InvalidOperationException("Settings are already in use.");
            current = settings;
        }
    }

    internal Task SetAsync<T>(string key, T value, CancellationToken ct = default)
    {
        lock (sync)
        {
            if (frozen) return Task.FromException(new InvalidOperationException("Settings are paused for update restart."));
            accepted++;
        }
        return WriteAsync(key, value, ct);
    }

    private async Task WriteAsync<T>(string key, T value, CancellationToken ct)
    {
        try
        {
            await writes.WaitAsync(ct);
            try
            {
#if DEBUG
                if (DebugBeforeSave is { } beforeSave) await beforeSave(key);
#endif
                // Untouched defaults stay implicit, so the store writes only stored values and this change.
                var next = Current.With(key, JsonSerializer.SerializeToElement(value));
                await store.SaveAsync(next, ct);
                lock (sync)
                {
                    current = next;
                    failedKeys.Remove(key);
                    if (failedKeys.Count == 0) writeFailure = null;
                }
                Changed?.Invoke(key);
            }
            finally { writes.Release(); }
        }
        catch (Exception exception)
        {
            lock (sync)
            {
                failedKeys.Add(key);
                writeFailure = ExceptionDispatchInfo.Capture(exception);
            }
            throw;
        }
        finally
        {
            lock (sync)
            {
                accepted--;
                if (accepted == 0) drained?.TrySetResult();
            }
        }
    }

    internal void Freeze()
    {
        lock (sync)
        {
            if (frozen) throw new InvalidOperationException("Settings are already paused.");
            frozen = true;
            drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
            if (accepted == 0) drained.TrySetResult();
        }
    }

    internal async Task DrainAsync(CancellationToken ct)
    {
        Task wait;
        lock (sync) wait = frozen ? drained!.Task : throw new InvalidOperationException("Settings are not paused.");
        await wait.WaitAsync(ct);
        lock (sync) writeFailure?.Throw();
    }

    internal async Task FlushAsync(CancellationToken ct)
    {
        await writes.WaitAsync(ct);
        try
        {
#if DEBUG
            if (DebugBeforeFlush is { } beforeFlush) await beforeFlush();
#endif
            await store.FlushAsync(ct);
        }
        finally { writes.Release(); }
    }

    internal void Resume()
    {
        lock (sync) { frozen = false; drained = null; }
    }
}
