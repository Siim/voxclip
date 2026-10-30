#if WIN_UI_TESTS
// Compile the production update service against a recording SDK boundary on any host.
// This deliberately records WaitExitThenApplyUpdates too: the original bug must fail the test.
namespace Velopack
{
    internal sealed record VelopackAsset(string Version);
    internal sealed record UpdateInfo(VelopackAsset TargetFullRelease);

    internal sealed class UpdateProbe
    {
        internal bool Installed { get; set; } = true;
        internal UpdateInfo? Available { get; set; } = new(new("0.2.0"));
        internal VelopackAsset? Pending { get; set; }
        internal bool FailDownload { get; set; }
        internal List<string> Calls { get; } = [];
    }

    internal sealed class UpdateManager
    {
        internal static AsyncLocal<UpdateProbe?> Scope { get; } = new();
        private readonly UpdateProbe probe;
        internal UpdateManager(Sources.GithubSource source) => probe = Scope.Value ?? throw new InvalidOperationException("Missing test update scope.");
        internal bool IsInstalled => probe.Installed;
        internal VelopackAsset? UpdatePendingRestart => probe.Pending;
        internal Task<UpdateInfo?> CheckForUpdatesAsync()
        {
            probe.Calls.Add("check");
            return Task.FromResult(probe.Available);
        }
        internal Task DownloadUpdatesAsync(UpdateInfo update, Action<int>? progress, CancellationToken cancelToken)
        {
            cancelToken.ThrowIfCancellationRequested();
            probe.Calls.Add("download");
            if (probe.FailDownload) throw new IOException("Controlled download failure.");
            probe.Pending = update.TargetFullRelease;
            progress?.Invoke(100);
            return Task.CompletedTask;
        }
        internal void WaitExitThenApplyUpdates(VelopackAsset target, bool silent, bool restart) => probe.Calls.Add("arm-exit-apply");
        internal void ApplyUpdatesAndRestart(VelopackAsset target) => probe.Calls.Add("apply");
    }
}

namespace Velopack.Sources
{
    internal sealed class GithubSource
    {
        internal GithubSource(string repository, string? token, bool prerelease) { }
    }
}

namespace VoxClip.App.Services
{
    internal sealed class AppServices
    {
        internal Dictionary<string, object?> Values { get; } = [];
        internal bool IsBusy { get; set; }
        internal T Get<T>(string key, T fallback) => Values.TryGetValue(key, out var value) && value is T typed ? typed : fallback;
        internal Task SetAsync<T>(string key, T value, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            Values[key] = value;
            return Task.CompletedTask;
        }
    }
}
#endif
