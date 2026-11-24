using System.Net;
using System.Text.Json;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Project;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class FalLipsyncTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "voxclip-fal-" + Guid.NewGuid().ToString("N"));
    private static CancellationToken Token => TestContext.Current.CancellationToken;
    private static VoiceLabPriceCatalog Prices => VoiceLabPriceCatalog.Parse(
        System.Text.Encoding.UTF8.GetBytes(FixtureLoader.ReadText("catalog/voice-lab.json")));

    [Theory]
    [InlineData(WholeClipLipsync.Lipsync2, "v2", "lipsync-2", "0.52")]
    [InlineData(WholeClipLipsync.Sync3, "v3", null, "1.38666666666667")]
    public async Task PricesThePaddedWindowAndRecoversTheAcceptedJobWithoutSubmittingAgain(
        WholeClipLipsync model, string version, string? modelName, string expected)
    {
        var store = Consent();
        var record = Assert.Single(store.ActiveVoices());
        var video = Path.Combine(root, "window.mp4");
        var audio = Path.Combine(root, "mixed.wav");
        File.WriteAllBytes(video, [1, 2]);
        File.WriteAllBytes(audio, [3, 4]);
        var responses = new FalHandler(version, modelName);
        using var provider = new FalLipsyncProvider(new Key(), Prices, responses);
        var quote = await provider.QuoteAsync(model, 10, 30, SyncMode.Remap, Token);
        Assert.Equal(decimal.Parse(expected, System.Globalization.CultureInfo.InvariantCulture), quote.Estimate.Usd!.Value, 10);
        Assert.Equal(10.4, quote.Estimate.Units);
        Assert.Empty(responses.Requests);
        var job = await provider.SubmitApprovedAsync(quote, video, audio, store, record, null, Token);
        Assert.Equal("fixture-job", job.RemoteId);
        Assert.Equal(5, responses.Requests.Count);

        var restarted = new FalHandler(version, modelName);
        using var recovery = new FalLipsyncProvider(new Key(), Prices, restarted);
        var done = Assert.IsType<LipsyncState.Done>(await recovery.PollAsync(recovery.Recover(model, job.RemoteId), Token));
        var path = Path.Combine(root, "result.mp4");
        await recovery.DownloadAsync(done.Result, path, null, Token);
        Assert.Equal("picture", File.ReadAllText(path));
        Assert.Equal(3, restarted.Requests.Count);
        Assert.All(restarted.Requests, request => Assert.Equal(HttpMethod.Get, request));
        await Assert.ThrowsAsync<FalLipsyncException>(() => recovery.DownloadAsync(new("https://elsewhere.invalid/files/result"), path, null, Token));
        Assert.Equal(3, restarted.Requests.Count);
    }

    private VoiceConsentStore Consent()
    {
        var store = new VoiceConsentStore(new DataLocations(root, Path.Combine(root, "settings.json"), Path.Combine(root, "models"),
            Path.Combine(root, "cache"), Path.Combine(root, "autosave"), Path.Combine(root, "secrets"), Path.Combine(root, "logs")));
        var record = JsonSerializer.Deserialize(FixtureLoader.ReadText("fixtures/voice-lab/consent-record.json"),
            VoiceConsentJson.Default.VoiceConsentRecord)!;
        var wave = VoiceLabTestCalls.SyntheticWav(16000, 16000 * 6, 2000);
        store.SaveStatement(wave, record.RecordId);
        store.Save(record with { Statement = record.Statement! with { AudioSha256 = VoiceConsentStore.Hash(wave) } });
        return store;
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }

    private sealed class Key : IKeyProvider
    {
        public Task<string?> GetKeyAsync(string account, CancellationToken ct) => Task.FromResult<string?>("fixture");
    }

    private sealed class FalHandler(string version, string? model) : HttpMessageHandler
    {
        public List<HttpMethod> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Requests.Add(request.Method);
            var uri = request.RequestUri!;
            if (uri.Host is "queue.fal.run" or "rest.fal.ai") Assert.Equal("Key", request.Headers.Authorization?.Scheme);
            else Assert.Null(request.Headers.Authorization);
            return (request.Method.Method, uri.Host, uri.AbsolutePath) switch
            {
                ("POST", "rest.fal.ai", "/storage/upload/initiate") => Reply("""{"upload_url":"https://storage.fal.ai/put","file_url":"https://v3.fal.media/files/upload"}"""),
                ("PUT", "storage.fal.ai", "/put") => Reply(""),
                ("POST", "queue.fal.run", var path) when path == "/fal-ai/sync-lipsync/" + version => await Submit(request, ct),
                ("GET", "queue.fal.run", "/fal-ai/sync-lipsync/requests/fixture-job/status") => Reply("""{"status":"COMPLETED"}"""),
                ("GET", "queue.fal.run", "/fal-ai/sync-lipsync/requests/fixture-job") => Reply("""{"video":{"url":"https://v3.fal.media/files/result"}}"""),
                ("GET", "v3.fal.media", "/files/result") => Reply("picture"),
                _ => throw new InvalidOperationException("Unexpected fal test request.")
            };
        }

        private async Task<HttpResponseMessage> Submit(HttpRequestMessage request, CancellationToken ct)
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            Assert.Equal("remap", body.RootElement.GetProperty("sync_mode").GetString());
            Assert.True(body.RootElement.GetProperty("enable_safety_checker").GetBoolean());
            Assert.Equal(model, body.RootElement.TryGetProperty("model", out var value) ? value.GetString() : null);
            return Reply("""{"request_id":"fixture-job","status_url":"https://queue.fal.run/fal-ai/sync-lipsync/requests/fixture-job/status"}""");
        }

        private static HttpResponseMessage Reply(string text) => new(HttpStatusCode.OK) { Content = new StringContent(text) };
    }
}
