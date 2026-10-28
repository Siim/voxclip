using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

internal static class ConnectorPreflight
{
    internal static async Task<ConnectorStatus?> ProbeAsync(bool granted, Func<CancellationToken, Task<bool>>? consent,
        Func<CancellationToken, Task<ConnectorStatus>> status, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!granted && (consent is null || !await consent(ct).WaitAsync(ct))) return null;
        ct.ThrowIfCancellationRequested();
        return await status(ct);
    }
}
