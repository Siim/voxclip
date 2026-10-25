using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[CollectionDefinition("WinAiDataIsolation", DisableParallelization = true)]
public sealed class AiDataIsolationCollection : ICollectionFixture<AiDataIsolation>;

public sealed class AiDataIsolation : IDisposable
{
    private readonly DirectoryInfo directory = Directory.CreateTempSubdirectory("voxclip-win-ai-data-");
    private readonly string? previousDataDirectory = Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR");
    private readonly string realCacheFile;
    private readonly DateTime? realCacheWriteTime;
    internal string Root => directory.FullName;
    internal string CacheFile => Path.Combine(Root, "Cache", "llm-models.json");

    public AiDataIsolation()
    {
        var root = OperatingSystem.IsWindows()
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoxConvo", "VoxClip")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support", "VoxClip");
        realCacheFile = Path.Combine(root, "Cache", "llm-models.json");
        realCacheWriteTime = ReadRealCacheWriteTime();
        Environment.SetEnvironmentVariable("VOXCLIP_DATA_DIR", Root);
    }

    internal void AssertRealCacheUnchanged() => Assert.Equal(realCacheWriteTime, ReadRealCacheWriteTime());
    private DateTime? ReadRealCacheWriteTime() => File.Exists(realCacheFile) ? File.GetLastWriteTimeUtc(realCacheFile) : null;

    public void Dispose()
    {
        try { AssertRealCacheUnchanged(); }
        finally
        {
            Environment.SetEnvironmentVariable("VOXCLIP_DATA_DIR", previousDataDirectory);
            directory.Delete(true);
        }
    }
}

[Trait("Track", "win-ai")]
[Collection("WinAiDataIsolation")]
public sealed class RoundFiveDataIsolationTests(AiDataIsolation isolation)
{
    [Fact]
    public async Task PublicStatusAndModelRefreshWriteOnlyTheIsolatedCache()
    {
        Assert.Equal(isolation.Root, Environment.GetEnvironmentVariable("VOXCLIP_DATA_DIR"));
        Assert.Equal(isolation.CacheFile, Path.Combine(DataLocations.Resolve().Cache, "llm-models.json"));
        var catalog = Catalog();
        using var processes = new FixtureProcessRunner(ConnectorId.Codex, catalog, new());
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, "{\"data\":[{\"id\":\"isolated-test-model\"}]}")));
        using var http = new HttpClient(handler);
        var keys = new MemoryKeys(null);
        var connector = new LlmConnector(ConnectorId.LmStudio, keys, processes, catalog, http);
        Assert.IsType<ConnectorStatus.Ready>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
        Assert.Single(await connector.GetModelsAsync(true, TestContext.Current.CancellationToken));
        Assert.True(File.Exists(isolation.CacheFile));
        await VoxClip.Core.Tests.Tracks.WinCoreNative.TextOutputTests.AssertFileAsync(isolation.CacheFile);
        isolation.AssertRealCacheUnchanged();
        Assert.Empty(processes.Requests);
        Assert.Empty(keys.Accounts);
    }
}
