namespace VoxClip.App.ViewModels;

internal sealed class PreviewTransportCoordinator(Func<CancellationToken, Task> pauseSource,
    Func<CancellationToken, Task> stopCandidate) : IAsyncDisposable
{
    private readonly SemaphoreSlim serial = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? pending;
    private long revision;
    private bool retired;

    internal Task SourceAsync(Func<CancellationToken, Task> start, CancellationToken token = default) =>
        TransitionAsync(false, start, token);
    internal Task CandidateAsync(Func<CancellationToken, Task> start, CancellationToken token = default) =>
        TransitionAsync(true, start, token);

    private async Task TransitionAsync(bool candidate, Func<CancellationToken, Task> start, CancellationToken token)
    {
        if (retired) return;
        var version = ++revision;
        pending?.Cancel();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, token);
        pending = cancellation;
        var entered = false;
        try
        {
            await serial.WaitAsync(cancellation.Token); entered = true;
            await stopCandidate(cancellation.Token);
            if (candidate) await pauseSource(cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (retired || version != revision) return;
            await start(cancellation.Token);
            if (candidate && (retired || version != revision || cancellation.IsCancellationRequested))
                await stopCandidate(CancellationToken.None);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            if (candidate && entered) await stopCandidate(CancellationToken.None);
        }
        finally
        {
            if (ReferenceEquals(pending, cancellation)) pending = null;
            if (entered) serial.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (retired) return;
        retired = true; revision++; lifetime.Cancel();
        await serial.WaitAsync();
        try { await stopCandidate(CancellationToken.None); await pauseSource(CancellationToken.None); }
        finally { serial.Release(); lifetime.Dispose(); }
    }
}
