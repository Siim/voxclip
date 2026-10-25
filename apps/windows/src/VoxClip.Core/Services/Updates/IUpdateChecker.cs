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
/// <summary>Platform-free update facade. The application supplies a Velopack backend; Core never references native packages.</summary>
public sealed class UpdateChecker : IUpdateChecker
{
    private readonly IUpdateChecker? backend;
    /// <summary>Development hosts may omit the backend; installed applications supply their platform adapter.</summary>
    public UpdateChecker(IUpdateChecker? backend = null) => this.backend = backend;
    /// <inheritdoc />
    public Task<UpdateInfo?> CheckAsync(bool manual, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return backend?.CheckAsync(manual, ct) ?? Task.FromResult<UpdateInfo?>(null);
    }
    /// <inheritdoc />
    public Task DownloadAsync(UpdateInfo update, IProgress<double>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return backend?.DownloadAsync(update, progress, ct) ?? Task.FromException(new InvalidOperationException("Updates are available only in an installed VoxClip build."));
    }
    /// <inheritdoc />
    public Task ApplyAsync(UpdateInfo update, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return backend?.ApplyAsync(update, ct) ?? Task.FromException(new InvalidOperationException("Updates are available only in an installed VoxClip build."));
    }
}
