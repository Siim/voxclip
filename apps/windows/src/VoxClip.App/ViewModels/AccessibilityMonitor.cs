namespace VoxClip.App.ViewModels;

internal readonly record struct AccessibilitySnapshot(AccessibilityEffects Effects, string Scheme)
{
    internal static AccessibilitySnapshot Default => new(new(true, true, false), "");
}

internal sealed class AccessibilityMonitor(Action<Action> dispatch, Func<AccessibilitySnapshot> read,
    Action<AccessibilitySnapshot> publish, Action<Exception> report) : IDisposable
{
    private readonly List<Action> unsubscribe = [];
    private bool started;
    private bool disposed;

    internal void Start(params Func<Action, Action>[] subscriptions)
    {
        if (started || disposed) return;
        started = true;
        Refresh();
        foreach (var subscribe in subscriptions)
        {
            try { unsubscribe.Add(subscribe(Changed)); }
            catch (Exception exception) { report(exception); }
        }
    }

    private void Changed() => dispatch(() => { if (!disposed) Refresh(); });
    private void Refresh()
    {
        try { publish(read()); }
        catch (Exception exception) { report(exception); }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        foreach (var remove in unsubscribe)
        {
            try { remove(); }
            catch (Exception exception) { report(exception); }
        }
        unsubscribe.Clear();
    }
}
