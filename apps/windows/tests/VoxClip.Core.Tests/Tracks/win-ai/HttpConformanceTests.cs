using System.Text.Json.Nodes;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Domain.Shared;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class HttpConformanceTests
{
    [Fact]
    public async Task AnthropicContextExhaustionDoesNotCorrectPartialJson()
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, "{\"stop_reason\":\"model_context_window_exceeded\",\"content\":[{\"type\":\"text\",\"text\":\"{\"}]}")));
        using var client = new HttpClient(handler);
        var keys = new MemoryKeys();
        var connector = new LlmConnector(ConnectorId.Anthropic, Catalog(), client, keys, new Redactor());
        var runner = new LlmRunner(keys, Catalog(), new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(Catalog().TestRequest(ConnectorId.Anthropic), connector, "claude-sonnet-5-5", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Truncated, failure.Error.Kind);
        Assert.Single(handler.Requests);
    }

    [Theory]
    [InlineData("not-loaded", 4096)]
    [InlineData("loading", 4096)]
    [InlineData("", 4096)]
    [InlineData("loaded", 131072)]
    public async Task LmStudioRequiresLoadedStateForWorkingContext(string state, int expected)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, new JsonObject { ["state"] = state, ["max_context_length"] = 131072 }.ToJsonString())));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.LmStudio, Catalog(), client, new MemoryKeys(), new Redactor());
        Assert.Equal(expected, await connector.GetContextTokensAsync("local", TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(8192, 8192)]
    [InlineData(0, 131072)]
    [InlineData(-1, 131072)]
    public async Task LmStudioPrefersOnlyPositiveLoadedContext(int loaded, int expected)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, new JsonObject { ["state"] = "loaded", ["loaded_context_length"] = loaded, ["max_context_length"] = 131072 }.ToJsonString())));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.LmStudio, Catalog(), client, new MemoryKeys(), new Redactor());
        Assert.Equal(expected, await connector.GetContextTokensAsync("local", TestContext.Current.CancellationToken));
    }
}
