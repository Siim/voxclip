using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class RoundFourSecurityTests
{
    private const string ConfigurationError = "VoxClip is missing its AI configuration. Reinstall VoxClip.";

    [Theory]
    [InlineData(ConnectorId.Anthropic)]
    [InlineData(ConnectorId.OpenAI)]
    [InlineData(ConnectorId.Xai)]
    [InlineData(ConnectorId.Gemini)]
    public async Task CraftedCloudAuthNeverReadsOrSendsAKey(ConnectorId id)
    {
        foreach (var change in new[] { "account", "User-Agent", "Host", "Proxy-Authorization", "template", "removed", "none", "malformed" })
        {
            var catalog = Catalog();
            var provider = catalog.Provider(id);
            switch (change)
            {
                case "account": provider["auth"]!["keyAccount"] = id == ConnectorId.Anthropic ? "llm-api-key-openai" : "llm-api-key-anthropic"; break;
                case "template": provider["auth"]!["valueTemplate"] = "unsafe {key}"; break;
                case "removed": provider.Remove("auth"); provider["baseUrl"] = "http://untrusted.example.test"; break;
                case "none": provider["auth"] = new JsonObject { ["type"] = "none" }; break;
                case "malformed": provider["auth"] = "invalid"; break;
                default: provider["auth"]!["header"] = change; break;
            }
            await AssertConfigurationRejectedAsync(id, catalog);
        }
    }

    [Theory]
    [InlineData(ConnectorId.Ollama)]
    [InlineData(ConnectorId.LmStudio)]
    [InlineData(ConnectorId.AppleFoundation)]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task KeylessConnectorsRejectAddedAuth(ConnectorId id)
    {
        var catalog = Catalog();
        catalog.Provider(id)["auth"] = catalog.Provider(ConnectorId.Anthropic)["auth"]!.DeepClone();
        await AssertConfigurationRejectedAsync(id, catalog);
    }

    [Theory]
    [InlineData(ConnectorId.Anthropic, "llm-api-key-anthropic", "api.anthropic.com", "x-api-key", "test-placeholder-value")]
    [InlineData(ConnectorId.OpenAI, "llm-api-key-openai", "api.openai.com", "Authorization", "Bearer test-placeholder-value")]
    [InlineData(ConnectorId.Xai, "llm-api-key-xai", "api.x.ai", "Authorization", "Bearer test-placeholder-value")]
    [InlineData(ConnectorId.Gemini, "llm-api-key-gemini", "generativelanguage.googleapis.com", "x-goog-api-key", "test-placeholder-value")]
    public async Task CloudAuthUsesTheCodePinnedAccountHostAndHeader(ConnectorId id, string account, string host, string header, string value)
    {
        var catalog = Catalog();
        var keys = new MemoryKeys();
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, Completion(id))));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(id, catalog, http, keys, new Redactor());
        await connector.SendAsync(catalog.TestRequest(id), "chat", TestContext.Current.CancellationToken);
        Assert.Equal(account, Assert.Single(keys.Accounts));
        var request = Assert.Single(handler.Requests);
        Assert.Equal(host, new Uri(request.Url).Host);
        Assert.Equal(value, request.Headers[header]);
    }

    private static async Task AssertConfigurationRejectedAsync(ConnectorId id, LlmCatalog catalog)
    {
        var keys = new MemoryKeys();
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("Invalid AI configuration must not send HTTP."));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(id, catalog, http, keys, new Redactor());
        Assert.Equal(ConfigurationError, Assert.IsType<ConnectorStatus.Unavailable>(await connector.GetStatusAsync(TestContext.Current.CancellationToken)).Reason);
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(id), "chat", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Unavailable, failure.Error.Kind);
        Assert.Equal(ConfigurationError + " Your edits are saved.", failure.Error.UserMessage);
        await Assert.ThrowsAsync<LlmException>(() => connector.GetModelsAsync(true, TestContext.Current.CancellationToken));
        Assert.Empty(keys.Accounts);
        Assert.Empty(handler.Requests);
    }
}
