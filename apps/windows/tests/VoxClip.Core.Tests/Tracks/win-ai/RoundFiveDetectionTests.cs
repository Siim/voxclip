using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class RoundFiveDetectionTests
{
    [Theory]
    [InlineData(ConnectorId.ClaudeCode, false)]
    [InlineData(ConnectorId.ClaudeCode, true)]
    [InlineData(ConnectorId.Codex, false)]
    [InlineData(ConnectorId.Codex, true)]
    public async Task HelpFlagsOnStderrOrBothStreamsAreSupported(ConnectorId id, bool splitStreams)
    {
        var catalog = Catalog();
        var required = catalog.Provider(id)["cli"]!["detect"]!["help"]!["requiredFlags"]!.AsArray().Select(flag => flag!.GetValue<string>()).ToArray();
        var split = splitStreams ? required.Length / 2 : 0;
        using var processes = new FixtureProcessRunner(id, catalog, new());
        processes.Override = command => command.Arguments.Contains("--help")
            ? new(0, string.Join('\n', required.Take(split)), string.Join('\n', required.Skip(split)), TimeSpan.Zero, false) : null;
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("CLI probes must not send HTTP."));
        using var http = new HttpClient(handler);
        var keys = new MemoryKeys(null);
        var connector = new LlmConnector(id, catalog, http, keys, new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        Assert.IsType<ConnectorStatus.Ready>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Single(processes.Requests, command => command.Arguments.Contains("--help"));
        Assert.DoesNotContain(processes.Requests, command => command.Arguments.Contains("app-server"));
        Assert.Empty(processes.Generations);
        Assert.Empty(keys.Accounts);
        Assert.Empty(handler.Requests);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode, "old-help")]
    [InlineData(ConnectorId.Codex, "old-help")]
    [InlineData(ConnectorId.ClaudeCode, "help-exit")]
    [InlineData(ConnectorId.Codex, "help-exit")]
    [InlineData(ConnectorId.ClaudeCode, "old-help-exit")]
    [InlineData(ConnectorId.Codex, "old-help-exit")]
    [InlineData(ConnectorId.ClaudeCode, "version-exit")]
    [InlineData(ConnectorId.Codex, "version-exit")]
    [InlineData(ConnectorId.ClaudeCode, "version-unparseable")]
    [InlineData(ConnectorId.Codex, "version-unparseable")]
    [InlineData(ConnectorId.Codex, "features-exit")]
    public async Task UnsupportedCliProbesReportTooOldBeforeAuthOrGeneration(ConnectorId id, string scenario)
    {
        var catalog = Catalog();
        var required = catalog.Provider(id)["cli"]!["detect"]!["help"]!["requiredFlags"]!.AsArray().Select(flag => flag!.GetValue<string>()).ToArray();
        var missing = required.Where(flag => id == ConnectorId.Codex ? flag is "--ephemeral" or "--ignore-user-config" : flag == "--json-schema").ToArray();
        Assert.NotEmpty(missing);
        using var processes = new FixtureProcessRunner(id, catalog, new());
        processes.Override = command =>
        {
            if (command.Arguments.Contains("--version"))
                return new(scenario == "version-exit" ? 2 : 0, scenario == "version-unparseable" ? "not a version" : id == ConnectorId.Codex ? "codex-cli 0.44.0" : "0.44.0", "", TimeSpan.Zero, false);
            if (command.Arguments.Contains("--help"))
                return new(scenario.EndsWith("help-exit", StringComparison.Ordinal) ? 2 : 0, string.Join('\n', scenario.StartsWith("old-help", StringComparison.Ordinal) ? required.Except(missing) : required), "", TimeSpan.Zero, false);
            if (command.Arguments.Contains("features")) return new(2, "", "unsupported subcommand", TimeSpan.Zero, false);
            return null;
        };
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("CLI probes must not send HTTP."));
        using var http = new HttpClient(handler);
        var keys = new MemoryKeys(null);
        var connector = new LlmConnector(id, catalog, http, keys, new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        var status = Assert.IsType<ConnectorStatus.CliTooOld>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        var version = scenario.StartsWith("version-", StringComparison.Ordinal) ? "unknown" : "0.44.0";
        var expectedMissing = scenario.StartsWith("old-help", StringComparison.Ordinal) ? missing : scenario == "help-exit" ? ["help"] : scenario == "features-exit" ? ["features list"] : new[] { "version" };
        Assert.Equal(version, status.Version);
        Assert.Equal(expectedMissing, status.Missing);
        var label = id == ConnectorId.ClaudeCode ? "Claude Code" : "Codex";
        var expectedMessage = version == "unknown"
            ? $"Your {label} is too old for VoxClip. Update it, then try again. Your edits are saved."
            : $"Your {label} {version} is too old for VoxClip. Update it, then try again. Your edits are saved.";
        var sendFailure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "default", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.CliTooOld, sendFailure.Error.Kind);
        Assert.Equal(VoxClipErrorCode.CliNotInstalled, sendFailure.Error.Code);
        Assert.Equal(expectedMessage, sendFailure.Message);
        var runFailure = await Assert.ThrowsAsync<LlmException>(() => new LlmRunner(keys, catalog, new Redactor()).RunAsync(catalog.TestRequest(id), connector, "default", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.CliTooOld, runFailure.Error.Kind);
        Assert.Equal(expectedMessage, runFailure.Message);
        if (id == ConnectorId.Codex)
        {
            Assert.Equal(catalog.Models(id), await connector.GetModelsAsync(true, TestContext.Current.CancellationToken));
            Assert.Equal("Couldn't refresh: " + expectedMessage, connector.RefreshWarning);
        }
        Assert.DoesNotContain(processes.Requests, command => command.Arguments.Contains("auth") || command.Arguments.Contains("login"));
        Assert.DoesNotContain(processes.Requests, command => command.Arguments.Contains("app-server"));
        Assert.Equal(scenario == "features-exit" ? 4 : 0, processes.Requests.Count(command => command.Arguments.Contains("features")));
        Assert.Empty(processes.Generations);
        Assert.Empty(keys.Accounts);
        Assert.Empty(handler.Requests);
    }

    [Theory]
    [InlineData("io", false)]
    [InlineData("io", true)]
    [InlineData("win32", false)]
    [InlineData("unexpected", false)]
    [InlineData("unexpected", true)]
    [InlineData("timeout", false)]
    [InlineData("cancel", false)]
    [InlineData("truncated", false)]
    [InlineData("old-help", true)]
    public async Task FailedCodexRefreshPreservesCachedOrCuratedModels(string failure, bool cached)
    {
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(ConnectorId.Codex, catalog, new() { ["model"] = "cached-test-model" });
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("CLI probes must not send HTTP."));
        using var http = new HttpClient(handler);
        var keys = new MemoryKeys(null);
        var connector = new LlmConnector(ConnectorId.Codex, catalog, http, keys, new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        var expectedModels = cached ? await connector.GetModelsAsync(true, TestContext.Current.CancellationToken) : catalog.Models(ConnectorId.Codex);
        var fetchedAt = connector.ModelsFetchedAt;
        if (cached)
        {
            Assert.Contains(expectedModels, model => model.Id == "cached-test-model");
            File.SetLastWriteTimeUtc(processes.BinaryPath, File.GetLastWriteTimeUtc(processes.BinaryPath).AddSeconds(2));
            processes.Requests.Clear();
        }
        processes.Override = command =>
        {
            if (failure == "old-help") return command.Arguments.Contains("--help") ? new(0, "unsupported help", "", TimeSpan.Zero, false) : null;
            if (!command.Arguments.Contains("--version")) return null;
            return failure switch
            {
                "io" => throw new IOException("test-only-probe-detail"),
                "win32" => throw new System.ComponentModel.Win32Exception("test-only-probe-detail"),
                "unexpected" => throw new InvalidOperationException("test-only-probe-detail"),
                "timeout" => throw new TimeoutException("test-only-probe-detail"),
                "cancel" => throw new OperationCanceledException(),
                _ => new(0, "test-only-probe-detail", "", TimeSpan.Zero, true)
            };
        };
        Assert.Equal(expectedModels, await connector.GetModelsAsync(true, TestContext.Current.CancellationToken));
        Assert.Equal(fetchedAt, connector.ModelsFetchedAt);
        Assert.Equal(failure == "old-help"
            ? "Couldn't refresh: Your Codex 0.120.0 is too old for VoxClip. Update it, then try again. Your edits are saved."
            : "Couldn't refresh: Codex stopped with an error: The CLI could not be started or its output could not be read. Your edits are saved.", connector.RefreshWarning);
        Assert.DoesNotContain(processes.Requests, command => command.Arguments.Contains("app-server") || command.Arguments.Contains("auth") || command.Arguments.Contains("login"));
        Assert.Empty(processes.Generations);
        Assert.Empty(keys.Accounts);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task MissingCodexRefreshAndSendIncludeTheInstallHint()
    {
        var catalog = Catalog();
        var platform = OperatingSystem.IsWindows() ? "windows" : "macos";
        var settings = catalog.Provider(ConnectorId.Codex)["cli"]!;
        settings["searchPaths"]![platform] = new JsonArray();
        using var processes = new FixtureProcessRunner(ConnectorId.Codex, catalog, new());
        var lookup = settings["shellLookup"]![platform]![0]!.GetValue<string>();
        processes.Override = request => Path.GetFileName(request.Executable).Equals(Path.GetFileName(lookup), StringComparison.OrdinalIgnoreCase) &&
            request.Arguments.SequenceEqual(settings["shellLookup"]![platform]!.AsArray().Skip(1).Select(item => item!.GetValue<string>()))
            ? new(0, "", "", TimeSpan.Zero, false) : null;
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("CLI probes must not send HTTP."));
        using var http = new HttpClient(handler);
        var keys = new MemoryKeys(null);
        var missing = Path.Combine(Path.GetTempPath(), "voxclip-missing-cli-" + Guid.NewGuid().ToString("N"), "codex");
        var connector = new LlmConnector(ConnectorId.Codex, catalog, http, keys, new Redactor(), processes: processes, binaryOverride: missing);
        var hint = catalog.Provider(ConnectorId.Codex)["cli"]!["installHint"]!.GetValue<string>();
        var expected = $"Codex isn't installed. {hint} Your edits are saved.";
        Assert.Equal(catalog.Models(ConnectorId.Codex), await connector.GetModelsAsync(true, TestContext.Current.CancellationToken));
        Assert.Equal("Couldn't refresh: " + expected, connector.RefreshWarning);
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(ConnectorId.Codex), "default", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.CliMissing, failure.Error.Kind);
        Assert.Equal(expected, failure.Message);
        Assert.DoesNotContain(processes.Requests, request => request.Arguments.Contains("--version") || request.Arguments.Contains("app-server"));
        Assert.Empty(processes.Generations);
        Assert.Empty(keys.Accounts);
        Assert.Empty(handler.Requests);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode, "--version")]
    [InlineData(ConnectorId.ClaudeCode, "--help")]
    [InlineData(ConnectorId.Codex, "--version")]
    [InlineData(ConnectorId.Codex, "--help")]
    [InlineData(ConnectorId.Codex, "features")]
    public async Task TruncatedDetectionOutputRemainsAGenericProbeFailure(ConnectorId id, string probe)
    {
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(id, catalog, new());
        processes.Override = command => command.Arguments.Contains(probe) ? new(0, "", "", TimeSpan.Zero, true) : null;
        using var http = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException()));
        var connector = new LlmConnector(id, catalog, http, new MemoryKeys(null), new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        var label = id == ConnectorId.ClaudeCode ? "Claude Code" : "Codex";
        Assert.Equal($"{label} stopped with an error: The CLI could not be started or its output could not be read.", status.Reason);
        Assert.DoesNotContain(processes.Requests, command => command.Arguments.Contains("auth") || command.Arguments.Contains("login"));
        Assert.Empty(processes.Generations);
    }
}
