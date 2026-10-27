namespace VoxClip.App.ViewModels;

public enum CaptionTileBackdrop { FrameBand, Card, Stage }

public static class CaptionTileState
{
    public static CaptionTileBackdrop Backdrop(bool loading, bool hasFrame) => loading
        ? CaptionTileBackdrop.Stage : hasFrame ? CaptionTileBackdrop.FrameBand : CaptionTileBackdrop.Card;
}

public sealed class LatestTileRender : IDisposable
{
    private readonly object gate = new();
    private CancellationTokenSource? pending;

    public async Task RunAsync<T>(Func<CancellationToken, Task<T>> render, Action<T> store, CancellationToken lifetime)
    {
        CancellationTokenSource request;
        lock (gate)
        {
            pending?.Cancel();
            request = pending = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        }
        try
        {
            var image = await render(request.Token);
            lock (gate)
                if (ReferenceEquals(pending, request) && !request.IsCancellationRequested) store(image);
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested) { }
        finally
        {
            lock (gate)
                if (ReferenceEquals(pending, request)) pending = null;
            request.Dispose();
        }
    }

    public void Dispose()
    {
        lock (gate) { pending?.Cancel(); pending = null; }
    }
}
