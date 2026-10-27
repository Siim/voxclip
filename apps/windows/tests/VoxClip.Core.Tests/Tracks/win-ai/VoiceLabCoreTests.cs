using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class VoiceLabCoreTests
{
    private const string Models = "[{\"model_id\":\"speech\",\"name\":\"Speech\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}]},{\"model_id\":\"changer\",\"can_do_voice_conversion\":true,\"languages\":[{\"language_id\":\"en\"}]}]";
    private const string Voices = "{\"voices\":[{\"voice_id\":\"own123\",\"name\":\"Mine\",\"category\":\"cloned\",\"is_owner\":true,\"voice_verification\":{\"requires_verification\":true,\"is_verified\":true}},{\"voice_id\":\"stock123\",\"name\":\"Stock\",\"category\":\"premade\"},{\"voice_id\":\"generated123\",\"name\":\"Generated\",\"category\":\"generated\",\"is_owner\":true}],\"has_more\":false}";
    private const string Plan = "{\"tier\":\"starter\",\"status\":\"active\",\"character_count\":0,\"character_limit\":10000,\"can_use_instant_voice_cloning\":true,\"voice_slots_used\":0,\"voice_limit\":10}";
    private static OwnVoicePolicy Policy(string? voice = "own123") => new("record-1", voice, true, true, true, true, true);
    private static byte[] Pcm()
    {
        var bytes = new byte[2400];
        bytes[0] = 0xff; bytes[1] = 0xff;
        return bytes;
    }
    private static byte[] Wav()
    {
        var bytes = new byte[44 + 1600];
        "RIFF"u8.CopyTo(bytes); BitConverter.TryWriteBytes(bytes.AsSpan(4), bytes.Length - 8);
        "WAVEfmt "u8.CopyTo(bytes.AsSpan(8)); BitConverter.TryWriteBytes(bytes.AsSpan(16), 16);
        BitConverter.TryWriteBytes(bytes.AsSpan(20), (short)1); BitConverter.TryWriteBytes(bytes.AsSpan(22), (short)1);
        BitConverter.TryWriteBytes(bytes.AsSpan(24), 16000); BitConverter.TryWriteBytes(bytes.AsSpan(28), 32000);
        BitConverter.TryWriteBytes(bytes.AsSpan(32), (short)2); BitConverter.TryWriteBytes(bytes.AsSpan(34), (short)16);
        "data"u8.CopyTo(bytes.AsSpan(36)); BitConverter.TryWriteBytes(bytes.AsSpan(40), 1600);
        return bytes;
    }
    private static HttpResponseMessage Json(int status, string body) => new((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private static HttpResponseMessage Audio(byte[] bytes, string type = "application/octet-stream") => new(HttpStatusCode.OK)
    { Content = new ByteArrayContent(bytes) { Headers = { ContentType = new(type) } } };
    private sealed class VoiceHttp(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        internal List<(string Method, string Url, string Body, string? Header)> Calls { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Calls.Add((request.Method.Method, request.RequestUri!.AbsoluteUri,
                request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct),
                request.Headers.GetValues("xi-api-key").Single()));
            var reply = await respond(request, ct);
            reply.RequestMessage = request;
            return reply;
        }
    }
    private static Task<HttpResponseMessage> Discovery(HttpRequestMessage request) => Task.FromResult(request.RequestUri!.AbsolutePath switch
    {
        "/v1/models" => Json(200, Models), "/v2/voices" => Json(200, Voices),
        "/v1/user/subscription" => Json(200, Plan), _ => Json(404, "{}")
    });

    [Fact]
    public async Task RegionalDiscoveryAndExactApprovalBindTtsAndConversion()
    {
        var pcm = Pcm();
        using var handler = new VoiceHttp((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath switch
        {
            "/v1/text-to-speech/stock123/with-timestamps" => Json(200, "{\"audio_base64\":\"" + Convert.ToBase64String(pcm) + "\",\"alignment\":{\"characters\":[\"H\",\"i\"],\"character_start_times_seconds\":[0,0.02],\"character_end_times_seconds\":[0.02,0.04]}}"),
            "/v1/voice-changer/stock123" => Audio(pcm),
            _ => Discovery(request).Result
        }));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys("synthetic-test-key"), handler, ElevenLabsRegion.Eu, new CaptureLog());
        Assert.Equal(2, (await service.DiscoverModelsAsync(TestContext.Current.CancellationToken)).Count);
        Assert.Equal(3, (await service.DiscoverVoicesAsync(TestContext.Current.CancellationToken)).Count);
        var prepared = service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en");
        Assert.Null(prepared.Estimate.Usd); Assert.Null(prepared.Estimate.Credits);
        var approval = service.Approve(prepared, true);
        await Assert.ThrowsAsync<VoiceLabException>(() => service.SynthesizeAsync("Ho", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en", approval, TestContext.Current.CancellationToken));
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() => service.SynthesizeAsync("Hi", "speech",
            VoiceLabVoiceChoice.Stock("stock123"), "en", approval, TestContext.Current.CancellationToken, new VoiceLabSpeechOptions(8)))).Kind);
        var result = await service.SynthesizeAsync("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en", approval, TestContext.Current.CancellationToken);
        Assert.Equal(pcm, result.Pcm); Assert.Equal(24000, result.SampleRate); Assert.Equal(2, result.Alignment!.Count);
        Assert.Equal("api.eu.residency.elevenlabs.io", new Uri(handler.Calls[^1].Url).Host);
        Assert.EndsWith("?output_format=pcm_24000", handler.Calls[^1].Url);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse("{\"text\":\"Hi\",\"model_id\":\"speech\",\"language_code\":\"en\",\"seed\":7,\"apply_text_normalization\":\"auto\",\"voice_settings\":{\"stability\":0.5,\"similarity_boost\":0.8}}"),
            JsonNode.Parse(handler.Calls[^1].Body)));
        Assert.Equal("synthetic-test-key", handler.Calls[^1].Header);
        await Assert.ThrowsAsync<VoiceLabException>(() => service.SynthesizeAsync("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en", approval, TestContext.Current.CancellationToken));
        var wav = Wav();
        var convert = service.Approve(service.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
        var altered = wav.ToArray(); altered[^1] = 1;
        Assert.Equal(VoiceLabErrorKind.ConsentRequired,
            (await Assert.ThrowsAsync<VoiceLabException>(() => service.ConvertAsync(altered, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", convert, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() => service.ConvertAsync(wav, "changer",
            VoiceLabVoiceChoice.Stock("stock123"), "en", convert, TestContext.Current.CancellationToken, cleanAudioOn: true))).Kind);
        var changed = await service.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", convert, TestContext.Current.CancellationToken);
        Assert.Null(changed.Alignment);
        Assert.Contains("name=\"audio\"; filename=\"audio.wav\"", handler.Calls[^1].Body);
        Assert.Contains("Content-Type: audio/wav", handler.Calls[^1].Body);
        Assert.Contains("\r\n\r\n{\"stability\":0.5,\"similarity_boost\":0.75}\r\n", handler.Calls[^1].Body);
        Assert.Contains("name=\"remove_background_noise\"\r\n\r\ntrue\r\n", handler.Calls[^1].Body);
        Assert.Equal(4, handler.Calls.Count);
    }

    [Fact]
    public async Task PolicyAndDiscoveryRejectUnsafeChoicesAndMalformedReplies()
    {
        using var handler = new VoiceHttp((request, _) => Discovery(request));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        await service.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await service.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Stock("own123"), "en")).Kind);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Own("own123", Policy("different")), "en")).Kind);
        Assert.Equal(VoiceLabErrorKind.UnsupportedModel, Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "et")).Kind);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.PrepareConversion(new byte[] { 1, 2 }, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en")).Kind);
        using var duplicates = new VoiceHttp((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath == "/v1/models" ? Json(200, "[{\"model_id\":\"x\"},{\"model_id\":\"x\"}]") :
            Json(200, "{\"voices\":[{\"voice_id\":\"x\",\"name\":\"one\",\"category\":\"premade\"},{\"voice_id\":\"x\",\"name\":\"two\",\"category\":\"premade\"}],\"has_more\":false}")));
        using var malformed = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), duplicates, ElevenLabsRegion.Default);
        Assert.Equal(VoiceLabErrorKind.MalformedResponse, (await Assert.ThrowsAsync<VoiceLabException>(() => malformed.DiscoverModelsAsync(TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(VoiceLabErrorKind.MalformedResponse, (await Assert.ThrowsAsync<VoiceLabException>(() => malformed.DiscoverVoicesAsync(TestContext.Current.CancellationToken))).Kind);
    }

    [Fact]
    public async Task CloneAndFailedPaidSendAreClaimedOnce()
    {
        var mutations = 0;
        using var handler = new VoiceHttp((request, _) =>
        {
            if (request.RequestUri!.AbsolutePath == "/v1/voices/add") { Interlocked.Increment(ref mutations); return Task.FromResult(Json(429, "busy")); }
            return Discovery(request);
        });
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Us);
        var clone = VoiceLabTestCalls.CloneRequest();
        await service.DiscoverSubscriptionAsync(TestContext.Current.CancellationToken);
        var prepared = service.PrepareClone(clone, Policy(null));
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, Assert.Throws<VoiceLabException>(() => service.Approve(prepared, false)).Kind);
        var approval = service.Approve(prepared, true);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.CreateOwnCloneAsync(VoiceLabTestCalls.CloneRequest(trainingFill: 2), Policy(null), approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(0, mutations);
        var first = await Assert.ThrowsAsync<VoiceLabException>(() => service.CreateOwnCloneAsync(clone, Policy(null), approval, TestContext.Current.CancellationToken));
        Assert.Equal(VoiceLabErrorKind.RateLimited, first.Kind);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() => service.CreateOwnCloneAsync(clone, Policy(null), approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(1, mutations);
        Assert.True(handler.Calls[^1].Body.Contains("name=files[]", StringComparison.Ordinal) || handler.Calls[^1].Body.Contains("name=\"files[]\"", StringComparison.Ordinal));
        Assert.Equal("api.us.elevenlabs.io", new Uri(handler.Calls[^1].Url).Host);
    }

    [Fact]
    public async Task UnverifiedOwnCloneCanBeDeletedButCannotGenerate()
    {
        using var handler = new VoiceHttp((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath switch
        {
            "/v1/user/subscription" => Json(200, Plan),
            "/v1/models" => Json(200, Models),
            "/v1/voices/add" => Json(200, "{\"voice_id\":\"pending123\",\"requires_verification\":true}"),
            "/v1/voices/pending123" => Json(404, "{}"),
            _ => Json(404, "{}")
        }));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        var clone = VoiceLabTestCalls.CloneRequest();
        await service.DiscoverSubscriptionAsync(TestContext.Current.CancellationToken);
        var createPolicy = Policy(null);
        var create = service.Approve(service.PrepareClone(clone, createPolicy), true);
        var result = await service.CreateOwnCloneAsync(clone, createPolicy, create, TestContext.Current.CancellationToken);
        Assert.True(result.RequiresVerification);
        await service.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired,
            Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Own("pending123", Policy("pending123")), "en")).Kind);
        var deletePolicy = Policy("pending123");
        var delete = service.Approve(service.PrepareDeletion("pending123", deletePolicy), true);
        await service.DeleteOwnCloneAsync("pending123", deletePolicy, delete, TestContext.Current.CancellationToken);
        Assert.Equal("DELETE", handler.Calls[^1].Method);
    }

    [Fact]
    public async Task ConversionRejectsWrongContentTypeAndStructuralWav()
    {
        using var handler = new VoiceHttp((request, ct) =>
        {
            if (request.RequestUri!.AbsolutePath == "/v1/models") return Discovery(request);
            if (request.RequestUri.AbsolutePath == "/v2/voices") return Discovery(request);
            return Task.FromResult(Audio(new byte[1024], "audio/mpeg"));
        });
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        await service.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await service.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
        var wav = Wav();
        var approval = service.Approve(service.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
        Assert.Equal(VoiceLabErrorKind.InvalidAudio, (await Assert.ThrowsAsync<VoiceLabException>(() => service.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(3, handler.Calls.Count);
        using var encodedHandler = new VoiceHttp((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath switch
        {
            "/v1/models" => Json(200, Models), "/v2/voices" => Json(200, Voices),
            _ => Audio(Wav())
        }));
        using var encoded = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), encodedHandler, ElevenLabsRegion.Default);
        await encoded.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await encoded.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
        var encodedApproval = encoded.Approve(encoded.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
        Assert.Equal(VoiceLabErrorKind.InvalidAudio, (await Assert.ThrowsAsync<VoiceLabException>(() => encoded.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", encodedApproval, TestContext.Current.CancellationToken))).Kind);
    }

    [Fact]
    public async Task OversizedResponseAndCancellationAreSingleDispatch()
    {
        using var oversizedHandler = new VoiceHttp((request, _) =>
        {
            if (request.RequestUri!.AbsolutePath == "/v1/models" || request.RequestUri.AbsolutePath == "/v2/voices") return Discovery(request);
            var response = Audio(new byte[1024]); response.Content.Headers.ContentLength = 33 * 1024 * 1024;
            return Task.FromResult(response);
        });
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), oversizedHandler, ElevenLabsRegion.Default);
        await service.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await service.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
        var wav = Wav();
        var approval = service.Approve(service.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
        Assert.Equal(VoiceLabErrorKind.ResponseTooLarge, (await Assert.ThrowsAsync<VoiceLabException>(() => service.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(3, oversizedHandler.Calls.Count);

        using var cancelHandler = new VoiceHttp(async (request, ct) =>
        {
            if (request.RequestUri!.AbsolutePath == "/v1/models" || request.RequestUri.AbsolutePath == "/v2/voices") return await Discovery(request);
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            throw new Exception("unreachable");
        });
        using var cancelling = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), cancelHandler, ElevenLabsRegion.Default);
        await cancelling.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await cancelling.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
        var cancelledApproval = cancelling.Approve(cancelling.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
        using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(20));
        Assert.Equal(VoiceLabErrorKind.Cancelled, (await Assert.ThrowsAsync<VoiceLabException>(() => cancelling.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", cancelledApproval, stop.Token))).Kind);
        Assert.Equal(3, cancelHandler.Calls.Count);
    }

    [Fact]
    public async Task RepeatingVoicePageTokenStopsWithinBound()
    {
        using var handler = new VoiceHttp((request, _) => Task.FromResult(Json(200,
            "{\"voices\":[],\"has_more\":true,\"next_page_token\":\"same\"}")));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        Assert.Equal(VoiceLabErrorKind.MalformedResponse,
            (await Assert.ThrowsAsync<VoiceLabException>(() => service.DiscoverVoicesAsync(TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(2, handler.Calls.Count);
    }

    [Theory]
    [InlineData("\n")]
    [InlineData("\r\n")]
    [InlineData(" ")]
    public async Task ProviderIdsRejectTrailingLineBreaksAndSpaces(string suffix)
    {
        var badModel = new JsonArray(new JsonObject { ["model_id"] = "model" + suffix, ["can_do_text_to_speech"] = true }).ToJsonString();
        var badLanguage = new JsonArray(new JsonObject { ["model_id"] = "speech", ["can_do_text_to_speech"] = true,
            ["languages"] = new JsonArray(new JsonObject { ["language_id"] = "en" + suffix }) }).ToJsonString();
        foreach (var models in new[] { badModel, badLanguage })
        {
            using var modelHandler = new VoiceHttp((_, _) => Task.FromResult(Json(200, models)));
            using var modelLab = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), modelHandler, ElevenLabsRegion.Default);
            Assert.Equal(VoiceLabErrorKind.MalformedResponse,
                (await Assert.ThrowsAsync<VoiceLabException>(() => modelLab.DiscoverModelsAsync(TestContext.Current.CancellationToken))).Kind);
        }
        var badVoice = new JsonObject { ["voices"] = new JsonArray(new JsonObject { ["voice_id"] = "voice" + suffix, ["name"] = "Bad", ["category"] = "premade" }), ["has_more"] = false }.ToJsonString();
        using var voiceHandler = new VoiceHttp((_, _) => Task.FromResult(Json(200, badVoice)));
        using var voiceLab = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), voiceHandler, ElevenLabsRegion.Default);
        Assert.Equal(VoiceLabErrorKind.MalformedResponse,
            (await Assert.ThrowsAsync<VoiceLabException>(() => voiceLab.DiscoverVoicesAsync(TestContext.Current.CancellationToken))).Kind);

        using var handler = new VoiceHttp((request, _) => Discovery(request));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        await service.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await service.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123" + suffix), "en")).Kind);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech" + suffix, VoiceLabVoiceChoice.Stock("stock123"), "en")).Kind);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en" + suffix)).Kind);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.PrepareDeletion("own123" + suffix, Policy("own123" + suffix))).Kind);
        Assert.DoesNotContain(handler.Calls, call => call.Method is "POST" or "DELETE");
    }

    [Fact]
    public async Task RewriteBindsEverySourceTimingAndUsesOneSelectedModel()
    {
        var root = Path.Combine(Path.GetTempPath(), "voxclip-rewrite-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "catalog")); Directory.CreateDirectory(Path.Combine(root, "prompts"));
        File.Copy(Path.Combine(Catalog().SharedRoot, "catalog", "llm-providers.json"), Path.Combine(root, "catalog", "llm-providers.json"));
        File.WriteAllText(Path.Combine(root, "prompts", "voice-rewrite.json"), "{\"schemaVersion\":1,\"system\":\"Return spoken words only.\",\"schemaName\":\"voice_rewrite_proposal\",\"schema\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"rewrite\"],\"properties\":{\"rewrite\":{\"type\":\"string\"}}},\"maxOutputTokens\":1024}");
        try
        {
            var service = new VoiceRewriteService(LlmCatalog.Load(root));
            var connector = new RewriteConnector();
            var source = new[] { Word(0, "Rough", 0, 0.5), Word(1, "passage", 0.6, 1.2) };
            var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.FullTake, source, "Improve it", "en");
            var prepared = await service.PrepareAsync(input, connector, "chosen", TestContext.Current.CancellationToken);
            Assert.Null(prepared.Estimate.Usd);
            var approval = service.Approve(prepared, true);
            var changed = input with { SourceWords = new[] { source[0] with { End = 0.51 }, source[1] } };
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync(changed, connector, "chosen", approval, TestContext.Current.CancellationToken))).Kind);
            var proposal = await service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken);
            Assert.Equal("Better passage", proposal.ProposedText); Assert.Equal(source, proposal.SourceWords);
            Assert.Equal(1, connector.Sends); Assert.Equal("chosen", proposal.Model);
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken))).Kind);
        }
        finally { Directory.Delete(root, true); }
    }

    private sealed class RewriteConnector : ILlmConnector
    {
        public ConnectorId Id => ConnectorId.OpenAI;
        public int Sends { get; private set; }
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) => Task.FromResult<ConnectorStatus>(new ConnectorStatus.Ready());
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>([new LlmModel("chosen", "Chosen", null, 32768, ModelSource.Discovered)]);
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) => Task.FromResult<int?>(32768);
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        { Sends++; Assert.Equal(LlmFeature.VoiceRewrite, request.Feature); return Task.FromResult(new RawCompletion("{\"rewrite\":\"Better passage\"}", null, model, new StopKind.Complete(), null, "provider-request")); }
    }

    [Theory]
    [InlineData(ConnectorId.OpenAI, 429)]
    [InlineData(ConnectorId.OpenAI, 500)]
    [InlineData(ConnectorId.Anthropic, 400)]
    public async Task RewriteHttpNeverRetriesOrOffersBetaFallback(ConnectorId id, int status)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Json(status,
            id == ConnectorId.Anthropic ? "{\"error\":{\"message\":\"unexpected anthropic-beta value\"}}" : "{\"error\":{\"message\":\"busy\"}}")));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(id, Catalog(), client, new MemoryKeys(), new Redactor(), (_, _) => throw new Exception("retry delay"));
        var model = id == ConnectorId.Anthropic ? "claude-opus-5-5" : "gpt-5.4";
        var request = Catalog().TestRequest(id) with { Feature = LlmFeature.VoiceRewrite };
        await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(request, model, TestContext.Current.CancellationToken));
        Assert.Single(handler.Requests);
        Assert.False(handler.Requests[0].Body!.ContainsKey("fallbacks"));
        Assert.False(handler.Requests[0].Headers.ContainsKey("anthropic-beta"));
    }
}
