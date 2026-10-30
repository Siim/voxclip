using System.Net;
using System.Text;
using System.Text.Json;
using VoxClip.Core.Services.Models;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class ModelDownloadCopyTests
{
    private const string ModelId = "whisper-base.en-q5_1";
    private static readonly byte[] Contents = Encoding.UTF8.GetBytes("model download copy contents");

    [Fact]
    public async Task ConfirmationNamesThePublisherAndCountsTheRequiredModels()
    {
        var catalogue = await new ModelCatalog(FixtureLoader.SharedRoot).GetModelsAsync(TestContext.Current.CancellationToken);
        var model = catalogue.Single(entry => entry.Id == "whisper-large-v3-turbo-q5_0");
        var dependencies = ModelDownloadCopy.Dependencies(model, catalogue);
        Assert.Equal("silero-vad-v6.2.0", Assert.Single(dependencies).Id);
        Assert.Empty(ModelDownloadCopy.Dependencies(dependencies[0], catalogue));
        Assert.Equal("Download Multilingual · Whisper large-v3-turbo (Q5_0) from huggingface.co?", ModelDownloadCopy.Title(model));
        Assert.Equal("This model is published by whisper.cpp project (ggml-org), Hugging Face ggerganov/whisper.cpp, not by VoxClip. " +
            "It downloads from the publisher (574.93 MB) and runs on this PC. Licence: MIT. By downloading you accept the publisher's terms.\n\n" +
            model.Attribution, ModelDownloadCopy.Body(model, dependencies));
        Assert.Equal("574.04 MB", ModelDownloadCopy.Size(model, []));
        Assert.Equal(new Uri("https://huggingface.co/ggerganov/whisper.cpp"), ModelDownloadCopy.SourcePage(model));
    }

    [Fact]
    public async Task ProgressCountsTheWholeDownload()
    {
        var catalogue = await new ModelCatalog(FixtureLoader.SharedRoot).GetModelsAsync(TestContext.Current.CancellationToken);
        var model = catalogue.Single(entry => entry.Id == "whisper-large-v3-turbo-q5_0");
        Assert.Equal("Downloading Multilingual · Whisper large-v3-turbo (Q5_0) · 50% · 287.46 MB of 574.93 MB",
            ModelDownloadCopy.Progress(model, new(model.Id, "ggml-large-v3-turbo-q5_0.bin", "downloading", 287_463_147, 574_926_293)));
        Assert.Equal("Downloading Multilingual · Whisper large-v3-turbo (Q5_0) · 100% · 574.93 MB of 574.93 MB",
            ModelDownloadCopy.Progress(model, new(model.Id, "ggml-large-v3-turbo-q5_0.bin", "verifying", 574_926_293, 574_926_293)));
        Assert.Equal("Downloading Multilingual · Whisper large-v3-turbo (Q5_0)…",
            ModelDownloadCopy.Progress(model, new(model.Id, "ggml-large-v3-turbo-q5_0.bin", "downloading", 1, null)));
    }

    [Theory]
    [InlineData("""{"sourcePage":"http://huggingface.co/ggerganov/whisper.cpp"}""")]
    [InlineData("""{"sourcePage":"https://example.com/ggerganov/whisper.cpp"}""")]
    [InlineData("""{"sourcePage":"huggingface.co/ggerganov/whisper.cpp"}""")]
    [InlineData("""{}""")]
    public async Task OnlyAnHttpsSourcePageOnTheDownloadHostGetsAButton(string metadata)
    {
        var catalogue = await new ModelCatalog(FixtureLoader.SharedRoot).GetModelsAsync(TestContext.Current.CancellationToken);
        using var document = JsonDocument.Parse(metadata);
        var model = catalogue.Single(entry => entry.Id == ModelId) with { RawMetadata = document.RootElement.Clone() };
        Assert.Null(ModelDownloadCopy.SourcePage(model));
        Assert.Equal(ModelId, ModelDownloadCopy.DisplayName(model));
        Assert.StartsWith("This model is published by huggingface.co, not by VoxClip.", ModelDownloadCopy.Body(model, []));
    }

    [Fact]
    public async Task StoreAsksForTheTermsTheCatalogueShows()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents, dependencies: true);
        var model = (await catalog.GetModelAsync(ModelId, TestContext.Current.CancellationToken))!;
        var shown = ModelDownloadCopy.Body(model, ModelDownloadCopy.Dependencies(model, await catalog.GetModelsAsync(TestContext.Current.CancellationToken)));
        using var handler = new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) }));
        using var http = new HttpClient(handler);
        string? asked = null;
        var store = new ModelStore(catalog, files.Root, http, (candidate, dependencies, _) =>
        {
            asked = ModelDownloadCopy.Body(candidate, dependencies);
            return Task.FromResult(true);
        });
        Assert.True((await store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken)).Verified);
        Assert.Equal(shown, asked);
        Assert.Equal(2, handler.Calls);
    }
}
