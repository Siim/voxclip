using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
[Trait("Category", "LiveLlm")]
[Collection("WinAiDataIsolation")]
public sealed class LiveLlmTests(AiDataIsolation isolation)
{
    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task InstalledSubscriptionCliOneTinyRoundTrip(ConnectorId id)
    {
        if (Environment.GetEnvironmentVariable("VOXCLIP_LIVE_TESTS") != "1" || Environment.GetEnvironmentVariable("VOXCLIP_LIVE_CLI") != "1") Assert.Skip("Set VOXCLIP_LIVE_TESTS=1 and VOXCLIP_LIVE_CLI=1 to opt in to a CLI generation.");
        var catalog = Catalog();
        var connector = new LlmConnector(id, catalog, LlmRuntime.Http, new MemoryKeys(null), new Redactor(), cacheFile: isolation.CacheFile);
        var status = await connector.GetStatusAsync(TestContext.Current.CancellationToken);
        if (status is ConnectorStatus.CliMissing) Assert.Skip($"{id}: no standalone CLI at catalogued locations or on PATH. Bundled application binaries are not probed.");
        if (status is ConnectorStatus.CliTooOld old) Assert.Skip($"{id} {old.Version}: missing required flags {string.Join(", ", old.Missing)}; no generation attempted.");
        if (status is ConnectorStatus.CliSignedOut) Assert.Skip($"{id}: sign in through the CLI before running this opt-in test; VoxClip never reads credentials.");
        Assert.IsType<ConnectorStatus.Ready>(status);
        var request = catalog.TestRequest(id);
        var model = catalog.Provider(id)["defaultModel"]!.GetValue<string>();
        var raw = await connector.SendAsync(request, model, TestContext.Current.CancellationToken);
        Assert.IsType<StopKind.Complete>(raw.Stop);
        var validated = LlmOutput.Validate(raw, request.Schema);
        Assert.NotNull(validated.Object);
        Assert.True(validated.Object["ok"]!.GetValue<bool>());
        Assert.Equal("voxclip", validated.Object["echo"]!.GetValue<string>());
    }

    [Fact]
    public async Task ExistingSmallOllamaModelOneTinyRoundTrip()
    {
        if (Environment.GetEnvironmentVariable("VOXCLIP_LIVE_TESTS") != "1" || Environment.GetEnvironmentVariable("VOXCLIP_LIVE_OLLAMA") != "1") Assert.Skip("Set VOXCLIP_LIVE_TESTS=1 and VOXCLIP_LIVE_OLLAMA=1 to opt in to local generation; this test never pulls models.");
        var catalog = Catalog();
        var connector = new LlmConnector(ConnectorId.Ollama, catalog, LlmRuntime.Http, new MemoryKeys(null), new Redactor(), cacheFile: isolation.CacheFile);
        Assert.IsType<ConnectorStatus.Ready>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        var installed = await connector.GetModelsAsync(false, TestContext.Current.CancellationToken);
        if (!installed.Any(model => model.Id == "qwen3:0.6b")) Assert.Skip("qwen3:0.6b is not installed; no pull or download performed.");
        var request = catalog.TestRequest(ConnectorId.Ollama) with { MaxOutputTokens = 64 };
        var raw = await connector.SendAsync(request, "qwen3:0.6b", TestContext.Current.CancellationToken);
        Assert.IsType<StopKind.Complete>(raw.Stop);
        var validated = LlmOutput.Validate(raw, request.Schema);
        Assert.NotNull(validated.Object);
        Assert.True(validated.Object["ok"]!.GetValue<bool>());
        Assert.Equal("voxclip", validated.Object["echo"]!.GetValue<string>());
    }

    [Fact(Skip = "API-key live tests are not authorized for this track; no keys are read or provider calls made.")]
    public void ApiKeyLiveTestsRemainDisabled() { }
}
