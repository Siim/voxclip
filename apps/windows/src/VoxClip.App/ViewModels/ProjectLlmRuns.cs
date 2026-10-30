namespace VoxClip.App.ViewModels;

internal sealed class ProjectLlmRuns
{
    private int held;
    internal bool IsBusy => Volatile.Read(ref held) != 0;
    internal event EventHandler? Changed;

    internal IDisposable? TryAcquire()
    {
        if (Interlocked.CompareExchange(ref held, 1, 0) != 0) return null;
        Changed?.Invoke(this, EventArgs.Empty);
        return new Lease(this);
    }

    private sealed class Lease(ProjectLlmRuns owner) : IDisposable
    {
        private ProjectLlmRuns? current = owner;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref current, null) is not { } runs) return;
            Interlocked.Exchange(ref runs.held, 0);
            runs.Changed?.Invoke(runs, EventArgs.Empty);
        }
    }
}
