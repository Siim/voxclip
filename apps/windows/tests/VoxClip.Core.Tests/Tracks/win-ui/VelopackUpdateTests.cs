#if WIN_UI_TESTS
using Velopack;
using VoxClip.App.Services;
using VoxClip.Core.Domain.Shared;
using Xunit;

namespace VoxClip.Ui.Tests;

public sealed class VelopackUpdateTests
{
    [Fact]
    public void ManualUpdateCopyDistinguishesInstalledAndDevelopmentBuilds()
    {
        var root = Path.GetDirectoryName(Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR"))!;
        var source = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/MainWindow.xaml.cs"));
        Assert.Contains("Updates.IsInstalled ? $\"VoxClip {AppServices.Version} is the latest version.\"", source);
        Assert.Contains("Couldn't check for updates. You're offline.", source);
        var settings = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/SettingsWindow.xaml.cs"));
        Assert.DoesNotContain("Update check finished.", settings);
    }

    [Fact]
    public async Task AutomaticCheckAndBackgroundDownloadNeverApplyUntilUserChoosesRestart()
    {
        var probe = new UpdateProbe();
        UpdateManager.Scope.Value = probe;
        try
        {
            var updates = new VelopackUpdates(new AppServices());
            var update = Assert.IsType<Core.Services.Updates.UpdateInfo>(await updates.CheckAsync(false, CancellationToken.None));
            await updates.DownloadAsync(update, null, CancellationToken.None);
            await Task.Yield();
            Assert.Equal(new[] { "check", "download" }, probe.Calls);

            // This is the separate action dispatched by Restart now after its save/busy gates.
            await updates.ApplyAsync(update, CancellationToken.None);
            Assert.Equal(new[] { "check", "download", "apply" }, probe.Calls);
        }
        finally { UpdateManager.Scope.Value = null; }
    }

    [Fact]
    public async Task PendingPackageIsOfferedAfterRelaunchWithoutNetworkOrAutomaticApply()
    {
        var probe = new UpdateProbe { Pending = new("0.2.0") };
        UpdateManager.Scope.Value = probe;
        try
        {
            var services = new AppServices();
            services.Values["update.autoCheck"] = false;
            services.Values["update.lastCheckAt"] = UtcTimestamp.Format(DateTimeOffset.UtcNow);
            var updates = new VelopackUpdates(services);
            var update = Assert.IsType<Core.Services.Updates.UpdateInfo>(await updates.CheckAsync(false, CancellationToken.None));
            await updates.DownloadAsync(update, null, CancellationToken.None);
            Assert.Empty(probe.Calls);
            await updates.ApplyAsync(update, CancellationToken.None);
            Assert.Equal(new[] { "apply" }, probe.Calls);
        }
        finally { UpdateManager.Scope.Value = null; }
    }

    [Fact]
    public async Task DisabledAutomaticChecksDoNotContactTheFeed()
    {
        var probe = new UpdateProbe();
        UpdateManager.Scope.Value = probe;
        try
        {
            var services = new AppServices(); services.Values["update.autoCheck"] = false;
            Assert.Null(await new VelopackUpdates(services).CheckAsync(false, CancellationToken.None));
            Assert.Empty(probe.Calls);
        }
        finally { UpdateManager.Scope.Value = null; }
    }

    [Fact]
    public async Task FailedDownloadCannotBecomeAnApplyAction()
    {
        var probe = new UpdateProbe { FailDownload = true };
        UpdateManager.Scope.Value = probe;
        try
        {
            var updates = new VelopackUpdates(new AppServices());
            var update = Assert.IsType<Core.Services.Updates.UpdateInfo>(await updates.CheckAsync(false, CancellationToken.None));
            await Assert.ThrowsAsync<IOException>(() => updates.DownloadAsync(update, null, CancellationToken.None));
            await Assert.ThrowsAsync<InvalidOperationException>(() => updates.ApplyAsync(update, CancellationToken.None));
            Assert.Equal(new[] { "check", "download" }, probe.Calls);
        }
        finally { UpdateManager.Scope.Value = null; }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task BusyOrCancelledRestartNeverInvokesTheUpdater(bool busy)
    {
        var probe = new UpdateProbe { Pending = new("0.2.0") };
        UpdateManager.Scope.Value = probe;
        try
        {
            var services = new AppServices { IsBusy = busy };
            var updates = new VelopackUpdates(services);
            var update = Assert.IsType<Core.Services.Updates.UpdateInfo>(await updates.CheckAsync(false, CancellationToken.None));
            if (busy) await Assert.ThrowsAsync<InvalidOperationException>(() => updates.ApplyAsync(update, CancellationToken.None));
            else await Assert.ThrowsAnyAsync<OperationCanceledException>(() => updates.ApplyAsync(update, new CancellationToken(true)));
            Assert.Empty(probe.Calls);
        }
        finally { UpdateManager.Scope.Value = null; }
    }

    [Fact]
    public async Task CheckingWithoutDownloadingDoesNotAuthorizeApply()
    {
        var probe = new UpdateProbe();
        UpdateManager.Scope.Value = probe;
        try
        {
            var updates = new VelopackUpdates(new AppServices());
            var update = Assert.IsType<Core.Services.Updates.UpdateInfo>(await updates.CheckAsync(false, CancellationToken.None));
            await Assert.ThrowsAsync<InvalidOperationException>(() => updates.ApplyAsync(update, CancellationToken.None));
            Assert.Equal(new[] { "check" }, probe.Calls);
        }
        finally { UpdateManager.Scope.Value = null; }
    }

    [Fact]
    public void StartupAndAutomaticWindowRouteLeaveApplyToTheExplicitAction()
    {
        var root = RepositoryRoot();
        var program = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/Program.cs"));
        Assert.Contains("VelopackApp.Build().SetAutoApplyOnStartup(false).Run()", program);
        var window = File.ReadAllText(Path.Combine(root, "apps/windows/src/VoxClip.App/MainWindow.xaml.cs"));
        var start = window.IndexOf("internal async Task CheckUpdatesAsync", StringComparison.Ordinal);
        var choice = window.IndexOf("restart.Click +=", start, StringComparison.Ordinal);
        Assert.True(start >= 0 && choice > start);
        var automatic = window[start..choice];
        Assert.Contains("Updates.CheckAsync(", automatic);
        Assert.Contains("Updates.DownloadAsync(", automatic);
        Assert.DoesNotContain("ApplyAsync(", automatic);
    }

    private static string RepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "apps/windows/src/VoxClip.App/Program.cs"))) return directory.FullName;
        throw new DirectoryNotFoundException("Repository source not found.");
    }
}
#endif
