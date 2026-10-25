using System.Reflection;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class RoundThreeRegressionTests
{
    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task DisabledCliNeverStartsDetectionRefreshOrGeneration(ConnectorId id)
    {
        var catalog = Catalog();
        catalog.Provider(id)["enabled"] = false;
        using var processes = new FixtureProcessRunner(id, catalog, new());
        using var http = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException()));
        var connector = new LlmConnector(id, catalog, http, new MemoryKeys(null), new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        var message = $"{catalog.Provider(id)["label"]!.GetValue<string>()} is not enabled.";
        var status = Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Equal(message, status.Reason);
        foreach (var refresh in new[] { true, false })
        {
            var modelFailure = await Assert.ThrowsAsync<LlmException>(() => connector.GetModelsAsync(refresh, TestContext.Current.CancellationToken));
            Assert.Equal(LlmErrorKind.Unavailable, modelFailure.Error.Kind);
            Assert.Equal(message + " Your edits are saved.", modelFailure.Message);
        }
        var sendFailure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "default", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Unavailable, sendFailure.Error.Kind);
        Assert.Equal(message + " Your edits are saved.", sendFailure.Message);
        Assert.Empty(processes.Requests);
        Assert.Null(connector.CliDetection);
    }

    [Theory]
    [InlineData(ConnectorId.Anthropic, "api.anthropic.com")]
    [InlineData(ConnectorId.OpenAI, "api.openai.com")]
    [InlineData(ConnectorId.Xai, "api.x.ai")]
    [InlineData(ConnectorId.Gemini, "generativelanguage.googleapis.com")]
    public async Task StoredKeysOnlyReachTheirPinnedHttpsHost(ConnectorId id, string pinned)
    {
        foreach (var address in new[] { "https://untrusted.example.test", $"http://{pinned}", $"https://{pinned}.example.test", $"https://user:password@{pinned}" }
            .Concat(new[] { "api.anthropic.com", "api.openai.com", "api.x.ai", "generativelanguage.googleapis.com" }.Where(host => host != pinned).Select(host => "https://" + host)))
        {
            var catalog = Catalog();
            catalog.Provider(id)["baseUrl"] = address;
            using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("A crafted catalog must not send HTTP."));
            using var client = new HttpClient(handler);
            var keys = new MemoryKeys();
            var connector = new LlmConnector(id, catalog, client, keys, new Redactor());
            Assert.Equal("VoxClip is missing its AI configuration. Reinstall VoxClip.", Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken)).Reason);
            await Assert.ThrowsAsync<LlmException>(() => connector.GetModelsAsync(true, TestContext.Current.CancellationToken));
            await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "chat", TestContext.Current.CancellationToken));
            var runner = new LlmRunner(keys, catalog, new Redactor());
            await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(catalog.TestRequest(id), connector, "chat", TestContext.Current.CancellationToken));
            Assert.Empty(handler.Requests);
            Assert.Empty(keys.Accounts);
        }
        using var acceptedHandler = new StubHttp((_, _, _) => Task.FromResult(Response(200, Completion(id))));
        using var acceptedClient = new HttpClient(acceptedHandler);
        var acceptedCatalog = Catalog();
        acceptedCatalog.Provider(id)["baseUrl"] = "https://" + pinned.ToUpperInvariant();
        var accepted = new LlmConnector(id, acceptedCatalog, acceptedClient, new MemoryKeys(), new Redactor());
        await accepted.SendAsync(acceptedCatalog.TestRequest(id), "chat", TestContext.Current.CancellationToken);
        var acceptedWire = Assert.Single(acceptedHandler.Requests);
        Assert.Equal(pinned, new Uri(acceptedWire.Url).Host);
        Assert.Contains("test-placeholder-value", acceptedWire.Headers[acceptedCatalog.Provider(id)["auth"]!["header"]!.GetValue<string>()], StringComparison.Ordinal);
    }

    [Fact]
    public async Task CraftedGeneratePathCannotBypassPinnedKeyHost()
    {
        var catalog = Catalog();
        catalog.Provider(ConnectorId.Anthropic)["generate"]!["path"] = "https://untrusted.example.test/messages";
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("No key may leave the pinned host."));
        using var client = new HttpClient(handler);
        var keys = new MemoryKeys();
        var connector = new LlmConnector(ConnectorId.Anthropic, catalog, client, keys, new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(ConnectorId.Anthropic), "chat", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Unavailable, failure.Error.Kind);
        Assert.Empty(handler.Requests);
        Assert.Empty(keys.Accounts);
    }

    [Fact]
    public async Task LmStudio503IsOverloadedAfterRetries()
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(503, "{}")));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.LmStudio, Catalog(), client, new MemoryKeys(), new Redactor(), (_, _) => Task.CompletedTask);
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Request(ConnectorId.LmStudio), "chat", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Overloaded, failure.Error.Kind);
        Assert.Equal(VoxClipErrorCode.RateLimited, failure.Error.Code);
        Assert.Equal(3, handler.Requests.Count);
    }

    [Theory]
    [InlineData(ConnectorId.Ollama, "Ollama")]
    [InlineData(ConnectorId.LmStudio, "LM Studio")]
    public async Task InvalidLocalAddressesAreSettingsProblems(ConnectorId id, string label)
    {
        foreach (var address in new[] { "127.0.0.1:1234", "localhost:1234", "http://", "ftp://localhost", "http://user:password@localhost", "http://localhost?query=1", "http://localhost#fragment" })
        {
            using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("Invalid settings must not send HTTP."));
            using var client = new HttpClient(handler);
            var catalog = Catalog();
            var reason = $"{label}'s server address in Settings isn't valid.";
            var connector = new LlmConnector(id, catalog, client, new MemoryKeys(), new Redactor(), baseUrl: address);
            var publicConnector = new LlmConnector(id, new MemoryKeys(), catalog, new Redactor(), baseUrl: address);
            Assert.Equal(reason, Assert.IsType<ConnectorStatus.Unavailable>(await publicConnector.GetStatusAsync(TestContext.Current.CancellationToken)).Reason);
            var actions = new Func<Task>[]
            {
                () => connector.GetModelsAsync(false, TestContext.Current.CancellationToken),
                () => connector.GetModelsAsync(true, TestContext.Current.CancellationToken),
                () => connector.GetContextTokensAsync("chat", TestContext.Current.CancellationToken),
                () => connector.SendAsync(Request(id), "chat", TestContext.Current.CancellationToken)
            };
            foreach (var action in actions)
            {
                var failure = await Assert.ThrowsAsync<LlmException>(action);
                Assert.Equal(LlmErrorKind.Unavailable, failure.Error.Kind);
                Assert.Equal(reason + " Your edits are saved.", failure.Error.UserMessage);
                Assert.Null(failure.Error.Status);
            }
            Assert.Empty(handler.Requests);
        }
    }

    [Theory]
    [InlineData(ConnectorId.Anthropic)]
    [InlineData(ConnectorId.OpenAI)]
    [InlineData(ConnectorId.Xai)]
    [InlineData(ConnectorId.Gemini)]
    public async Task CloudBaseUrlOverridesNeverReceiveStoredKeys(ConnectorId id)
    {
        foreach (var address in new[] { "https://untrusted.example.test", "http://untrusted.example.test", "not a URL" })
        {
            using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, Completion(id))));
            using var client = new HttpClient(handler);
            var catalog = Catalog();
            var connector = new LlmConnector(id, catalog, client, new MemoryKeys(), new Redactor(), baseUrl: address);
            await connector.SendAsync(Request(id), "chat", TestContext.Current.CancellationToken);
            var wire = Assert.Single(handler.Requests);
            Assert.Equal(new Uri(catalog.Provider(id)["baseUrl"]!.GetValue<string>()).Authority, new Uri(wire.Url).Authority);
            Assert.DoesNotContain("untrusted", wire.Url, StringComparison.Ordinal);
        }
    }

    [Theory]
    [InlineData(ConnectorId.Ollama, 401, "Ollama")]
    [InlineData(ConnectorId.Ollama, 403, "Ollama")]
    [InlineData(ConnectorId.LmStudio, 401, "LM Studio")]
    [InlineData(ConnectorId.LmStudio, 403, "LM Studio")]
    public async Task LocalAuthenticationRejectionIsNotAKeyProblem(ConnectorId id, int status, string label)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(status, "{}")));
        using var client = new HttpClient(handler);
        var catalog = Catalog();
        var keys = new MemoryKeys();
        var connector = new LlmConnector(id, catalog, client, keys, new Redactor());
        var reason = $"{label} rejected the request ({status}).";
        Assert.Equal(reason, Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken)).Reason);
        var runner = new LlmRunner(keys, catalog, new Redactor());
        var preflight = await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(Request(id), connector, "chat", TestContext.Current.CancellationToken));
        var send = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Request(id), "chat", TestContext.Current.CancellationToken));
        foreach (var exception in new[] { preflight, send })
        {
            Assert.Equal(LlmErrorKind.Unavailable, exception.Error.Kind);
            Assert.Equal(VoxClipErrorCode.ProviderError, exception.Error.Code);
            Assert.Equal(reason + " Your edits are saved.", exception.Error.UserMessage);
        }
        Assert.Empty(keys.Accounts);
    }

    [Fact]
    public void RuntimeVersionUsesAssemblyInformationalVersion()
    {
        var version = typeof(LlmCatalog).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>();
        Assert.NotNull(version);
        Assert.Equal(version.InformationalVersion.Split('+')[0], LlmRuntime.Version);
    }
}
