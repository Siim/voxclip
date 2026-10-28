using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

internal static class ConnectorPreflight
{
    internal static async Task<ConnectorStatus> ProbeAsync(Func<CancellationToken, Task<ConnectorStatus>> status, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return await status(ct);
    }

    internal static async Task<bool> AuthorizeAsync(ConnectorStatus status, bool granted,
        Func<CancellationToken, Task<bool>> consent, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (status is not ConnectorStatus.Ready) return false;
        if (!granted && !await consent(ct).WaitAsync(ct)) return false;
        ct.ThrowIfCancellationRequested();
        return true;
    }
}
