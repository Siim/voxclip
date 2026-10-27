using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Process;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class ProcessAndCliTests
{
    [Theory]
    [InlineData(ConnectorId.ClaudeCode, false)]
    [InlineData(ConnectorId.ClaudeCode, true)]
    [InlineData(ConnectorId.Codex, false)]
    [InlineData(ConnectorId.Codex, true)]
    public async Task DetectionAndAuthTimeoutsAreClassifiedWithoutGenerating(ConnectorId id, bool auth)
    {
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(id, catalog, new());
        processes.Override = command => command.Arguments.Contains(auth ? id == ConnectorId.ClaudeCode ? "auth" : "login" : "--version") ? throw new TimeoutException() : null;
        using var http = new HttpClient();
        var connector = new LlmConnector(id, catalog, http, new MemoryKeys(null), new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        var label = id == ConnectorId.ClaudeCode ? "Claude Code" : "Codex";
        Assert.Equal($"{label} stopped with an error: The CLI could not be started or its output could not be read.", status.Reason);
        var failure = await Assert.ThrowsAsync<LlmException>(() => new LlmRunner(new MemoryKeys(null), catalog, new Redactor()).RunAsync(catalog.TestRequest(id), connector, "default", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Unavailable, failure.Error.Kind);
        Assert.Equal(VoxClipErrorCode.ProviderError, failure.Error.Code);
        Assert.EndsWith("Your edits are saved.", failure.Message, StringComparison.Ordinal);
        Assert.Empty(processes.Generations);
        Assert.All(processes.Requests, command => Assert.False(Directory.Exists(command.WorkingDirectory)));
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task CancelBeforeCliGateIsClassifiedWithoutStartingAProcess(ConnectorId id)
    {
        using var processes = new FixtureProcessRunner(id, Catalog(), new());
        using var http = new HttpClient();
        var connector = new LlmConnector(id, Catalog(), http, new MemoryKeys(null), new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(id), "default", cancellation.Token));
        Assert.Equal(LlmErrorKind.Cancelled, failure.Error.Kind);
        Assert.Empty(failure.Message);
        Assert.Empty(processes.Requests);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task SignedOutIsAnActionableGate(ConnectorId id)
    {
        var catalog = Catalog();
        using var runner = new FixtureProcessRunner(id, catalog, new());
        runner.Override = command => command.Arguments.Contains(id == ConnectorId.ClaudeCode ? "auth" : "login") ? new(1, "Not logged in", "", TimeSpan.Zero, false) : null;
        using var http = new HttpClient();
        var connector = new LlmConnector(id, catalog, http, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath);
        Assert.IsType<ConnectorStatus.CliSignedOut>(await connector.GetStatusAsync(CancellationToken.None));
        var exception = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "default", CancellationToken.None));
        Assert.Equal(LlmErrorKind.CliSignedOut, exception.Error.Kind);
        Assert.Contains(id == ConnectorId.ClaudeCode ? "run claude" : "codex login", exception.Message, StringComparison.Ordinal);
        Assert.EndsWith("Your edits are saved.", exception.Message, StringComparison.Ordinal);
        Assert.Empty(runner.Generations);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task RequiredFlagsAreCheckedWithoutGenerating(ConnectorId id)
    {
        using var runner = new FixtureProcessRunner(id, Catalog(), new JsonObject { ["supportedFlags"] = new JsonArray("--model") });
        using var http = new HttpClient();
        var connector = new LlmConnector(id, Catalog(), http, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath);
        Assert.IsType<ConnectorStatus.CliTooOld>(await connector.GetStatusAsync(CancellationToken.None));
        Assert.DoesNotContain(runner.Requests, command => command.Arguments.Contains("auth") || command.Arguments.Contains("login"));
        Assert.Empty(runner.Generations);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task DetectionIsCachedButAuthIsAlwaysChecked(ConnectorId id)
    {
        using var runner = new FixtureProcessRunner(id, Catalog(), new());
        using var http = new HttpClient();
        var connector = new LlmConnector(id, Catalog(), http, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath);
        await connector.GetStatusAsync(CancellationToken.None);
        await connector.GetStatusAsync(CancellationToken.None);
        Assert.Single(runner.Requests, command => command.Arguments.Contains("--version"));
        Assert.Equal(2, runner.Requests.Count(command => command.Arguments.Contains(id == ConnectorId.ClaudeCode ? "auth" : "login")));
        File.AppendAllText(runner.BinaryPath, "changed");
        await connector.GetStatusAsync(CancellationToken.None);
        Assert.Equal(2, runner.Requests.Count(command => command.Arguments.Contains("--version")));
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode, "{\"type\":\"result\",\"is_error\":true,\"result\":\"Not logged in\",\"api_error_status\":401}", 1, LlmErrorKind.CliSignedOut)]
    [InlineData(ConnectorId.ClaudeCode, "{\"type\":\"result\",\"is_error\":true,\"result\":\"usage limit reached\",\"api_error_status\":429}", 1, LlmErrorKind.PlanLimit)]
    [InlineData(ConnectorId.ClaudeCode, "{\"type\":\"result\",\"is_error\":true,\"result\":\"overloaded\",\"api_error_status\":529}", 1, LlmErrorKind.Overloaded)]
    [InlineData(ConnectorId.Codex, "{\"type\":\"turn.failed\",\"error\":{\"message\":\"Unauthorized\"}}", 1, LlmErrorKind.CliSignedOut)]
    [InlineData(ConnectorId.Codex, "{\"type\":\"turn.failed\",\"error\":{\"message\":\"rate limit\"}}", 1, LlmErrorKind.PlanLimit)]
    [InlineData(ConnectorId.Codex, "{\"type\":\"error\",\"message\":\"model_not_found\"}", 1, LlmErrorKind.ModelNotFound)]
    [InlineData(ConnectorId.Codex, "{\"type\":\"turn.failed\",\"error\":{\"message\":\"context length exceeded\"}}", 1, LlmErrorKind.ContextTooLong)]
    [InlineData(ConnectorId.Codex, "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{}\"}}", 0, LlmErrorKind.CliFailed)]
    public async Task CliFailuresAreClassifiedAndCleaned(ConnectorId id, string output, int exit, LlmErrorKind kind)
    {
        using var runner = new FixtureProcessRunner(id, Catalog(), new());
        runner.Override = command => command.Arguments.Contains("-p") || command.Arguments.Contains("--output-schema") ? new(exit, output, "", TimeSpan.Zero, false) : null;
        using var http = new HttpClient();
        var connector = new LlmConnector(id, Catalog(), http, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath);
        var exception = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(id), "default", CancellationToken.None));
        Assert.Equal(kind, exception.Error.Kind);
        Assert.All(runner.Requests, command => Assert.False(Directory.Exists(command.WorkingDirectory)));
    }

    /// <summary><c>cli-replies.json</c> (ai.md §4.5 and §6.8): each Claude result envelope goes through the connector, then its reply
    /// is read against the case's schema. The envelope is one strict parse of up to 512 levels; the reply, up to 64. The shared
    /// fixture runner calls this for every case.</summary>
    internal static async Task ClaudeReplyCase(JsonNode input, JsonNode expected)
    {
        var connectorId = VoiceRewriteBudgetTests.Connector(input["connector"]!.GetValue<string>());
        var stdout = input["stdout"]!.GetValue<string>();
        using var runner = new FixtureProcessRunner(connectorId, Catalog(), new());
        var stderr = input["stderr"]?.GetValue<string>() ?? "";
        runner.Override = command => command.Arguments.Contains("-p") || command.Arguments.Contains("--output-schema") || command.Arguments.Contains("app-server")
            ? new(0, stdout, stderr, TimeSpan.Zero, false) : null;
        using var http = new HttpClient();
        var connector = new LlmConnector(connectorId, Catalog(), http, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath);
        if (input["mode"]?.GetValue<string>() == "app-server")
        {
            var models = await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
            Assert.Equal(expected["models"]!.AsArray().Select(value => value!.GetValue<string>()), models.Select(model => model.Id));
            return;
        }
        var schema = input["schema"]!.DeepClone().AsObject();
        var request = new LlmRequest(LlmFeature.VoiceRewrite, "Rewrite the source.", null, "Return the rewrite.", "voice_rewrite_proposal", schema, 512,
            Effort.Medium, TimeSpan.FromSeconds(120), "en", "cli-reply");
        string outcome;
        try
        {
            var answer = await connector.SendAsync(request, input["model"]!.GetValue<string>(), TestContext.Current.CancellationToken);
            switch (answer.Stop)
            {
                case StopKind.Truncated: outcome = "truncated"; break;
                case StopKind.Refused refused: Assert.Null(refused.Category); outcome = "refused"; break;
                default:
                    var parsed = LlmOutput.Validate(answer, schema);
                    if (parsed.Object is null) { outcome = "invalidOutput"; break; }
                    Assert.Equal(expected["rewrite"]!.GetValue<string>(), parsed.Object["rewrite"]!.GetValue<string>());
                    Assert.Equal(expected["model"]!.GetValue<string>(), answer.Model);
                    outcome = "reply";
                    break;
            }
        }
        catch (LlmException exception)
        {
            if (expected["message"] is { } message) Assert.Equal(message.GetValue<string>(), exception.Error.Reason);
            outcome = exception.Error.Kind.ToString();
            outcome = char.ToLowerInvariant(outcome[0]) + outcome[1..];
        }
        Assert.Equal(expected["error"]?.GetValue<string>() ?? "reply", outcome);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task CliGenerationTimeoutAndCancellationCleanWorkspaces(ConnectorId id)
    {
        using var runner = new FixtureProcessRunner(id, Catalog(), new());
        using var http = new HttpClient();
        var connector = new LlmConnector(id, Catalog(), http, new MemoryKeys(null), new Redactor(), processes: runner, binaryOverride: runner.BinaryPath);
        runner.Override = command => command.Arguments.Contains("-p") || command.Arguments.Contains("--output-schema") ? throw new TimeoutException() : null;
        var timeout = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(id), "default", CancellationToken.None));
        Assert.Equal(LlmErrorKind.Timeout, timeout.Error.Kind);
        Assert.Equal($"{Catalog().Provider(id)["label"]!.GetValue<string>()} took too long to answer. Try again, or pick a faster model. Your edits are saved.", timeout.Message);
        using var cancellation = new CancellationTokenSource();
        runner.Override = command =>
        {
            if (!command.Arguments.Contains("-p") && !command.Arguments.Contains("--output-schema")) return null;
            cancellation.Cancel(); throw new OperationCanceledException(cancellation.Token);
        };
        var cancelled = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(id), "default", cancellation.Token));
        Assert.Equal(LlmErrorKind.Cancelled, cancelled.Error.Kind);
        Assert.Empty(cancelled.Message);
        Assert.All(runner.Requests, command => Assert.False(Directory.Exists(command.WorkingDirectory)));
    }

    [Fact]
    public async Task ProcessRunnerPreservesArgumentsStdinAndBothPipes()
    {
        RequireMac();
        var result = await new ProcessRunner().RunAsync(new("/bin/sh", new[] { "-c", "printf '%s' \"$1\"; /bin/cat; printf 'stderr-✓' >&2", "sh", "a\"b\\c\n😀" }, Path.GetTempPath(), "stdin-✓", TimeSpan.FromSeconds(10)), null, CancellationToken.None);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal("a\"b\\c\n😀stdin-✓", result.StandardOutput);
        Assert.Equal("stderr-✓", result.StandardError);
        Assert.False(result.OutputTruncated);
    }

    [Fact]
    public async Task ProcessRunnerDrainsBothPipesButCapsRetainedBytes()
    {
        RequireMac();
        var result = await new ProcessRunner().RunAsync(new("/bin/sh", new[] { "-c", "awk 'BEGIN { for(i=0;i<20000;i++) {printf \"abcdefghij\"; printf \"abcdefghij\" > \"/dev/stderr\"} }'" }, Path.GetTempPath(), null, TimeSpan.FromSeconds(10), OutputLimitBytes: 1024), null, CancellationToken.None);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal(1024, result.StandardOutput.Length);
        Assert.Equal(1024, result.StandardError.Length);
        Assert.True(result.OutputTruncated);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ProcessRunnerKillsGrandchildren(bool cancel)
    {
        RequireMac();
        var directory = Path.Combine(Path.GetTempPath(), "voxclip-tree-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var pidFile = Path.Combine(directory, "pid");
        try
        {
            using var cancellation = new CancellationTokenSource();
            var command = new ProcessRequest("/bin/sh", new[] { "-c", "trap '' TERM; /bin/sleep 45 & child=$!; printf '%s' \"$child\" > \"$1\"; wait", "sh", pidFile }, directory, null, TimeSpan.FromSeconds(cancel ? 15 : 1));
            var running = new ProcessRunner().RunAsync(command, null, cancellation.Token);
            for (var attempt = 0; !File.Exists(pidFile) && attempt < 100; attempt++) await Task.Delay(20, TestContext.Current.CancellationToken);
            Assert.True(File.Exists(pidFile));
            var pid = int.Parse(await File.ReadAllTextAsync(pidFile, TestContext.Current.CancellationToken), System.Globalization.CultureInfo.InvariantCulture);
            if (cancel) { cancellation.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running); }
            else await Assert.ThrowsAsync<TimeoutException>(() => running);
            var status = await new ProcessRunner().RunAsync(new("/bin/ps", new[] { "-o", "stat=", "-p", pid.ToString(System.Globalization.CultureInfo.InvariantCulture) }, directory, null, TimeSpan.FromSeconds(5)), null, CancellationToken.None);
            Assert.True(string.IsNullOrWhiteSpace(status.StandardOutput) || status.StandardOutput.TrimStart().StartsWith('Z'), "Grandchild is still running after tree termination.");
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("CLAUDE_CONFIG_DIR")]
    [InlineData("CODEX_HOME")]
    [InlineData("ANTHROPIC_API_KEY")]
    [InlineData("OPENAI_API_KEY")]
    [InlineData("ANTHROPIC_AUTH_TOKEN")]
    [InlineData("CLAUDE_CODE_OAUTH_TOKEN")]
    [InlineData("CODEX_API_KEY")]
    [InlineData("CODEX_ACCESS_TOKEN")]
    public async Task ProcessRunnerRejectsAuthenticationOverrides(string name)
    {
        var executable = OperatingSystem.IsWindows() ? Path.Combine(Environment.SystemDirectory, "where.exe") : "/bin/echo";
        var exception = await Assert.ThrowsAsync<ArgumentException>(() => new ProcessRunner().RunAsync(new(executable, [], Path.GetTempPath(), null, TimeSpan.FromSeconds(1), new Dictionary<string, string?> { [name] = "not-a-credential" }), null, CancellationToken.None));
        Assert.StartsWith("CLI authentication environment must be inherited unchanged.", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AppServerWaitsForInitializeBeforeModelList()
    {
        RequireMac();
        var script = "IFS= read -r init; printf '%s\\n' '{\"id\":1,\"result\":{}}'; IFS= read -r ready; IFS= read -r list; case \"$ready\" in *initialized*) ;; *) exit 5;; esac; printf '%s\\n' '{\"id\":2,\"result\":{\"data\":[]}}'; /bin/sleep 45";
        var request = new ProcessRequest("/bin/sh", new[] { "-c", script }, Path.GetTempPath(), "{\"id\":1,\"method\":\"initialize\"}\n{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"model/list\"}\n", TimeSpan.FromSeconds(10));
        var result = await ((IAppServerRunner)new ProcessRunner()).RunAppServerAsync(request, CancellationToken.None);
        Assert.Contains("\"id\":2", result.StandardOutput, StringComparison.Ordinal);
    }

    private static void RequireMac() { if (!OperatingSystem.IsMacOS()) Assert.Skip("Native POSIX process-group verification runs on macOS; Windows Job Object verification runs on the Windows VM."); }
}
