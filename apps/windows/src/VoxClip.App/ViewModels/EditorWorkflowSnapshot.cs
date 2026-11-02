using VoxClip.Core.Domain.Shared;

namespace VoxClip.App.ViewModels;

internal sealed class EditorWorkflowSnapshot(EditorViewModel editor)
{
    internal Project Project { get; } = editor.Project;
    internal bool IsCurrent => !editor.IsLeaving && !editor.IsReadOnly && ReferenceEquals(Project, editor.Project);
    internal void RequireCurrent()
    {
        if (!IsCurrent) throw new OperationCanceledException("The project changed. Review the current request. Your edits are saved.");
    }
}

internal sealed class InlineJobLifetime : IDisposable
{
    private readonly CancellationTokenSource cancellation = new();
    private readonly object sync = new();
    private readonly CancellationToken token;
    private readonly TaskCompletionSource drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int workers;
    private bool retired;
    private bool disposed;
    internal InlineJobLifetime() => token = cancellation.Token;
    internal CancellationToken Token => token;
    internal Task Drained => drained.Task;
    internal async Task<bool> DrainAsync(TimeSpan bound)
    {
        try { await Drained.WaitAsync(bound); return true; }
        catch (TimeoutException) { return false; }
    }

    internal IDisposable Enter()
    {
        lock (sync)
        {
            if (retired) throw new OperationCanceledException(token);
            workers++;
            return new Worker(this);
        }
    }

    internal void Retire()
    {
        lock (sync)
        {
            if (retired) return;
            retired = true;
            cancellation.Cancel();
            CompleteDrain();
        }
    }

    private void CompleteDrain()
    {
        if (!retired || workers != 0 || disposed) return;
        disposed = true;
        drained.TrySetResult();
        cancellation.Dispose();
    }

    public void Dispose() => Retire();

    private sealed class Worker(InlineJobLifetime owner) : IDisposable
    {
        private InlineJobLifetime? active = owner;
        public void Dispose()
        {
            var previous = Interlocked.Exchange(ref active, null);
            if (previous is null) return;
            lock (previous.sync)
            {
                previous.workers--;
                previous.CompleteDrain();
            }
        }
    }
}

internal sealed class WorkflowProgress<T>(Action<T> evidence, Action<T> presentation, Action<Action> dispatch) : IProgress<T>
{
    public void Report(T value)
    {
        evidence(value);
        dispatch(() => presentation(value));
    }
}
