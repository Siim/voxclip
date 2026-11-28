using System.Text.Json.Nodes;
using VoxClip.Core.Services.LLM;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class ScriptedConnectorTests
{
    [Fact]
    public async Task ReturnsRepliesInOrderAndFailsWhenTheScriptRunsOut()
    {
        var connector = new ScriptedConnector(new JsonNode?[] { JsonValue.Create("first"), JsonValue.Create("second") });
        var request = new LlmRequest(LlmFeature.Test, "", null, "Test the script", "test", new(), 1,
            null, TimeSpan.FromSeconds(1), null, "scripted-test");

        Assert.Equal("first", (await connector.SendAsync(request, "fixture", TestContext.Current.CancellationToken)).Object?.GetValue<string>());
        Assert.Equal("second", (await connector.SendAsync(request, "fixture", TestContext.Current.CancellationToken)).Object?.GetValue<string>());
        await Assert.ThrowsAsync<ScriptedConnector.Exhausted>(() => connector.SendAsync(request, "fixture", TestContext.Current.CancellationToken));
        Assert.Equal(new[] { request, request, request }, connector.Requests);
    }
}
