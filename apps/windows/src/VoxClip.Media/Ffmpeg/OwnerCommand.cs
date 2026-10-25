namespace VoxClip.Media.Ffmpeg;

internal sealed class OwnerCommand<TResult>
{
    private readonly TaskCompletionSource<TResult> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Func<TResult> operation;
    private readonly CancellationToken cancellation;
    internal Task<TResult> Task => completion.Task;

    internal OwnerCommand(Func<TResult> operation, CancellationToken cancellation)
    {
        this.operation = operation;
        this.cancellation = cancellation;
        var registration = cancellation.Register(() => completion.TrySetCanceled(cancellation));
        _ = completion.Task.ContinueWith(_ => registration.Dispose(), CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    internal void Execute()
    {
        if (completion.Task.IsCompleted) return;
        try { cancellation.ThrowIfCancellationRequested(); completion.TrySetResult(operation()); }
        catch (OperationCanceledException exception) { completion.TrySetCanceled(exception.CancellationToken); }
        catch (Exception exception) { completion.TrySetException(exception); }
    }

    internal void Fail(Exception exception) => completion.TrySetException(exception);
}
