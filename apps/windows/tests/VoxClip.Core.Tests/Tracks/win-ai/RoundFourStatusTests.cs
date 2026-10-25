using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Process;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
[Collection("WinAiDataIsolation")]
public sealed class RoundFourStatusTests
{
    [Theory]
    [InlineData(ConnectorId.Ollama, "Ollama")]
    [InlineData(ConnectorId.LmStudio, "LM Studio")]
    public async Task LocalProbe400DoesNotIncludeTheProviderMessage(ConnectorId id, string label)
    {
        var keys = new MemoryKeys();
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(400, "{\"error\":{\"message\":\"test-only-provider-detail\"}}")));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(id, keys, new ProcessRunner(), Catalog(), http);
        var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Equal($"{label} rejected the request (400).", status.Reason);
        Assert.DoesNotContain("test-only-provider-detail", status.Reason, StringComparison.Ordinal);
        Assert.Single(handler.Requests);
        Assert.Empty(keys.Accounts);
    }

    [Theory]
    [InlineData(ConnectorId.Ollama, "Ollama")]
    [InlineData(ConnectorId.LmStudio, "LM Studio")]
    public async Task LocalProbe404ReturnsTheInvalidSettingsAddressStatus(ConnectorId id, string label)
    {
        var catalog = Catalog();
        var keys = new MemoryKeys();
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(404, "{}")));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(id, keys, new ProcessRunner(), catalog, http);
        var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Equal($"{label}'s server address in Settings isn't valid.", status.Reason);
        Assert.Single(handler.Requests);
        Assert.Empty(keys.Accounts);
        var refreshing = new LlmConnector(id, catalog, http, keys, new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => refreshing.GetModelsAsync(true, TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Unavailable, failure.Error.Kind);
        Assert.Equal(404, failure.Error.Status);
        Assert.Contains(status.Reason, refreshing.RefreshWarning!, StringComparison.Ordinal);
        Assert.DoesNotContain("doesn't offer the model", refreshing.RefreshWarning!, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingOllamaModelDetailsStillReportModelNotFound()
    {
        var catalog = Catalog();
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(404, "{}")));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Ollama, catalog, http, new MemoryKeys(null), new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.GetContextTokensAsync("removed:latest", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.ModelNotFound, failure.Error.Kind);
        Assert.Equal("removed:latest", failure.Error.Model);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode, false)]
    [InlineData(ConnectorId.ClaudeCode, true)]
    [InlineData(ConnectorId.Codex, false)]
    [InlineData(ConnectorId.Codex, true)]
    public async Task CliProbeFailuresReturnSafeUnavailableStatuses(ConnectorId id, bool auth)
    {
        foreach (var failure in new[] { "io", "win32", "unexpected", "cancel", "truncated" }.Concat(auth ? ["exit"] : Array.Empty<string>()))
        {
            var catalog = Catalog();
            using var processes = new FixtureProcessRunner(id, catalog, new());
            catalog.Provider(id)["cli"]!["searchPaths"]![OperatingSystem.IsWindows() ? "windows" : "macos"] = new JsonArray(processes.BinaryPath);
            processes.Override = command =>
            {
                if (!command.Arguments.Contains(auth ? id == ConnectorId.ClaudeCode ? "auth" : "login" : "--version")) return null;
                return failure switch
                {
                    "io" => throw new IOException("test-only-probe-detail"),
                    "win32" => throw new System.ComponentModel.Win32Exception("test-only-probe-detail"),
                    "unexpected" => throw new InvalidOperationException("test-only-probe-detail"),
                    "cancel" => throw new OperationCanceledException(),
                    "exit" => new(2, "test-only-probe-detail", "test-only-probe-detail", TimeSpan.Zero, false),
                    _ => new(0, "test-only-probe-detail", "", TimeSpan.Zero, true)
                };
            };
            using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("CLI probes must not send HTTP."));
            using var http = new HttpClient(handler);
            var keys = new MemoryKeys(null);
            var connector = new LlmConnector(id, keys, processes, catalog, http);
            var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
            var label = id == ConnectorId.ClaudeCode ? "Claude Code" : "Codex";
            Assert.Equal($"{label} stopped with an error: The CLI could not be started or its output could not be read.", status.Reason);
            Assert.DoesNotContain("test-only-probe-detail", status.Reason, StringComparison.Ordinal);
            Assert.DoesNotContain("Your edits are saved.", status.Reason, StringComparison.Ordinal);
            Assert.Empty(processes.Generations);
            Assert.Empty(keys.Accounts);
            Assert.Empty(handler.Requests);
        }
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode, 1, "not JSON", "")]
    [InlineData(ConnectorId.ClaudeCode, 0, "{\"loggedIn\":false}", "")]
    [InlineData(ConnectorId.ClaudeCode, 2, "{\"loggedIn\":false}", "")]
    [InlineData(ConnectorId.Codex, 1, "", "")]
    [InlineData(ConnectorId.Codex, 0, "Not logged in", "")]
    [InlineData(ConnectorId.Codex, 2, "Not logged in", "")]
    [InlineData(ConnectorId.Codex, 2, "", "Not logged in")]
    public async Task SignedOutSignalsTakePrecedenceOverUnexpectedAuthExitCodes(ConnectorId id, int exitCode, string output, string error)
    {
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(id, catalog, new());
        processes.Override = command => command.Arguments.Contains(id == ConnectorId.ClaudeCode ? "auth" : "login")
            ? new(exitCode, output, error, TimeSpan.Zero, false) : null;
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("CLI probes must not send HTTP."));
        using var http = new HttpClient(handler);
        var keys = new MemoryKeys(null);
        var connector = new LlmConnector(id, catalog, http, keys, new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        Assert.IsType<ConnectorStatus.CliSignedOut>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "default", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.CliSignedOut, failure.Error.Kind);
        Assert.Equal(VoxClipErrorCode.CliNotSignedIn, failure.Error.Code);
        var runFailure = await Assert.ThrowsAsync<LlmException>(() => new LlmRunner(keys, catalog, new Redactor()).RunAsync(catalog.TestRequest(id), connector, "default", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.CliSignedOut, runFailure.Error.Kind);
        Assert.DoesNotContain(processes.Requests, command => command.Arguments.Contains("app-server"));
        Assert.Empty(processes.Generations);
        Assert.Empty(keys.Accounts);
        Assert.Empty(handler.Requests);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode, false)]
    [InlineData(ConnectorId.Codex, false)]
    [InlineData(ConnectorId.Codex, true)]
    public async Task AuthSignedOutSignalsComeFromTheCatalog(ConnectorId id, bool useText)
    {
        var catalog = Catalog();
        var auth = catalog.Provider(id)["cli"]!["detect"]!["auth"]!;
        auth["signedOutExitCode"] = 42;
        if (useText) auth["signedOutText"] = "catalog signed-out marker";
        using var processes = new FixtureProcessRunner(id, catalog, new());
        processes.Override = command => command.Arguments.Contains(id == ConnectorId.ClaudeCode ? "auth" : "login")
            ? new(useText ? 2 : 42, "", useText ? "catalog signed-out marker" : "", TimeSpan.Zero, false) : null;
        using var http = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException()));
        var connector = new LlmConnector(id, catalog, http, new MemoryKeys(null), new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        Assert.IsType<ConnectorStatus.CliSignedOut>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Empty(processes.Generations);
    }

    [Theory]
    [InlineData(0, "not JSON")]
    [InlineData(2, "not JSON")]
    [InlineData(0, "{}")]
    [InlineData(2, "{\"loggedIn\":true}")]
    [InlineData(0, "{\"loggedIn\":\"false\"}")]
    public async Task MalformedOrFailedClaudeAuthReturnsUnavailableInsteadOfThrowing(int exitCode, string output)
    {
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(ConnectorId.ClaudeCode, catalog, new());
        processes.Override = command => command.Arguments.Contains("auth") ? new(exitCode, output, "", TimeSpan.Zero, false) : null;
        using var http = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException()));
        var connector = new LlmConnector(ConnectorId.ClaudeCode, catalog, http, new MemoryKeys(null), new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Equal("Claude Code stopped with an error: The CLI could not be started or its output could not be read.", status.Reason);
        Assert.Empty(processes.Generations);
    }
}
