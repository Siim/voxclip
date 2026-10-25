using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
[Collection("WinAiDataIsolation")]
public sealed class PublicContractTests
{
    [Theory]
    [InlineData("CliDetection")]
    [InlineData("RefreshWarning")]
    [InlineData("ModelsFetchedAt")]
    [InlineData("SelectedModel")]
    public void ConnectorUiStateHasPublicGettersOnly(string name)
    {
        var property = typeof(LlmConnector).GetProperty(name);
        Assert.NotNull(property);
        Assert.True(property.GetMethod!.IsPublic);
        Assert.False(property.SetMethod?.IsPublic ?? false);
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task CliDetectionExposesPathVersionAndApiKeyAuth(ConnectorId id)
    {
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(id, catalog, new());
        processes.Override = request => request.Arguments.Contains("auth") ? new(0, "{\"loggedIn\":true,\"authMethod\":\"api_key\"}", "", TimeSpan.Zero, false) :
            request.Arguments.Contains("login") ? new(0, "Logged in using an API key", "", TimeSpan.Zero, false) : null;
        using var http = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException()));
        var connector = new LlmConnector(id, catalog, http, new MemoryKeys(null), new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        Assert.Null(connector.CliDetection);
        Assert.IsType<ConnectorStatus.Ready>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        var detection = connector.CliDetection!;
        Assert.Equal(processes.BinaryPath, detection.Path);
        Assert.NotEqual("unknown", detection.Version);
        Assert.True(detection.UsesApiKey);
        Assert.NotNull(detection.AuthMethod);
        if (id == ConnectorId.Codex)
        {
            await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
            Assert.NotNull(connector.ModelsFetchedAt);
        }
    }

