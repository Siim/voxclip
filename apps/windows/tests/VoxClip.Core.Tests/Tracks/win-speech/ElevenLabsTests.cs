using System.Net;
using System.Net.Http.Headers;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.Speech;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.Speech;

public sealed class ElevenLabsTests
{
    internal const string Response = """{"language_code":"est","language_probability":0.98,"transcription_id":"test-request","words":[{"text":" Tere, ","type":"word","logprob":-0.02,"start":0.12,"end":0.48,"speaker_id":"speaker_0"},{"text":" ","type":"spacing","start":0.48,"end":0.6},{"text":"ee","type":"word","logprob":-0.2,"start":0.6,"end":0.8},{"text":"(laughs)","type":"audio_event","logprob":0,"start":0.9,"end":1,"speaker_id":"speaker_1"},{"text":"untimed","type":"word","start":null,"end":null},{"text":"ignored","type":"new_type"}]}""";

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MapsSyntheticResponseAndStreamsExactMultipart(bool diarize)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp(async (message, ct) =>
        {
            Assert.Equal("/v1/speech-to-text", message.RequestUri!.AbsolutePath);
            Assert.True(message.Headers.Contains("xi-api-key"));
            var body = Assert.IsAssignableFrom<MultipartFormDataContent>(message.Content);
            var parts = body.ToArray();
            var names = parts.Select(part => part.Headers.ContentDisposition!.Name!.Trim('"')).ToArray();
            var expected = new List<string> { "model_id", "language_code", "timestamps_granularity", "tag_audio_events", "diarize" };
            if (diarize) expected.Add("num_speakers");
            expected.AddRange(["keyterms", "keyterms", "file"]);
            Assert.Equal(expected, names);
            Assert.Equal("scribe_v2", await parts[0].ReadAsStringAsync(ct));
            Assert.Equal("et", await parts[1].ReadAsStringAsync(ct));
            Assert.Equal("word", await parts[2].ReadAsStringAsync(ct));
            Assert.Equal("true", await parts[3].ReadAsStringAsync(ct));
            Assert.Equal(diarize ? "true" : "false", await parts[4].ReadAsStringAsync(ct));
            Assert.Equal("audio/wav", parts[^1].Headers.ContentType!.MediaType);
            Assert.Equal("audio.wav", parts[^1].Headers.ContentDisposition!.FileName!.Trim('"'));
            Assert.Equal(await File.ReadAllBytesAsync(files.Wav, ct), await parts[^1].ReadAsByteArrayAsync(ct));
            Assert.DoesNotContain("no_verbatim", names);
            Assert.DoesNotContain("file_format", names);
            return StubHttp.Json(Response);
        });
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default);
        var raw = await engine.TranscribeAsync(files.Request(new(diarize, diarize ? 2 : null, ["VoxClip", "TalTech"]), new LanguageChoice.Forced("est")),
            new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken);
        Assert.Equal("et", raw.Language);
        Assert.Equal("test-request", raw.ProviderRequestId);
        Assert.Equal(0.98, raw.LanguageProbability);
        Assert.True(raw.Verbatim);
        Assert.Equal(TimingSource.Native, raw.Timing);
        Assert.Equal(4, raw.Tokens.Count);
        Assert.Equal("Tere,", raw.Tokens[0].Text);
        Assert.Equal(Math.Exp(-0.02), raw.Tokens[0].Conf);
        Assert.Equal(diarize ? "speaker_0" : null, raw.Tokens[0].Speaker);
        Assert.Equal(WordKind.Event, raw.Tokens[2].Kind);
        Assert.Null(raw.Tokens[2].Conf);
        Assert.Null(raw.Tokens[3].Start);
        Assert.All(raw.Tokens, token => Assert.False(token.JoinsPrevious));
        Assert.NotNull(engine.ProviderResponse(raw));
    }

    [Theory]
    [InlineData(401, "{\"detail\":\"bad credential\"}", VoxClipErrorCode.KeyRejected)]
    [InlineData(401, "{\"detail\":\"missing permission speech_to_text\"}", VoxClipErrorCode.KeyPermissionMissing)]
    [InlineData(403, "{}", VoxClipErrorCode.KeyPermissionMissing)]
    [InlineData(422, "{\"detail\":[{\"msg\":\"bad input\"}]}", VoxClipErrorCode.ProviderError)]
    [InlineData(400, "{\"detail\":\"credits used up\"}", VoxClipErrorCode.QuotaExceeded)]
    [InlineData(400, "{\"detail\":{\"status\":\"invalid_parameter\",\"message\":\"bad input\"}}", VoxClipErrorCode.ProviderError)]
    public async Task MapsErrorsWithoutRetryingClientFailures(int status, string body, VoxClipErrorCode expected)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(body, (HttpStatusCode)status)));
        var error = await Assert.ThrowsAsync<VoxClipException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(expected, error.Code);
        Assert.Equal(1, handler.Calls);
        if (expected == VoxClipErrorCode.ProviderError) Assert.Contains("bad input", error.Message);
    }

    [Theory]
    [InlineData(429, VoxClipErrorCode.RateLimited)]
    [InlineData(500, VoxClipErrorCode.ProviderError)]
    [InlineData(529, VoxClipErrorCode.ProviderError)]
    public async Task RetryableFailuresStopAfterThreeAttempts(int status, VoxClipErrorCode expected)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) =>
        {
            var response = StubHttp.Json("{}", (HttpStatusCode)status);
            response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.Zero);
            return Task.FromResult(response);
        });
        var error = await Assert.ThrowsAsync<VoxClipException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(expected, error.Code);
        Assert.Equal(3, handler.Calls);
    }

    [Fact]
    public void RetryAfterAndDefaultBackoffAreBounded()
    {
        using var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
        response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromMinutes(5));
        Assert.Equal(TimeSpan.FromSeconds(30), SpeechTransport.Backoff(response, 0));
        Assert.Equal(TimeSpan.FromSeconds(1), SpeechTransport.Backoff(null, 0));
        Assert.Equal(TimeSpan.FromSeconds(2), SpeechTransport.Backoff(null, 1));
    }

    [Theory]
    [InlineData("{}", VoxClipErrorCode.ProviderError)]
    [InlineData("not json", VoxClipErrorCode.ProviderError)]
    [InlineData("{\"transcripts\":[],\"language_code\":\"en\",\"words\":[]}", VoxClipErrorCode.ProviderError)]
    [InlineData("{\"language_code\":\"en\",\"words\":[4]}", VoxClipErrorCode.ProviderError)]
    public async Task RejectsUnexpectedOrEmptyResponseShapes(string response, VoxClipErrorCode expected)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json(response)));
        var error = await Assert.ThrowsAsync<VoxClipException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(expected, error.Code);
        Assert.Equal("ElevenLabs answered 200: unexpected response shape", error.Message);
    }

    [Fact]
    public async Task UploadCompletionChangesStageBeforeProviderFinishes()
    {
        using var files = new SpeechFiles();
        var progress = new CaptureProgress<TranscriptionProgress>();
        using var handler = new StubHttp(async (message, ct) =>
        {
            await message.Content!.CopyToAsync(Stream.Null, ct);
            Assert.Equal(new(TranscriptionStage.Uploading, 1), progress.Values[^2]);
            Assert.Equal(new(TranscriptionStage.Transcribing, null), progress.Values[^1]);
            await Task.Delay(150, ct);
            return StubHttp.Json(Response);
        });
        await ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default).TranscribeAsync(files.Request(), progress, TestContext.Current.CancellationToken);
        Assert.Contains(progress.Values, value => value.Stage == TranscriptionStage.Uploading && value.Fraction == 0);
    }

    [Fact]
    public async Task MissingCataloguePreventsEvenAutoLanguageUpload()
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        var missing = new VoxClip.Core.Services.Models.ModelCatalog(files.Root);
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default, modelCatalog: missing);
        var error = await Assert.ThrowsAsync<VoxClipException>(() => new TranscriptionService([engine], missing, files.Root)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.SharedResourcesMissing, error.Code);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task ParameterlessConstructionHasNoImplicitEnvironmentKeys()
    {
        Assert.IsType<Readiness.NeedsKey>(await new ElevenLabsTranscriber().ReadinessAsync(
            new(TranscriptEngine.Elevenlabs, null, new LanguageChoice.Auto(), new()), TestContext.Current.CancellationToken));
        var provider = ElevenLabsTranscriber.CreateEnvironmentKeyProvider();
        Assert.Null(await provider.GetKeyAsync("not-an-account", TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(0.09, VoxClipErrorCode.NoSpeech, null)]
    [InlineData(36000.1, VoxClipErrorCode.MediaTooLong, "10:00:00")]
    [InlineData(90061, VoxClipErrorCode.MediaTooLong, "25:01:01")]
    public async Task DurationLimitsPreventNetworkUse(double duration, VoxClipErrorCode expected, string? durationText)
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        var request = files.Request();
        var error = await Assert.ThrowsAsync<VoxClipException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default)
            .TranscribeAsync(request with { Audio = request.Audio with { DurationSeconds = duration } }, new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(expected, error.Code);
        if (durationText is not null) Assert.Equal($"ElevenLabs accepts up to 10 hours. This take is {durationText}.", error.Message);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public async Task MissingKeyAndInvalidOptionsDoNotUpload()
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => throw new InvalidOperationException("Must not upload."));
        var engine = ElevenLabsTranscriber.ForTesting(new TestKeys(null), handler, region: ElevenLabsRegion.Default);
        Assert.IsType<Readiness.NeedsKey>(await engine.ReadinessAsync(files.Request().Plan, TestContext.Current.CancellationToken));
        var error = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.KeyMissing, error.Code);
        await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(files.Request(new(NumSpeakers: 2)), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        var invalidTerm = await Assert.ThrowsAsync<VoxClipException>(() => engine.TranscribeAsync(files.Request(new(Keyterms: ["bad[term]"])), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.Contains("bad[term]", invalidTerm.Message);
        Assert.Equal(0, handler.Calls);
    }

    [Fact]
    public void KeyErrorsAtAnyStatusReadAsKeyProblemsAndResidencyExplainsItself()
    {
        const string invalid = "{\"detail\":{\"type\":\"authentication_error\",\"code\":\"invalid_api_key\",\"message\":\"Invalid API key\"}}";
        Assert.Equal(VoxClipErrorCode.KeyRejected, ElevenLabsTranscriber.MapError(HttpStatusCode.BadRequest, invalid, "synthetic-key").Code);
        var residency = ElevenLabsTranscriber.MapError(HttpStatusCode.BadRequest, invalid, "synthetic-key", ElevenLabsRegion.Eu);
        Assert.Equal(VoxClipErrorCode.ProviderError, residency.Code);
        Assert.Contains("most accounts use Region: Default", residency.Message);
        Assert.Contains("IN residency", ElevenLabsTranscriber.MapError(HttpStatusCode.BadRequest, "{}", "synthetic-key", ElevenLabsRegion.In).Message);
        Assert.Equal("ElevenLabs answered 400: The request could not be completed.", ElevenLabsTranscriber.MapError(HttpStatusCode.BadRequest, "{}", "synthetic-key", ElevenLabsRegion.Us).Message);
        Assert.Equal(VoxClipErrorCode.KeyRejected, ElevenLabsTranscriber.MapError(HttpStatusCode.Unauthorized, "{}", "synthetic-key").Code);
        var unauthorized = ElevenLabsTranscriber.MapError(HttpStatusCode.Unauthorized, "{}", "synthetic-key", ElevenLabsRegion.Eu);
        Assert.Equal(VoxClipErrorCode.ProviderError, unauthorized.Code);
        Assert.Contains("EU residency", unauthorized.Message);
        var longReason = "{\"detail\":{\"message\":\"" + new string('x', 300) + "\"}}";
        var cut = ElevenLabsTranscriber.MapError(HttpStatusCode.BadRequest, longReason, "synthetic-key", ElevenLabsRegion.Sg).Message;
        Assert.EndsWith("most accounts use Region: Default", cut);
        Assert.Equal("ElevenLabs answered 400: ".Length + 200, cut.Length);
    }

    [Fact]
    public async Task KeyTestExplainsResidencyWithoutEchoingTheBody()
    {
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json("{\"detail\":{\"status\":\"invalid_api_key\"}}", HttpStatusCode.Unauthorized)));
        var error = await Assert.ThrowsAsync<VoxClipException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Eu)
            .TestKeyAsync(TestContext.Current.CancellationToken));
        Assert.Equal(VoxClipErrorCode.ProviderError, error.Code);
        Assert.Equal("ElevenLabs answered 401: The request could not be completed. ElevenLabs EU residency needs a key from a data-residency workspace; most accounts use Region: Default", error.Message);
        using var busy = new StubHttp((_, _) => Task.FromResult(StubHttp.Json("{}", HttpStatusCode.ServiceUnavailable)));
        var outage = await Assert.ThrowsAsync<VoxClipException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), busy, region: ElevenLabsRegion.Default)
            .TestKeyAsync(TestContext.Current.CancellationToken));
        Assert.Equal("ElevenLabs answered 503: The request could not be completed.", outage.Message);
    }

    [Fact]
    public async Task ErrorDetailIsRedactedBeforeTruncation()
    {
        using var files = new SpeechFiles();
        using var handler = new StubHttp((_, _) => Task.FromResult(StubHttp.Json("{\"detail\":\"synthetic-test-credential \"}", HttpStatusCode.BadRequest)));
        var error = await Assert.ThrowsAsync<VoxClipException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), TestContext.Current.CancellationToken));
        Assert.DoesNotContain("synthetic-test-credential", error.Message);
        Assert.Contains("[REDACTED]", error.Message);
    }

    [Fact]
    public async Task CancellationInterruptsHttpAndNeverRetries()
    {
        using var files = new SpeechFiles();
        using var cancel = new CancellationTokenSource();
        using var handler = new StubHttp(async (_, ct) => { cancel.Cancel(); await Task.Delay(Timeout.InfiniteTimeSpan, ct); return StubHttp.Json(Response); });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ElevenLabsTranscriber.ForTesting(new TestKeys(), handler, region: ElevenLabsRegion.Default)
            .TranscribeAsync(files.Request(), new CaptureProgress<TranscriptionProgress>(), cancel.Token));
        Assert.Equal(1, handler.Calls);
    }
}
