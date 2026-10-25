using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Process;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class WindowsProcessTests(WindowsNativeProbe probe) : IClassFixture<WindowsNativeProbe>
{
    private static void RequireWindows() { if (!OperatingSystem.IsWindows()) Assert.Skip("Windows-native process verification."); }

    [Fact]
    public async Task ArgumentListRoundTripsQuotesNewlinesBackslashesAndEmptyArgs()
    {
        RequireWindows();
        var arguments = new[] { "--argv", "", "--tools", "", "a\"b\\c\n😀", "backslash\\\"quote", "trailing\\", "line1\nline2\r\nline3", "&|<>%notexpanded%" };
        var result = await new ProcessRunner().RunAsync(new(probe.Executable, arguments, probe.DirectoryPath, "stdin-✓", TimeSpan.FromSeconds(10)), null, TestContext.Current.CancellationToken);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal(arguments.Skip(1), JsonSerializer.Deserialize<string[]>(result.StandardOutput));
        Assert.Equal("stdin-✓", result.StandardError);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task JobObjectKillsGrandchildrenOnTimeoutAndCancel(bool cancel)
    {
        RequireWindows();
        await VerifyJobObjectCleanupAsync(cancel);
    }

    [Fact]
    public async Task ReadinessFailureCancelsAndReapsOwnedProcessTree()
    {
        RequireWindows();
        var childPid = 0;
        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => VerifyJobObjectCleanupAsync(true, pid =>
        {
            childPid = pid;
            throw new InvalidOperationException("Injected failure while the PID file is incomplete.");
        }));
        Assert.Equal("Injected failure while the PID file is incomplete.", failure.Message);
        Assert.False(failure.Data.Contains("CleanupFailure"), failure.Data["CleanupFailure"]?.ToString());
        Assert.True(childPid > 0);
        Assert.False(IsRunning(childPid), "Early failure left the grandchild running.");
        Assert.Empty(Directory.EnumerateFiles(probe.DirectoryPath, "*.pid*"));
    }

    private async Task VerifyJobObjectCleanupAsync(bool cancel, Action<int>? beforeReady = null)
    {
        var pidFile = Path.Combine(probe.DirectoryPath, Guid.NewGuid().ToString("N") + ".pid");
        var pendingFile = pidFile + ".pending";
        var writingFile = pidFile + ".writing";
        var releaseFile = pidFile + ".release";
        using var cancellation = new CancellationTokenSource();
        var running = new ProcessRunner().RunAsync(new(probe.Executable, new[] { "--spawn", pidFile }, probe.DirectoryPath, null, TimeSpan.FromSeconds(cancel ? 20 : 3)), null, cancellation.Token);
        int? pid = null;
        Exception? primaryFailure = null;
        try
        {
            var readiness = Stopwatch.StartNew();
            while (!File.Exists(writingFile) && readiness.Elapsed < TimeSpan.FromSeconds(2))
                await Task.Delay(20, TestContext.Current.CancellationToken);
            Assert.True(File.Exists(writingFile), "The native probe did not enter its partial PID write.");
            pid = int.Parse(await File.ReadAllTextAsync(writingFile, TestContext.Current.CancellationToken), System.Globalization.CultureInfo.InvariantCulture);
            Assert.False(File.Exists(pidFile), "The final PID path was visible before publication.");
            Assert.Throws<IOException>(() => File.ReadAllText(pendingFile));
            beforeReady?.Invoke(pid.Value);
            File.WriteAllText(releaseFile, "ready");
            while (!File.Exists(pidFile) && readiness.Elapsed < TimeSpan.FromSeconds(2))
                await Task.Delay(20, TestContext.Current.CancellationToken);
            Assert.True(File.Exists(pidFile), "The native probe did not publish the completed PID.");
            Assert.Equal(pid.Value, int.Parse(await File.ReadAllTextAsync(pidFile, TestContext.Current.CancellationToken), System.Globalization.CultureInfo.InvariantCulture));

            var stopwatch = Stopwatch.StartNew();
            if (cancel) cancellation.Cancel();
            if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running.WaitAsync(TimeSpan.FromSeconds(6), TestContext.Current.CancellationToken));
            else await Assert.ThrowsAsync<TimeoutException>(() => running.WaitAsync(TimeSpan.FromSeconds(6), TestContext.Current.CancellationToken));
            Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(6));
            Assert.False(IsRunning(pid.Value), "Grandchild survived Job Object closure.");
        }
        catch (Exception exception) { primaryFailure = exception; throw; }
        finally
        {
            try
            {
                cancellation.Cancel();
                Exception? cleanupFailure = null;
                try { await running.WaitAsync(TimeSpan.FromSeconds(8)); }
                catch (OperationCanceledException) { }
                catch (TimeoutException) when (running.IsCompleted) { }
                catch (Exception exception) { cleanupFailure = exception; }
                try
                {
                    if (pid is int childPid && IsRunning(childPid))
                    {
                        using var child = System.Diagnostics.Process.GetProcessById(childPid);
                        child.Kill(true);
                        await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                    }
                }
                catch (ArgumentException) { }
                catch (Exception exception) { cleanupFailure ??= exception; }
                foreach (var file in new[] { pidFile, pendingFile, writingFile, writingFile + ".tmp", releaseFile })
                    try { File.Delete(file); } catch (Exception exception) { cleanupFailure ??= exception; }
                if (cleanupFailure is not null) throw cleanupFailure;
            }
            catch (Exception cleanupFailure) when (primaryFailure is not null)
            {
                primaryFailure.Data["CleanupFailure"] = cleanupFailure.ToString();
            }
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SilentAppServerHonorsTimeoutAndCancel(bool cancel)
    {
        RequireWindows();
        using var cancellation = new CancellationTokenSource();
        if (cancel) cancellation.CancelAfter(300);
        var stopwatch = Stopwatch.StartNew();
        var running = ((IAppServerRunner)new ProcessRunner()).RunAppServerAsync(new(probe.Executable, new[] { "--hold" }, probe.DirectoryPath, "{}\n{}\n{}\n", TimeSpan.FromMilliseconds(cancel ? 10000 : 300)), cancellation.Token);
        if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
        else await Assert.ThrowsAsync<TimeoutException>(() => running.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(3.5));
    }

    [Fact]
    public async Task BadExecutableMapsToPathFreeIOExceptionAndUnavailable()
    {
        RequireWindows();
        var broken = Path.Combine(probe.DirectoryPath, "not-a-program.exe");
        await File.WriteAllTextAsync(broken, "not a PE executable", TestContext.Current.CancellationToken);
        var failure = await Assert.ThrowsAsync<IOException>(() => new ProcessRunner().RunAsync(new(broken, [], probe.DirectoryPath, null, TimeSpan.FromSeconds(2)), null, CancellationToken.None));
        Assert.Equal("Could not start the process.", failure.Message);
        Assert.Null(failure.InnerException);
        var connector = new LlmConnector(ConnectorId.ClaudeCode, new MemoryKeys(null), Catalog(), new Redactor(), cliPath: broken);
        var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Equal("Claude Code stopped with an error: The CLI could not be started or its output could not be read.", status.Reason);
    }

    [Theory]
    [InlineData(".exe", true)]
    [InlineData(".cmd", true)]
    [InlineData("", true)]
    [InlineData(".bat", false)]
    [InlineData(".ps1", false)]
    [InlineData(".sh", false)]
    [InlineData("", false)]
    public async Task WindowsCliResolutionOnlyRunsNativeExeOrNodeShim(string extension, bool supported)
    {
        RequireWindows();
        var catalog = Catalog();
        using var runner = new FixtureProcessRunner(ConnectorId.ClaudeCode, catalog, new());
        var directory = Path.GetDirectoryName(runner.BinaryPath)!;
        var path = Path.Combine(directory, "shim" + extension);
        File.WriteAllText(path, "fake shim");
        if (extension.Length == 0 && supported) File.WriteAllText(path + ".cmd", "fake shim");
        var node = Path.Combine(directory, "node.exe");
        File.WriteAllText(node, "fake node");
        var script = Path.Combine(directory, "node_modules", "@anthropic-ai", "claude-code", "cli.js");
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(script)!);
        File.WriteAllText(script, "fake script");
        using var client = new HttpClient();
        var connector = new LlmConnector(ConnectorId.ClaudeCode, catalog, client, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: path);
        var status = await connector.GetStatusAsync(TestContext.Current.CancellationToken);
        if (!supported) { Assert.IsType<ConnectorStatus.CliMissing>(status); Assert.Empty(runner.Requests); return; }
        Assert.IsType<ConnectorStatus.Ready>(status);
        await connector.SendAsync(catalog.TestRequest(ConnectorId.ClaudeCode), "default", TestContext.Current.CancellationToken);
        Assert.All(runner.Requests, request =>
        {
            Assert.Equal(extension == ".exe" ? path : node, request.Executable);
            if (extension != ".exe") Assert.Equal(script, request.Arguments[0]);
        });
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode, false)]
    [InlineData(ConnectorId.ClaudeCode, true)]
    [InlineData(ConnectorId.Codex, false)]
    [InlineData(ConnectorId.Codex, true)]
    public async Task ExplicitNpmShimUsesNodeEvenWithANativeSibling(ConnectorId id, bool lookupNode)
    {
        RequireWindows();
        var catalog = Catalog();
        using var runner = new FixtureProcessRunner(id, catalog, new());
        var directory = Path.GetDirectoryName(runner.BinaryPath)!;
        var shim = Path.ChangeExtension(runner.BinaryPath, ".cmd");
        File.WriteAllText(shim, "fake shim");
        var node = Path.Combine(directory, "node.exe");
        File.WriteAllText(node, "fake node");
        var components = id == ConnectorId.ClaudeCode ? new[] { "node_modules", "@anthropic-ai", "claude-code", "cli.js" } : new[] { "node_modules", "@openai", "codex", "bin", "codex.js" };
        var script = Path.Combine(new[] { directory }.Concat(components).ToArray());
        System.IO.Directory.CreateDirectory(Path.GetDirectoryName(script)!);
        File.WriteAllText(script, "fake script");
        if (lookupNode)
        {
            var alternate = Path.Combine(directory, "runtime");
            System.IO.Directory.CreateDirectory(alternate);
            var resolved = Path.Combine(alternate, "node.exe");
            File.Move(node, resolved);
            node = resolved;
            runner.Override = request => Path.GetFileName(request.Executable).Equals("where.exe", StringComparison.OrdinalIgnoreCase)
                ? new(0, Path.Combine(directory, "node") + "\r\n" + shim + "\r\n" + resolved + "\r\n", "", TimeSpan.Zero, false) : null;
        }
        using var client = new HttpClient();
        var connector = new LlmConnector(id, catalog, client, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: shim);
        Assert.IsType<ConnectorStatus.Ready>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        await connector.SendAsync(catalog.TestRequest(id), "default", TestContext.Current.CancellationToken);
        Assert.All(runner.Requests, request =>
        {
            if (Path.GetFileName(request.Executable).Equals("where.exe", StringComparison.OrdinalIgnoreCase))
            {
                Assert.Equal(Path.Combine(Environment.SystemDirectory, "where.exe"), request.Executable);
                Assert.Equal(new[] { "node" }, request.Arguments);
            }
            else
            {
                Assert.Equal(node, request.Executable);
                Assert.Equal(script, request.Arguments[0]);
            }
        });
        Assert.Equal(lookupNode ? 1 : 0, runner.Requests.Count(request => Path.GetFileName(request.Executable).Equals("where.exe", StringComparison.OrdinalIgnoreCase)));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingOverrideFallsThroughAndWhereUsesSystemDirectory(bool useWhere)
    {
        RequireWindows();
        var catalog = Catalog();
        using var runner = new FixtureProcessRunner(ConnectorId.Codex, catalog, new());
        catalog.Provider(ConnectorId.Codex)["cli"]!["searchPaths"]!["windows"] = useWhere ? new JsonArray() : new JsonArray(runner.BinaryPath);
        runner.Override = request => Path.GetFileName(request.Executable).Equals("where.exe", StringComparison.OrdinalIgnoreCase) ? new(0, Path.ChangeExtension(runner.BinaryPath, null) + "\r\n" + Path.ChangeExtension(runner.BinaryPath, ".ps1") + "\r\n" + runner.BinaryPath + "\r\n", "", TimeSpan.Zero, false) : null;
        using var client = new HttpClient();
        var connector = new LlmConnector(ConnectorId.Codex, catalog, client, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: Path.Combine(Path.GetDirectoryName(runner.BinaryPath)!, "gone.exe"));
        Assert.IsType<ConnectorStatus.Ready>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        if (useWhere) Assert.Equal(Path.Combine(Environment.SystemDirectory, "where.exe"), runner.Requests[0].Executable);
        Assert.All(runner.Requests, request => Assert.True(Path.IsPathFullyQualified(request.Executable)));
    }

    private static bool IsRunning(int pid)
    {
        try { using var process = System.Diagnostics.Process.GetProcessById(pid); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }
}

public sealed class WindowsNativeProbe : IAsyncLifetime
{
    internal string DirectoryPath { get; } = Path.Combine(Path.GetTempPath(), "voxclip-native-probe-" + Guid.NewGuid().ToString("N"));
    internal string Executable => Path.Combine(DirectoryPath, "out", "NativeProbe.exe");
    public async ValueTask InitializeAsync()
    {
        if (!OperatingSystem.IsWindows()) return;
        Directory.CreateDirectory(DirectoryPath);
        await File.WriteAllTextAsync(Path.Combine(DirectoryPath, "NativeProbe.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><UseAppHost>true</UseAppHost></PropertyGroup></Project>");
        await File.WriteAllTextAsync(Path.Combine(DirectoryPath, "Program.cs"), """
            using System.Diagnostics;
            using System.Text.Json;
            Console.InputEncoding = new System.Text.UTF8Encoding(false);
            Console.OutputEncoding = new System.Text.UTF8Encoding(false);
            if (args[0] == "--argv") { Console.Write(JsonSerializer.Serialize(args.Skip(1).ToArray())); Console.Error.Write(Console.In.ReadToEnd()); return; }
            if (args[0] == "--spawn")
            {
                var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
                start.ArgumentList.Add("--hold");
                using var child = Process.Start(start)!;
                var pid = child.Id.ToString(System.Globalization.CultureInfo.InvariantCulture);
                var bytes = System.Text.Encoding.UTF8.GetBytes(pid);
                using (var writer = new FileStream(args[1] + ".pending", FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    writer.Write(bytes, 0, 1);
                    writer.Flush(true);
                    File.WriteAllText(args[1] + ".writing.tmp", pid);
                    File.Move(args[1] + ".writing.tmp", args[1] + ".writing");
                    if (!SpinWait.SpinUntil(() => File.Exists(args[1] + ".release"), TimeSpan.FromSeconds(10)))
                        throw new TimeoutException("The PID publication gate was not released.");
                    writer.SetLength(0);
                    writer.Write(bytes);
                    writer.Flush(true);
                }
                File.Move(args[1] + ".pending", args[1]);
            }
            Thread.Sleep(120000);
            """);
        var result = await new ProcessRunner().RunAsync(new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "dotnet", "dotnet.exe"), new[] { "build", "-c", "Release", "-o", "out", "--nologo", "--disable-build-servers" }, DirectoryPath, null, TimeSpan.FromSeconds(120)), null, CancellationToken.None);
        Assert.True(result.ExitCode == 0, result.StandardOutput + result.StandardError);
    }
    public ValueTask DisposeAsync()
    {
        if (Directory.Exists(DirectoryPath)) Directory.Delete(DirectoryPath, true);
        return ValueTask.CompletedTask;
    }
}
