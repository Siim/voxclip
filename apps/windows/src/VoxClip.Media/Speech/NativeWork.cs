namespace VoxClip.Media.Speech;

internal static class NativeWork
{
    internal static async Task<T> RunAsync<T>(Func<Task<T>> run, Action finished, CancellationToken ct)
    {
        var work = Task.Run(async () =>
        {
            try { return await run().ConfigureAwait(false); }
            finally { finished(); }
        }, CancellationToken.None);
        try { return await work.WaitAsync(ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            _ = work.ContinueWith(completed => _ = completed.Exception, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            throw;
        }
    }
}
