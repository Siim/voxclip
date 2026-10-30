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
    internal static async Task<VoxClip.Core.Domain.Clips.AiResult?> FindAsync(IClipFinder finder, ClipFinderRequest request,
        Func<CancellationToken, Task<bool>> consent, CancellationToken ct)
    {
        if (!await consent(ct).WaitAsync(ct)) return null;
        ct.ThrowIfCancellationRequested();
        return await finder.FindClipsAsync(request, null, ct);
    }

    internal static async Task<LlmConnectionTestResult?> TestAsync(LlmRunner runner, ILlmConnector connector, string model,
        Func<CancellationToken, Task<bool>> consent, CancellationToken ct)
    {
        if (!await consent(ct).WaitAsync(ct)) return null;
        ct.ThrowIfCancellationRequested();
        return await runner.TestAsync(connector, model, ct);
    }
}
