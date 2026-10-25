using System.Diagnostics;
using System.Text.Json.Nodes;
using VoxClip.Core.Services.Process;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class ReviewProcessTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SilentAppServerHonorsTimeoutAndCancel(bool cancel)
    {
        if (!OperatingSystem.IsMacOS()) Assert.Skip("POSIX silent-child case; Windows has a native counterpart.");
        using var cancellation = new CancellationTokenSource();
        if (cancel) cancellation.CancelAfter(200);
        var stopwatch = Stopwatch.StartNew();
        var request = new ProcessRequest("/bin/sh", new[] { "-c", "exec /bin/sleep 45" }, Path.GetTempPath(), "{}\n{}\n{}\n", TimeSpan.FromMilliseconds(cancel ? 10000 : 200));
        var running = ((IAppServerRunner)new ProcessRunner()).RunAppServerAsync(request, cancellation.Token);
        if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
        else await Assert.ThrowsAsync<TimeoutException>(() => running.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(3.5), $"Silent app server took {stopwatch.Elapsed}.");
    }

    [Fact]
    public async Task SuccessfulLeaderDoesNotWaitForDescendantPipeEof()
    {
        if (!OperatingSystem.IsMacOS()) Assert.Skip("POSIX descendant pipe case.");
        var stopwatch = Stopwatch.StartNew();
        var result = await new ProcessRunner().RunAsync(new("/bin/sh", new[] { "-c", "/bin/sleep 45 & printf done" }, Path.GetTempPath(), null, TimeSpan.FromSeconds(10)), null, TestContext.Current.CancellationToken);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal("done", result.StandardOutput);
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(5));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ParallelSpawnsDoNotInheritOtherPipeEnds(bool appServer)
    {
        if (!OperatingSystem.IsMacOS()) Assert.Skip("POSIX descriptor isolation case.");
        var runner = new ProcessRunner();
        var jobs = Enumerable.Range(0, 8).Select(async index =>
        {
            if (appServer)
            {
                var script = "read init; printf '{\"id\":1}\n'; read ready; read list; printf '{\"id\":2}\n'; exec /bin/sleep 45";
                return await ((IAppServerRunner)runner).RunAppServerAsync(new("/bin/sh", new[] { "-c", script }, Path.GetTempPath(), "{}\n{}\n{}\n", TimeSpan.FromSeconds(5)), TestContext.Current.CancellationToken);
            }
            return await runner.RunAsync(new("/bin/sh", new[] { "-c", "/bin/cat; printf '%s' \"$1\"", "sh", index.ToString(System.Globalization.CultureInfo.InvariantCulture) }, Path.GetTempPath(), "stdin", TimeSpan.FromSeconds(5)), null, TestContext.Current.CancellationToken);
        });
        var results = await Task.WhenAll(jobs).WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.All(results, result => Assert.Equal(0, result.ExitCode));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AllRunnerEntryPointsRejectRelativeExecutables(bool appServer)
    {
        var request = new ProcessRequest("where.exe", [], Path.GetTempPath(), "{}\n{}\n{}\n", TimeSpan.FromSeconds(1));
        if (appServer) await Assert.ThrowsAsync<ArgumentException>(() => ((IAppServerRunner)new ProcessRunner()).RunAppServerAsync(request, CancellationToken.None));
        else await Assert.ThrowsAsync<ArgumentException>(() => new ProcessRunner().RunAsync(request, null, CancellationToken.None));
    }
}
