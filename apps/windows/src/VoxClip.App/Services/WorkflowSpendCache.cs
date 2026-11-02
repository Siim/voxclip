using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;

namespace VoxClip.App.Services;

internal static class WorkflowSpendCache
{
    private static readonly SemaphoreSlim serial = new(1, 1);
    internal static VoiceLabSpendTotal? Monthly { get; private set; }
    internal static event EventHandler? Changed;
    internal static async Task RefreshAsync(DataLocations locations)
    {
        await serial.WaitAsync();
        try { Monthly = await new VoiceLabSpendLedger(locations).TotalAsync("elevenlabs", DateTimeOffset.Now, CancellationToken.None); }
        catch (Exception exception) when (exception is not OutOfMemoryException) { Monthly = null; }
        finally { serial.Release(); }
        Changed?.Invoke(null, EventArgs.Empty);
    }
}
