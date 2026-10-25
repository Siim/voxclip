using VoxClip.Core.Services.Models;
using Xunit;

namespace VoxClip.Core.Tests.Tracks;

public sealed class SpeechPlaceholderTests
{
    [Fact]
    public async Task BundledCatalogueLoadsWithoutNetworkOrNativeRuntime()
    {
        var models = await new ModelCatalog().GetModelsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(9, models.Count);
        Assert.All(models, model => Assert.Equal("MIT", model.License));
    }
}
