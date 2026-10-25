using Velopack;
using Velopack.Sources;
using VoxClip.Core.Services.Updates;

namespace VoxClip.App.Services;

internal sealed class VelopackUpdates(AppServices services) : IUpdateChecker
{
    private readonly UpdateManager manager = new(new GithubSource("https://github.com/Siim/voxclip", null, false));
    private Velopack.UpdateInfo? available;
    private readonly SemaphoreSlim check = new(1, 1);

    public async Task<Core.Services.Updates.UpdateInfo?> CheckAsync(bool manual, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!manager.IsInstalled || !manual && !services.Get("update.autoCheck", true)) return null;
        await check.WaitAsync(ct);
        try
        {
            if (!manual && DateTimeOffset.TryParse(services.Get("update.lastCheckAt", ""), out var last) && DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24)) return null;
            available = await manager.CheckForUpdatesAsync().WaitAsync(ct);
            await services.SetAsync("update.lastCheckAt", DateTimeOffset.UtcNow.ToString("O"), ct);
            return available is null ? null : new(available.TargetFullRelease.Version.ToString(), new("https://github.com/Siim/voxclip/releases"), false);
        }
        finally { check.Release(); }
    }

    public async Task DownloadAsync(Core.Services.Updates.UpdateInfo update, IProgress<double>? progress, CancellationToken ct)
    {
        var target = available ?? throw new InvalidOperationException("Check for updates first.");
        await manager.DownloadUpdatesAsync(target, percent => progress?.Report(percent / 100.0), cancelToken: ct);
        manager.WaitExitThenApplyUpdates(target.TargetFullRelease, silent: true, restart: false);
    }

    public Task ApplyAsync(Core.Services.Updates.UpdateInfo update, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (services.IsBusy) throw new InvalidOperationException("Finish the export first.");
        var target = available ?? throw new InvalidOperationException("Check for updates first.");
        manager.ApplyUpdatesAndRestart(target.TargetFullRelease);
        return Task.CompletedTask;
    }
}
