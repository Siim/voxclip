using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Models;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class ModelStoreTests
{
    private const string ModelId = "whisper-base.en-q5_1";
    private static readonly byte[] Contents = Encoding.UTF8.GetBytes("verified synthetic GGML file for range tests");

    [Fact]
    public async Task InstallsDependenciesOnceAndWritesCatalogueMarkerLast()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents, dependencies: true);
        using var handler = new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) }));
        using var http = new HttpClient(handler);
        var confirmations = 0;
        var store = new ModelStore(catalog, files.Root, http, (model, dependencies, _) =>
        {
            confirmations++;
            Assert.Equal(ModelId, model.Id);
            Assert.Equal("silero-vad-v6.2.0", Assert.Single(dependencies).Id);
            return Task.FromResult(true);
        });
        var installed = await store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        Assert.True(installed.Verified);
        Assert.True(await store.VerifyAsync(ModelId, null, TestContext.Current.CancellationToken));
        await VoxClip.Core.Tests.Tracks.WinCoreNative.TextOutputTests.AssertFileAsync(Path.Combine(installed.Directory, "installed.json"));
        using var marker = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(installed.Directory, "installed.json"), TestContext.Current.CancellationToken));
        Assert.Equal(ModelId, marker.RootElement.GetProperty("id").GetString());
        Assert.True(marker.RootElement.TryGetProperty("installedAt", out _));
        Assert.True(marker.RootElement.TryGetProperty("attribution", out _));
        Assert.Equal(2, (await store.ListInstalledAsync(TestContext.Current.CancellationToken)).Count);
        await Task.WhenAll(store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken), store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(2, handler.Calls);
        Assert.Equal(1, confirmations);
        await store.RemoveAsync(ModelId, TestContext.Current.CancellationToken);
        Assert.False(Directory.Exists(installed.Directory));
        Assert.Equal("silero-vad-v6.2.0", Assert.Single(await store.ListInstalledAsync(TestContext.Current.CancellationToken)).Id);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ResumesRangeOrRestartsWhenHostIgnoresRange(bool ignoreRange)
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        var model = (await catalog.GetModelAsync(ModelId, TestContext.Current.CancellationToken))!;
        var target = await PartialAsync(files.Root, model, Contents[..8]);
        using var handler = new StubHttp((request, _) =>
        {
            Assert.Equal(8, Assert.Single(request.Headers.Range!.Ranges).From);
            var response = new HttpResponseMessage(ignoreRange ? HttpStatusCode.OK : HttpStatusCode.PartialContent)
            {
                Content = new ByteArrayContent(ignoreRange ? Contents : Contents[8..])
            };
            if (!ignoreRange) response.Content.Headers.ContentRange = new ContentRangeHeaderValue(8, Contents.Length - 1, Contents.Length);
            return Task.FromResult(response);
        });
        using var http = new HttpClient(handler);
        var store = Store(catalog, files.Root, http);
        await store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        Assert.Equal(Contents, await File.ReadAllBytesAsync(target, TestContext.Current.CancellationToken));
        Assert.False(File.Exists(target + ".partial"));
        Assert.False(File.Exists(target + ".partial.json"));
    }

    [Fact]
    public async Task RejectsShaMismatchAndRemovesPartialWithoutInstalledMarker()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[Contents.Length]) }));
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => Store(catalog, files.Root, http).InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ModelChecksumMismatch, error.Code);
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(files.Root, "Models"), "*.partial", SearchOption.AllDirectories));
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(files.Root, "Models"), "installed.json", SearchOption.AllDirectories));
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task RejectsCompleteCorruptPartialWithoutRequestingUnsatisfiableRange()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        await PartialAsync(files.Root, (await catalog.GetModelAsync(ModelId, TestContext.Current.CancellationToken))!, new byte[Contents.Length]);
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not request an exhausted range."));
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => Store(catalog, files.Root, http).InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ModelChecksumMismatch, error.Code);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task RejectsInvalidContentRangeWithoutAppending()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        var target = await PartialAsync(files.Root, (await catalog.GetModelAsync(ModelId, TestContext.Current.CancellationToken))!, Contents[..8]);
        using var handler = new StubHttp((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(Contents[8..]) };
            response.Content.Headers.ContentRange = new ContentRangeHeaderValue(0, Contents.Length - 9, Contents.Length);
            return Task.FromResult(response);
        });
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => Store(catalog, files.Root, http).InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProviderError, error.Code);
        Assert.Equal("Hugging Face answered 206: The model host returned an invalid resume range.", error.Message);
        Assert.Equal(8, new FileInfo(target + ".partial").Length);
    }

    [Theory]
    [InlineData(404, VoxClipErrorCode.ProviderError, "Hugging Face answered 404: The model download could not be completed.")]
    [InlineData(429, VoxClipErrorCode.RateLimited, "Hugging Face is busy. Try again in a minute.")]
    public async Task ModelHostFailuresUseExactProviderCopy(int status, VoxClipErrorCode expected, string message)
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) =>
        {
            var response = new HttpResponseMessage((HttpStatusCode)status);
            response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.Zero);
            return Task.FromResult(response);
        });
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => Store(catalog, files.Root, http).InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(expected, error.Code);
        Assert.Equal(message, error.Message);
        Assert.Equal(status == 429 ? 3 : 1, handler.Calls);
    }

    [Fact]
    public async Task MissingOrDeclinedLicenceConsentNeverDownloads()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Consent was not given."));
        using var http = new HttpClient(handler);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new ModelStore(catalog, files.Root, http).InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new ModelStore(catalog, files.Root, http, (_, _, _) => Task.FromResult(false))
            .InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task DetectsDiskShortageBeforeConsentOrDownload()
    {
        using var files = new SpeechFiles();
        await files.CatalogueAsync(Contents);
        var path = Path.Combine(files.Root, "catalog.json");
        var node = JsonNode.Parse(await File.ReadAllTextAsync(path, TestContext.Current.CancellationToken))!;
        var model = node["models"]!.AsArray().Single(entry => entry!["id"]!.GetValue<string>() == ModelId)!;
        model["files"]![0]!["bytes"] = 1L << 60;
        model["totalBytes"] = 1L << 60;
        await File.WriteAllTextAsync(path, node.ToJsonString(), TestContext.Current.CancellationToken);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => new ModelStore(ModelCatalog.FromFile(path), files.Root)
            .InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.DiskFull, error.Code);
    }

    [Fact]
    public async Task VerifyDetectsSameSizeCorruptionAndInvalidatesMarker()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) }));
        using var http = new HttpClient(handler);
        var store = Store(catalog, files.Root, http);
        var installed = await store.InstallAsync(ModelId, null, TestContext.Current.CancellationToken);
        var model = (await catalog.GetModelAsync(ModelId, TestContext.Current.CancellationToken))!;
        await File.WriteAllBytesAsync(Path.Combine(installed.Directory, model.Files[0].Name), new byte[Contents.Length], TestContext.Current.CancellationToken);
        Assert.False(await store.VerifyAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Empty(await store.ListInstalledAsync(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task CancellationKeepsPartialForResume()
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var cancel = new CancellationTokenSource();
        using var handler = new StubHttp((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Contents) }));
        using var http = new HttpClient(handler);
        var progress = new CaptureProgress<ModelDownloadProgress>(value => { if (value.Stage == "downloading") cancel.Cancel(); });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Store(catalog, files.Root, http).InstallAsync(ModelId, progress, cancel.Token));
        Assert.Single(Directory.EnumerateFiles(Path.Combine(files.Root, "Models"), "*.partial", SearchOption.AllDirectories));
        Assert.Empty(Directory.EnumerateFiles(Path.Combine(files.Root, "Models"), "installed.json", SearchOption.AllDirectories));
    }

    [Theory]
    [InlineData("../escape")]
    [InlineData("a\\b")]
    [InlineData(".")]
    public async Task RemovalRejectsUnsafeModelIds(string id)
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        await Assert.ThrowsAsync<InvalidDataException>(() => new ModelStore(catalog, files.Root).RemoveAsync(id, TestContext.Current.CancellationToken));
        Assert.True(Directory.Exists(files.Root));
    }

    [Theory]
    [InlineData(403, 1)]
    [InlineData(404, 1)]
    [InlineData(429, 3)]
    [InlineData(503, 3)]
    public async Task DownloadHttpFailuresUseThePinnedCodesAndCopy(int status, int expectedAttempts)
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) =>
        {
            var response = StubHttp.Json("{}", (HttpStatusCode)status);
            response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.Zero);
            return Task.FromResult(response);
        });
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => Store(catalog, files.Root, http)
            .InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(status == 429 ? VoxClipErrorCode.RateLimited : VoxClipErrorCode.ProviderError, error.Code);
        Assert.Equal(status == 429 ? "Hugging Face is busy. Try again in a minute."
            : $"Hugging Face answered {status}: The model download could not be completed.", error.Message);
        Assert.Equal(expectedAttempts, handler.Calls);
        Assert.Empty(Directory.EnumerateFiles(files.Root, "installed.json", SearchOption.AllDirectories));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExhaustedTransportFailuresAreOffline(bool streamFailure)
    {
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync(Contents);
        using var handler = new StubHttp((_, _) => throw (streamFailure ? new IOException("Synthetic transfer failure.")
            : new HttpRequestException("Synthetic connection failure.")));
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => Store(catalog, files.Root, http)
            .InstallAsync(ModelId, null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.Offline, error.Code);
        Assert.Equal("You're offline. On-device transcription and editing still work.", error.Message);
        Assert.Equal(3, handler.Calls);
    }

    private static ModelStore Store(IModelCatalog catalog, string root, HttpClient http) => new(catalog, root, http, (_, _, _) => Task.FromResult(true));
    private static async Task<string> PartialAsync(string root, TranscriptionModel model, byte[] partial)
    {
        var directory = Path.Combine(root, "Models", "whispercpp", model.Id);
        Directory.CreateDirectory(directory);
        var file = model.Files[0];
        var target = Path.Combine(directory, file.Name);
        await File.WriteAllBytesAsync(target + ".partial", partial);
        await File.WriteAllTextAsync(target + ".partial.json", new JsonObject { ["url"] = file.Url.AbsoluteUri, ["bytes"] = file.Bytes, ["sha256"] = file.Sha256 }.ToJsonString());
        return target;
    }
}
