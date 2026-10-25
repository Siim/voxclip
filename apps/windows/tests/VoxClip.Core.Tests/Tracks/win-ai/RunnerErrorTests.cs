using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class RunnerErrorTests
{
    [Theory]
    [InlineData(ConnectorId.OpenAI, LlmErrorKind.MissingKey)]
    [InlineData(ConnectorId.Codex, LlmErrorKind.CliSignedOut)]
    public async Task PreflightErrorsReportExactlyOneTerminalError(ConnectorId id, LlmErrorKind expected)
    {
        var connector = new ScriptedConnector(id, (_, _, _) => throw new InvalidOperationException())
        { Status = id == ConnectorId.OpenAI ? new ConnectorStatus.NeedsKey() : new ConnectorStatus.CliSignedOut() };
        var errors = new List<(LlmErrorKind Kind, string Message)>();
        var runner = new LlmRunner(new MemoryKeys(null), Catalog(), new Redactor(), (kind, message) => errors.Add((kind, message)));
        await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(Catalog().TestRequest(id), connector, "default", TestContext.Current.CancellationToken));
        Assert.Equal(expected, Assert.Single(errors).Kind);
        Assert.Empty(connector.Requests);
    }

    [Fact]
    public async Task ClipFinderPreflightUsesTheInjectedErrorCallback()
    {
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => throw new InvalidOperationException()) { Status = new ConnectorStatus.NeedsKey() };
        var errors = new List<LlmErrorKind>();
        var runner = new LlmRunner(new MemoryKeys(null), Catalog(), new Redactor(), (kind, _) => errors.Add(kind));
        var finder = new ClipFinder(runner, _ => connector, FixtureLoader.SharedRoot);
        var input = new ClipFinderRequest(Words(20), new Dictionary<string, string>(), new HashSet<string>(), ClipPreset.Best, null, "en", ConnectorId.OpenAI, "chat");
        await Assert.ThrowsAsync<LlmException>(() => finder.FindClipsAsync(input, null, TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.MissingKey, Assert.Single(errors));
    }

    [Theory]
    [InlineData(LlmErrorKind.InvalidOutput)]
    [InlineData(LlmErrorKind.Truncated)]
    [InlineData(LlmErrorKind.Refused)]
    public async Task ValidationFailuresAreReportedOnce(LlmErrorKind expected)
    {
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, model, _) => Task.FromResult(new RawCompletion("not JSON", null, model,
            expected == LlmErrorKind.Truncated ? new StopKind.Truncated() : expected == LlmErrorKind.Refused ? new StopKind.Refused(null) : new StopKind.Complete(), null, null)));
        var errors = new List<LlmErrorKind>();
        var runner = new LlmRunner(new MemoryKeys(), Catalog(), new Redactor(), (kind, _) => errors.Add(kind));
        var failure = await Assert.ThrowsAsync<LlmException>(() => runner.TestAsync(connector, "chat", TestContext.Current.CancellationToken));
        Assert.Equal(expected, failure.Error.Kind);
        Assert.Equal(expected, Assert.Single(errors));
    }

    [Fact]
    public async Task ErrorMessagesAreRedactedAndBounded()
    {
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => throw new InvalidOperationException())
        { Status = new ConnectorStatus.Unavailable("test-only-value " + new string('x', 300)) };
        string? observed = null;
        var runner = new LlmRunner(new MemoryKeys(), Catalog(), new Redactor(["test-only-value"]), (_, message) => observed = message);
        await Assert.ThrowsAsync<LlmException>(() => runner.TestAsync(connector, "chat", TestContext.Current.CancellationToken));
        Assert.NotNull(observed);
        Assert.DoesNotContain("test-only-value", observed, StringComparison.Ordinal);
        Assert.Contains("[REDACTED]", observed, StringComparison.Ordinal);
        Assert.True(observed.Length <= 200);
    }

    [Fact]
    public async Task LoggingCallbackFailuresDoNotMaskTheProviderError()
    {
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => throw new InvalidOperationException()) { Status = new ConnectorStatus.NeedsKey() };
        var runner = new LlmRunner(new MemoryKeys(null), Catalog(), new Redactor(), (_, _) => throw new IOException("test sink failure"));
        var failure = await Assert.ThrowsAsync<LlmException>(() => runner.TestAsync(connector, "chat", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.MissingKey, failure.Error.Kind);
    }

    [Fact]
    public async Task InjectedDiagnosticsAreRedactedAndCannotFailASuccessfulRequest()
    {
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(ConnectorId.Codex, catalog, new());
        using var handler = new StubHttp((_, _, _) =>
        {
            var response = Response(200, Completion(ConnectorId.OpenAI));
            response.Headers.Add(catalog.Provider(ConnectorId.OpenAI)["requestIdHeader"]!.GetValue<string>(), "test-placeholder-value");
            return Task.FromResult(response);
        });
        using var http = new HttpClient(handler);
        string? observed = null;
        var connector = new LlmConnector(ConnectorId.OpenAI, catalog, http, new MemoryKeys(), new Redactor(), processes: processes,
            onDiagnostic: message => { observed = message; throw new IOException("test sink failure"); });
        await connector.SendAsync(catalog.TestRequest(ConnectorId.OpenAI), "chat", TestContext.Current.CancellationToken);
        Assert.NotNull(observed);
        Assert.DoesNotContain("test-placeholder-value", observed, StringComparison.Ordinal);
        Assert.Contains("requestId=[REDACTED]", observed, StringComparison.Ordinal);
    }
}
