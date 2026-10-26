using System.Diagnostics;
using Xunit;

namespace VoxClip.Media.Tests.E2E;

public sealed class CliProcessCleanupTests
{
    [Fact]
    public async Task ObserverFailureReapsStartedCli()
    {
        var pid = 0;
        var failure = new InvalidDataException("observer failed before CLI exit");
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => MediaCliE2ETests.RunProcess(
            Sleeper(), (process, _) =>
            {
                pid = process.Id;
                return Task.FromException(failure);
            }, TestContext.Current.CancellationToken, TimeSpan.FromSeconds(20)));
        Assert.Same(failure, error);
        AssertStopped(pid);
    }

    [Fact]
    public async Task CancellationReapsStartedCliAndObserver()
    {
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var pid = 0;
        var observerStopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var error = await Assert.ThrowsAnyAsync<OperationCanceledException>(() => MediaCliE2ETests.RunProcess(
            Sleeper(), async (process, token) =>
            {
                pid = process.Id;
                cancellation.Cancel();
                try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
                finally { observerStopped.TrySetResult(); }
            }, cancellation.Token, TimeSpan.FromSeconds(20)));
        Assert.True(error.CancellationToken.IsCancellationRequested);
        Assert.True(observerStopped.Task.IsCompleted);
        AssertStopped(pid);
    }

    private static ProcessStartInfo Sleeper()
    {
        var start = OperatingSystem.IsWindows()
            ? new ProcessStartInfo("powershell.exe")
            : new ProcessStartInfo("/bin/sh");
        start.UseShellExecute = false;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        if (OperatingSystem.IsWindows())
        {
            start.ArgumentList.Add("-NoProfile");
            start.ArgumentList.Add("-NonInteractive");
            start.ArgumentList.Add("-Command");
            start.ArgumentList.Add("Start-Sleep -Seconds 30");
        }
        else
        {
            start.ArgumentList.Add("-c");
            start.ArgumentList.Add("sleep 30");
        }
        return start;
    }

    private static void AssertStopped(int pid)
    {
        Assert.True(pid > 0);
        Assert.Throws<ArgumentException>(() => Process.GetProcessById(pid));
    }
}
