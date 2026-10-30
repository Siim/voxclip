using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

internal sealed record VoiceLabKeyStatus(string Provider, string Account, bool Saved, bool Unreadable);

internal sealed class VoiceLabKeyInventory(IKeyProvider keys, Func<bool> enabled, CancellationToken lifetime) : IDisposable
{
    private CancellationTokenSource? pending;
    private int generation;
    private bool loaded;
    private bool disposed;
    internal IReadOnlyList<VoiceLabKeyStatus> Rows { get; private set; } = [];
    internal event EventHandler? Changed;

    internal async Task RefreshAsync()
    {
        if (disposed) return;
        if (!enabled())
        {
            generation++;
            pending?.Cancel();
            pending = null;
            loaded = false;
            Rows = [];
            Changed?.Invoke(this, EventArgs.Empty);
            return;
        }
        if (loaded) return;
        loaded = true;
        var epoch = ++generation;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        pending = cancellation;
        var rows = new List<VoiceLabKeyStatus>();
        bool Current() => !disposed && enabled() && epoch == generation && !cancellation.IsCancellationRequested;
        try
        {
            foreach (var provider in new[] { ("ElevenLabs", "elevenlabs-api-key"), ("fal.ai", "fal-api-key"), ("sync.so", "syncso-api-key") })
            {
                if (!Current()) return;
                var saved = false;
                var unreadable = false;
                try { saved = await keys.GetKeyAsync(provider.Item2, cancellation.Token) is not null; }
                catch (Exception error) when (error is not OperationCanceledException) { saved = true; unreadable = true; }
                if (!Current()) return;
                rows.Add(new(provider.Item1, provider.Item2, saved, unreadable));
            }
            if (!Current()) return;
            Rows = rows;
            Changed?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally
        {
            if (epoch == generation) pending = null;
        }
    }

    public void Dispose()
    {
        disposed = true;
        generation++;
        pending?.Cancel();
        pending = null;
        Rows = [];
    }
}
