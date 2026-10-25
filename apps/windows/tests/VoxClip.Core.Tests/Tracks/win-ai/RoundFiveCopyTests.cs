using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class RoundFiveCopyTests
{
    [Theory]
    [InlineData(ConnectorId.Codex)]
    public async Task CliModelNotFoundAndPreflightUseTheCatalogLabel(ConnectorId id)
    {
        var catalog = Catalog();
        var label = catalog.Provider(id)["label"]!.GetValue<string>();
        using var processes = new FixtureProcessRunner(id, catalog, new());
        var marker = catalog.Provider(id)["cli"]!["modelErrorMarkers"]![0]!.GetValue<string>();
        processes.Override = command => command.Arguments.Contains("--output-schema") ?
            new(1, new JsonObject { ["type"] = "error", ["message"] = marker }.ToJsonString(), "", TimeSpan.Zero, false) : null;
        using var http = new HttpClient(new StubHttp((_, _, _) => throw new InvalidOperationException()));
        var keys = new MemoryKeys(null);
        var connector = new LlmConnector(id, catalog, http, keys, new Redactor(), processes: processes, binaryOverride: processes.BinaryPath);
        var runner = new LlmRunner(keys, catalog, new Redactor());
        Assert.Equal(label, await runner.PreflightAsync(connector, "missing-model", LlmFeature.Test, TestContext.Current.CancellationToken));
        var failure = await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(catalog.TestRequest(id), connector, "missing-model", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.ModelNotFound, failure.Error.Kind);
        Assert.Equal($"{label} doesn't offer the model \"missing-model\" to this account. Pick another model or refresh the list. Your edits are saved.", failure.Message);
    }
}
