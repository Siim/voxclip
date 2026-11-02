using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class TranscriptionEvidenceTests
{
    [Fact]
    public async Task AcceptedHeadersAreAccountedBeforeAResponseStreamFailureAndNeverRetried()
    {
        using var files = new SpeechFiles();
        List<TranscriptionEvidence> evidence = [];
        using var handler = new StubHttp((_, _) =>
        {
            var response = new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new UnreadableContent() };
            response.Headers.Add("request-id", "body-unavailable-request");
            return Task.FromResult(response);
        });
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        await Assert.ThrowsAsync<IOException>(() => engine.TranscribeAsync(files.Request() with { Observe = evidence.Add },
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal("body-unavailable-request", Assert.Single(evidence, item => item.Kind == TranscriptionEvidenceKind.Accepted).RequestId);
        Assert.DoesNotContain(evidence, item => item.Kind == TranscriptionEvidenceKind.Completed);
        Assert.Equal(1, handler.Calls);
    }

    private sealed class UnreadableContent : HttpContent
    {
        protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromException<Stream>(new IOException("Response stream unavailable."));
        protected override Task SerializeToStreamAsync(Stream stream, System.Net.TransportContext? context) => Task.FromException(new IOException("Response stream unavailable."));
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
    }

    [Fact]
    public async Task HttpAcceptanceAndCompletionAreObservedBeforeAnyCacheReplay()
    {
        using var files = new SpeechFiles();
        List<TranscriptionEvidence> evidence = [];
        using var handler = new StubHttp((_, _) =>
        {
            Assert.Equal(TranscriptionEvidenceKind.UploadStarted, Assert.Single(evidence).Kind);
            var response = StubHttp.Json(ElevenLabsTests.Response);
            response.Headers.Add("request-id", "accepted-request");
            return Task.FromResult(response);
        });
        var request = files.Request() with { Observe = evidence.Add };
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var service = new TranscriptionService([engine], dataRoot: files.Root);
        var fresh = await service.TranscribeAsync(request, null, null, TestContext.Current.CancellationToken);
        Assert.False(fresh.FromCache);
        Assert.Equal(new[] { TranscriptionEvidenceKind.UploadStarted, TranscriptionEvidenceKind.Accepted, TranscriptionEvidenceKind.Completed },
            evidence.Select(item => item.Kind));
        Assert.Equal("accepted-request", evidence[1].RequestId);
        Assert.Equal("test-request", evidence[2].RequestId);
        evidence.Clear();
        var cached = await service.TranscribeAsync(request, null, null, TestContext.Current.CancellationToken);
        Assert.True(cached.FromCache);
        Assert.Equal(TranscriptionEvidenceKind.Cached, Assert.Single(evidence).Kind);
        Assert.Equal(1, handler.Calls);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task EvidencePersistenceFailureNeverRetriesOrStartsAnUnaccountedUpload(bool accepted)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(ElevenLabsTests.Response)));
        var failures = 0;
        var request = files.Request() with
        {
            Observe = evidence =>
            {
                if (evidence.Kind != (accepted ? TranscriptionEvidenceKind.Accepted : TranscriptionEvidenceKind.UploadStarted)) return;
                failures++;
                throw new IOException("Accounting unavailable.");
            }
        };
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        await Assert.ThrowsAsync<IOException>(() => engine.TranscribeAsync(request,
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(1, failures);
        Assert.Equal(accepted ? 1 : 0, handler.Calls);
    }

    [Fact]
    public async Task CancellationAfterAcceptanceRetainsProviderEvidenceWithoutRetrying()
    {
        using var files = new SpeechFiles();
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        List<TranscriptionEvidence> evidence = [];
        using var handler = new StubHttp((_, _) =>
        {
            var response = StubHttp.Json(ElevenLabsTests.Response);
            response.Headers.Add("request-id", "cancelled-request");
            return Task.FromResult(response);
        });
        var request = files.Request() with { Observe = item => { evidence.Add(item); if (item.Kind == TranscriptionEvidenceKind.Accepted) cancellation.Cancel(); } };
        using var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => engine.TranscribeAsync(request,
            new CaptureProgress<TranscriptionProgress>(), cancellation.Token));
        Assert.Equal("cancelled-request", Assert.Single(evidence, item => item.Kind == TranscriptionEvidenceKind.Accepted).RequestId);
        Assert.DoesNotContain(evidence, item => item.Kind == TranscriptionEvidenceKind.Completed);
        Assert.Equal(1, handler.Calls);
    }
}
