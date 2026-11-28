namespace VoxClip.App.ViewModels;

/// <summary>The page's waveform load over a project's recordings, one at a time (editing §5.10): a recording whose video can't be
/// probed or decoded is handed to <c>failed</c> and skipped, so the others still load their waveform and levels and their cut edges
/// never wait on it. Only cancelling the load stops it.</summary>
internal static class RecordingLoads
{
    internal static async Task EachAsync<T>(IEnumerable<T> recordings, Func<T, Task> load, Action<T, Exception> failed, CancellationToken token)
    {
        foreach (var recording in recordings)
        {
            token.ThrowIfCancellationRequested();
            try { await load(recording); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception exception) when (exception is not OutOfMemoryException) { failed(recording, exception); }
        }
    }
}
