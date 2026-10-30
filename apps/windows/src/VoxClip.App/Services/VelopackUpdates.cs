using System.Globalization;
using Velopack;
using Velopack.Sources;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Updates;

namespace VoxClip.App.Services;

internal sealed class VelopackUpdates(AppServices services) : IUpdateChecker
{
    private readonly UpdateManager manager = new(new GithubSource("https://github.com/Siim/voxclip", null, false));
    internal bool IsInstalled => manager.IsInstalled;
    private Velopack.UpdateInfo? available;
    private VelopackAsset? downloaded;
    private readonly SemaphoreSlim check = new(1, 1);

    public async Task<Core.Services.Updates.UpdateInfo?> CheckAsync(bool manual, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!manager.IsInstalled) return null;
        await check.WaitAsync(ct);
        try
        {
            // A downloaded package stays a user choice across launches, without a network check.
            if (manager.UpdatePendingRestart is { } pending)
            {
                downloaded = pending;
                return Ready(pending);
            }
            if (!manual && !services.Get("update.autoCheck", true)) return null;
            if (!manual && DateTimeOffset.TryParse(services.Get("update.lastCheckAt", ""), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var last)
                && DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24)) return null;
            available = await manager.CheckForUpdatesAsync().WaitAsync(ct);
            await services.SetAsync("update.lastCheckAt", UtcTimestamp.Format(DateTimeOffset.UtcNow), ct);
            return available is null ? null : new(available.TargetFullRelease.Version.ToString(), new("https://github.com/Siim/voxclip/releases"), false);
        }
        finally { check.Release(); }
    }

    public async Task DownloadAsync(Core.Services.Updates.UpdateInfo update, IProgress<double>? progress, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if ((downloaded ?? manager.UpdatePendingRestart) is { } pending && pending.Version.ToString() == update.Version)
        {
            downloaded = pending;
            return;
        }
        var target = available ?? throw new InvalidOperationException("Check for updates first.");
        if (target.TargetFullRelease.Version.ToString() != update.Version) throw new InvalidOperationException("The update changed. Check for updates again.");
        await manager.DownloadUpdatesAsync(target, percent => progress?.Report(percent / 100.0), cancelToken: ct);
        downloaded = target.TargetFullRelease;
    }

    public Task ApplyAsync(Core.Services.Updates.UpdateInfo update, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (services.IsBusy) throw new InvalidOperationException("Finish the export first.");
        var target = downloaded ?? manager.UpdatePendingRestart ?? throw new InvalidOperationException("Download the update first.");
        if (target.Version.ToString() != update.Version) throw new InvalidOperationException("The update changed. Check for updates again.");
        manager.ApplyUpdatesAndRestart(target);
        return Task.CompletedTask;
    }

    private static Core.Services.Updates.UpdateInfo Ready(VelopackAsset asset) =>
        new(asset.Version.ToString(), new("https://github.com/Siim/voxclip/releases"), false);
}
