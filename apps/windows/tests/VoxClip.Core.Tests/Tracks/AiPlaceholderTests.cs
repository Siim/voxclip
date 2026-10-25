using Xunit;
namespace VoxClip.Core.Tests.Tracks;

public sealed class AiPlaceholderTests
{
    [Fact]
    [Trait("Track", "win-ai")]
    public async Task CatalogAndApprovedConstructionPathsAreUsable()
    {
        var catalog = new VoxClip.Core.Services.LLM.LlmCatalog();
        var connector = new VoxClip.Core.Services.LLM.LlmConnector(VoxClip.Core.Services.LLM.ConnectorId.OpenAI,
            new VoxClip.Core.Services.LLM.EmptyKeys(), catalog, new VoxClip.Core.Domain.Shared.Redactor());
        Assert.IsType<VoxClip.Core.Services.LLM.ConnectorStatus.NeedsKey>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.NotEmpty(await catalog.GetModelsAsync(connector.Id, TestContext.Current.CancellationToken));
        Assert.NotNull(new VoxClip.Core.Services.LLM.ClipFinder(catalog, new VoxClip.Core.Services.LLM.EmptyKeys(), new VoxClip.Core.Domain.Shared.Redactor(), null));
    }
}
