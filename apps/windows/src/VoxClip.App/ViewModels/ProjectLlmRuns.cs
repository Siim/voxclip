namespace VoxClip.App.ViewModels;

/// <summary>The project's one AI lease (twin of the Mac <c>ProjectLlmRuns</c>). Only one AI request runs on a project at a time, except
/// inside <see cref="SharingAsync"/>: while Claude mode's planner holds the lease for the plans still in flight, the clip being applied
/// lets its own Rewrite steps take a lease too (ai.md §16.12), so the free fit round and Keep fixing still run.</summary>
internal sealed class ProjectLlmRuns
{
    private readonly object gate = new();
    private bool held;
    private int guests;
    private int sharers;
    internal bool IsBusy { get { lock (gate) return held || guests > 0; } }
    internal event EventHandler? Changed;

    internal IDisposable? TryAcquire()
    {
        Lease lease;
        lock (gate)
        {
            if (!held && guests == 0) { held = true; lease = new(this, false); }
            else if (sharers > 0) { guests++; lease = new(this, true); }
            else return null;
        }
        Changed?.Invoke(this, EventArgs.Empty);
        return lease;
    }

    /// <summary>Runs <paramref name="body"/> letting its own steps take a lease while another holder has it. Only inside that window.</summary>
    internal async Task SharingAsync(Func<Task> body)
    {
        lock (gate) sharers++;
        try { await body(); }
        finally { lock (gate) sharers--; }
    }

    private void Release(bool guest)
    {
        lock (gate) { if (guest) guests--; else held = false; }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private sealed class Lease(ProjectLlmRuns owner, bool guest) : IDisposable
    {
        private ProjectLlmRuns? current = owner;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref current, null) is not { } runs) return;
            runs.Release(guest);
        }
    }
}