    [Fact]
    public async Task RefreshStateRetainsSelectedModelAndLastSuccessfulTimestamp()
    {
        var catalog = Catalog();
        var failed = false;
        using var handler = new StubHttp((_, _, _) => Task.FromResult(failed ? Response(500, "{}") : Response(200, "{\"data\":[]}")));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, catalog, http, new MemoryKeys(), new Redactor(), (_, _) => Task.CompletedTask);
        connector.SelectModel("selected-model");
        var models = await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
        Assert.Contains(models, model => model.Id == "selected-model" && model.Name.EndsWith(" (not listed for this key)", StringComparison.Ordinal));
        Assert.Null(connector.RefreshWarning);
        Assert.NotNull(connector.ModelsFetchedAt);
        var fetched = connector.ModelsFetchedAt;
        failed = true;
        await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
        Assert.StartsWith("Couldn't refresh: ", connector.RefreshWarning!, StringComparison.Ordinal);
        Assert.Equal(fetched, connector.ModelsFetchedAt);
        Assert.Equal("selected-model", connector.SelectedModel);
        connector.SelectModel(null);
        Assert.Null(connector.SelectedModel);
    }

    [Theory]
    [InlineData(true, " \ufeffVoXcLiP\n", true)]
    [InlineData(false, "voxclip", false)]
    [InlineData(true, "different", false)]
    public async Task ConnectionTestUsesTheCatalogRequestAndPassRule(bool ok, string echo, bool passed)
    {
        var catalog = Catalog();
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, model, _) => Task.FromResult(new RawCompletion(null,
            new JsonObject { ["ok"] = ok, ["echo"] = echo }, model, new StopKind.Complete(), null, null)));
        var result = await new LlmRunner(new MemoryKeys(), catalog, new Redactor()).TestAsync(connector, "chat", TestContext.Current.CancellationToken);
        Assert.Equal(passed, result.Passed);
        Assert.Equal("chat", result.Model);
        Assert.False(result.UsedFallback);
        Assert.True(result.Seconds >= 0);
        var request = Assert.Single(connector.Requests);
        Assert.Equal(catalog.TestRequest(ConnectorId.OpenAI).System, request.System);
        Assert.Equal(LlmFeature.Test, request.Feature);
        Assert.Null(request.CachedBlock);
        Assert.Equal(TimeSpan.FromSeconds(30), request.Timeout);
        Assert.Equal(TimeSpan.FromSeconds(120), catalog.TestRequest(ConnectorId.Codex).Timeout);
    }

    [Fact]
    public async Task PublicDryRunRequestsAreAvailableWithoutProviderCalls()
    {
        var catalog = LlmCatalog.Load(FixtureLoader.SharedRoot);
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => throw new InvalidOperationException());
        var finder = new ClipFinder(new LlmRunner(new MemoryKeys(), catalog, new Redactor()), _ => connector, FixtureLoader.SharedRoot);
        var request = new ClipFinderRequest(Words(9000), new Dictionary<string, string>(), new HashSet<string>(), ClipPreset.Best, null, "en", ConnectorId.OpenAI, "chat", DryRun: true);
        await finder.FindClipsAsync(request, null, TestContext.Current.CancellationToken);
        Assert.Equal(2, finder.DryRunRequests.Count);
        Assert.All(finder.DryRunRequests, prepared => Assert.NotNull(prepared.CachedBlock));
        Assert.Empty(connector.Requests);
        Assert.Equal(0, connector.StatusCalls);
        Assert.Equal(0, connector.ContextCalls);
        Assert.True(typeof(ClipFinder).GetProperty(nameof(ClipFinder.DryRunRequests))!.GetMethod!.IsPublic);
    }

    [Fact]
    public void LoadFailsEagerlyWhenTheCatalogIsMissing()
    {
        var failure = Assert.Throws<VoxClipException>(() => LlmCatalog.Load(Path.Combine(FixtureLoader.SharedRoot, Guid.NewGuid().ToString("N"))));
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, failure.Code);
    }

    [Fact]
    public async Task W7InjectsKeylessHttpAndReturnsPresetsInPromptOrder()
    {
        var catalog = LlmCatalog.Load(FixtureLoader.SharedRoot);
        using var processes = new FixtureProcessRunner(ConnectorId.Codex, catalog, new());
        using var handler = new StubHttp((request, _, _) => Task.FromResult(Response(200,
            request.Method == HttpMethod.Get ? "{\"data\":[{\"id\":\"chat\"}]}" : Completion(ConnectorId.LmStudio))));
        using var http = new HttpClient(handler);
        var keys = new MemoryKeys();
        var connector = new LlmConnector(ConnectorId.LmStudio, keys, processes, catalog, http);
        var runner = new LlmRunner(keys, catalog, new Redactor());
        var finder = new ClipFinder(runner, _ => connector, FixtureLoader.SharedRoot);
        IClipFinder contract = finder;
        var presets = await contract.GetPresetsAsync(TestContext.Current.CancellationToken);
        var expected = catalog.ReadAsset("prompts/clip-finder.json")["presets"]!.AsArray().Select(item => Enum.Parse<ClipPreset>(item!["id"]!.GetValue<string>(), true));
        Assert.Equal(expected, presets);
        await connector.SendAsync(catalog.TestRequest(ConnectorId.LmStudio), "chat", TestContext.Current.CancellationToken);
        Assert.Contains(handler.Requests, request => request.Url.EndsWith("/chat/completions", StringComparison.Ordinal));
        Assert.Empty(keys.Accounts);
        Assert.Empty(processes.Requests);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAsync<OperationCanceledException>(() => contract.GetPresetsAsync(cancelled.Token));
    }

    [Theory]
    [InlineData(ConnectorId.ClaudeCode)]
    [InlineData(ConnectorId.Codex)]
    public async Task W7UsesTheInjectedProcessRunner(ConnectorId id)
    {
        var catalog = LlmCatalog.Load(FixtureLoader.SharedRoot);
        using var processes = new FixtureProcessRunner(id, catalog, new());
        catalog.Provider(id)["cli"]!["searchPaths"]![OperatingSystem.IsWindows() ? "windows" : "macos"] = new JsonArray(processes.BinaryPath);
        using var handler = new StubHttp((_, _, _) => throw new InvalidOperationException("CLI detection must not send HTTP."));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(id, new MemoryKeys(null), processes, catalog, http);
        Assert.IsType<ConnectorStatus.Ready>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.NotEmpty(processes.Requests);
        Assert.Empty(handler.Requests);
    }
}
