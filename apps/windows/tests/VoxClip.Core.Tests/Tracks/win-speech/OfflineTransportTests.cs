using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Models;
using VoxClip.Core.Services.Speech;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class OfflineTransportTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ProductionSpeechConstructorFailsOfflineBeforeConnecting(bool keyTest)
    {
        if (!NetworkGuard.Enabled) return;
        using var files = new SpeechFiles();
        using var transcriber = new ElevenLabsTranscriber(new TestKeys());
        var before = NetworkGuard.BlockedRequests("api.elevenlabs.io");
        var failure = await Assert.ThrowsAsync<VoxClipException>(async () =>
        {
            if (keyTest) await transcriber.TestKeyAsync(TestContext.Current.CancellationToken);
            else await transcriber.TranscribeAsync(files.Request(), new CaptureProgress<Core.Domain.Transcript.TranscriptionProgress>(), TestContext.Current.CancellationToken);
        });
        Assert.Equal(VoxClipErrorCode.Offline, failure.Code);
        Assert.True(NetworkGuard.BlockedRequests("api.elevenlabs.io") > before);
        Assert.True(transcriber.OwnedHandler!.UseProxy);
        Assert.Null(transcriber.OwnedHandler.Proxy);
    }

    [Fact]
    public async Task ProductionModelDownloadFailsOfflineBeforeConnecting()
    {
        if (!NetworkGuard.Enabled) return;
        using var files = new SpeechFiles();
        var catalog = await files.CatalogueAsync([1, 2, 3]);
        var store = new ModelStore(catalog, files.Root, confirmDownload: (_, _, _) => Task.FromResult(true));
        var before = NetworkGuard.BlockedRequests("huggingface.co");
        var failure = await Assert.ThrowsAsync<VoxClipException>(() => store.InstallAsync("whisper-base.en-q5_1", null, TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.Offline, failure.Code);
        Assert.True(NetworkGuard.BlockedRequests("huggingface.co") > before);
        Assert.Empty(Directory.EnumerateFiles(files.Root, "*.bin", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task ProductionCloudConnectorFailsOfflineBeforeConnecting()
    {
        if (!NetworkGuard.Enabled) return;
        var catalog = LlmCatalog.Load(FixtureLoader.SharedRoot);
        var connector = new LlmConnector(ConnectorId.OpenAI, new SyntheticKeys(), catalog, new Redactor());
        var before = NetworkGuard.BlockedRequests("api.openai.com");
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(catalog.TestRequest(ConnectorId.OpenAI), "gpt-5.4", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Network, failure.Error.Kind);
        Assert.True(NetworkGuard.BlockedRequests("api.openai.com") > before);
        using var handler = LlmRuntime.CreateHttpHandler();
        Assert.True(handler.UseProxy);
        Assert.Null(handler.Proxy);
    }

    private sealed class SyntheticKeys : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => Task.FromResult<string?>("synthetic-offline-credential");
    }
}
