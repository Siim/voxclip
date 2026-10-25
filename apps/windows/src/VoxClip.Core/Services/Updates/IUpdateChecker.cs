namespace VoxClip.Core.Services.Updates;

/// <summary>Update result; architecture §13.2. Development installs do not check automatically.</summary>
public sealed record UpdateInfo(string Version, Uri ReleaseUrl, bool Downloaded);
/// <summary>Cancelable update facade, platform implementation owned by UI; architecture §13.</summary>
public interface IUpdateChecker
{
    /// <summary>Throttled or manual check with no auth token.</summary>
    Task<UpdateInfo?> CheckAsync(bool manual, CancellationToken ct);
    /// <summary>Download an update from the current architecture's feed.</summary>
    Task DownloadAsync(UpdateInfo update, IProgress<double>? progress, CancellationToken ct);
    /// <summary>Restart only when no export/transcription is active.</summary>
    Task ApplyAsync(UpdateInfo update, CancellationToken ct);
}
/// <summary>Safe development-build placeholder owned by win-ui.</summary>
public sealed class UpdateChecker : IUpdateChecker
{
    // TODO(win-ui): connect Velopack; development startup currently reports no available update.
    /// <inheritdoc />
    public Task<UpdateInfo?> CheckAsync(bool manual, CancellationToken ct) => Task.FromResult<UpdateInfo?>(null);
    /// <inheritdoc />
    public Task DownloadAsync(UpdateInfo update, IProgress<double>? progress, CancellationToken ct) => ServiceStub.Missing("win-ui", ct);
    /// <inheritdoc />
    public Task ApplyAsync(UpdateInfo update, CancellationToken ct) => ServiceStub.Missing("win-ui", ct);
}
