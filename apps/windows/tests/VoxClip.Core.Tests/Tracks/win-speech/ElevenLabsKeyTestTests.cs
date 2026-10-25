using System.Net;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.Logging;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class ElevenLabsKeyTestTests
{
    [Fact]
    public async Task SuccessUsesOnlyAnUnpaidGetAndRegistersTheKeyBeforeSending()
    {
        var log = new KeyTestLog();
        using var handler = new StubHttp((request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal(new Uri("https://api.eu.residency.elevenlabs.io/v1/user/subscription"), request.RequestUri);
            Assert.Null(request.Content);
            Assert.Equal("synthetic-test-credential", Assert.Single(request.Headers.GetValues("xi-api-key")));
            Assert.Equal("synthetic-test-credential", Assert.Single(log.Secrets));
            Assert.StartsWith("VoxClip/", request.Headers.UserAgent.ToString());
            Assert.Contains(OperatingSystem.IsWindows() ? "Windows " : "macOS ", request.Headers.UserAgent.ToString());
            return Task.FromResult(StubHttp.Json("private-subscription-body"));
        });
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Eu, logger: log);
        var result = await engine.TestKeyAsync(TestContext.Current.CancellationToken);
        Assert.True(result.CanReadAccountDetails);
        Assert.Equal("Works.", result.Message);
        Assert.Equal(1, handler.Calls);
        Assert.Equal("elevenlabs key test HTTP 200", Assert.Single(log.Messages));
    }

    [Fact]
    public async Task KeyTestsAndUploadsUseTheSameUserAgent()
    {
        using var files = new SpeechFiles();
        var userAgents = new List<string>();
        using var handler = new StubHttp((request, _) =>
        {
            userAgents.Add(request.Headers.UserAgent.ToString());
            return Task.FromResult(StubHttp.Json(ElevenLabsTests.Response));
        });
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, ElevenLabsRegion.Default);
        await engine.TestKeyAsync(TestContext.Current.CancellationToken);
        await engine.TranscribeAsync(files.Request(), new CaptureProgress<Core.Domain.Transcript.TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.Equal(2, userAgents.Count);
        Assert.StartsWith("VoxClip/", userAgents[0]);
        Assert.Equal(userAgents[0], userAgents[1]);
    }

    [Theory]
    [InlineData(401, "{\"detail\":{\"status\":\"missing_permissions\",\"message\":\"Needs user_read\"}}")]
    [InlineData(403, "{\"detail\":{\"status\":\"missing_permissions\",\"message\":\"Needs user_read\"}}")]
    [InlineData(401, "{\"detail\":\"The API key is missing the permission user_read.\"}")]
    [InlineData(403, "The API key lacks the user_read permission.")]
    public async Task MissingPermissionProvesValidityButNotTranscriptionPermission(int status, string body)
    {
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(body, (HttpStatusCode)status)));
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var result = await engine.TestKeyAsync(TestContext.Current.CancellationToken);
        Assert.False(result.CanReadAccountDetails);
        Assert.Equal("The key works. It can't read account details (user_read), and that is fine for transcription.", result.Message);
        Assert.Equal(1, handler.Calls);
    }

    [Theory]
    [InlineData(401, "{\"detail\":\"private-response-body\"}", VoxClipErrorCode.KeyRejected)]
    [InlineData(401, "{\"detail\":\"Invalid key; no permission check was performed.\"}", VoxClipErrorCode.KeyRejected)]
    [InlineData(403, "{\"detail\":\"private-response-body\"}", VoxClipErrorCode.ProviderError)]
    [InlineData(307, "private-response-body", VoxClipErrorCode.ProviderError)]
    [InlineData(429, "private-response-body", VoxClipErrorCode.RateLimited)]
    [InlineData(503, "private-response-body", VoxClipErrorCode.ProviderError)]
    [InlineData(201, "private-response-body", VoxClipErrorCode.ProviderError)]
    public async Task FailuresNeverEchoProviderBodiesOrRetry(int status, string body, VoxClipErrorCode code)
    {
        var log = new KeyTestLog();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(body, (HttpStatusCode)status)));
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default, logger: log);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => engine.TestKeyAsync(TestContext.Current.CancellationToken));
        Assert.Equal(code, error.Code);
        if (code == VoxClipErrorCode.KeyRejected)
            Assert.Equal("ElevenLabs rejected the key (401). Your video is still here.", error.Message);
        Assert.DoesNotContain("private-response-body", error.Message);
        Assert.DoesNotContain("synthetic-test-credential", error.Message);
        Assert.Equal($"elevenlabs key test HTTP {status}", Assert.Single(log.Messages));
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task MissingKeyNeverSendsARequest()
    {
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not send."));
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(null), handler, region: ElevenLabsRegion.Default);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => engine.TestKeyAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.KeyMissing, error.Code);
        Assert.Equal("Add your ElevenLabs key in Settings to use it.", error.Message);
        Assert.Equal(0, handler.Calls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task TransportFailuresUseOnlyTheOfflineCopy(bool timeout)
    {
        using var handler = new StubHttp((_, _) => throw (timeout
            ? new OperationCanceledException("private-transport-body") : new HttpRequestException("private-transport-body")));
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => engine.TestKeyAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.Offline, error.Code);
        Assert.Equal("You're offline. On-device transcription and editing still work.", error.Message);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task CallerCancellationIsPreservedWithoutSendingARequest()
    {
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not send."));
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => engine.TestKeyAsync(cancelled.Token));
        Assert.Equal(0, handler.Calls);
    }

    private sealed class KeyTestLog : ILog
    {
        internal List<string> Secrets { get; } = [];
        internal List<string> Messages { get; } = [];
        public void RegisterSecret(string secret) => Secrets.Add(secret);
        public void Write(LogLevel level, string category, string message) => Messages.Add(message);
        public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>([]);
        public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
