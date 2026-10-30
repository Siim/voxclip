using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class VoiceLabFixtureTests
{
    private static JsonObject Contract()
    {
        var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "contract.json");
        Assert.True(File.Exists(path), "The canonical shared Voice Lab contract is required.");
        var root = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Assert.Equal(1, root["version"]!.GetValue<int>());
        return root;
    }
    private static IEnumerable<JsonNode> Rows(string table) => Contract()[table]!.AsArray().Select(row => row!);
    private static string Text(JsonNode row, string key) => row[key]!.GetValue<string>();
    private static bool Flag(JsonNode row, string key) => row[key]?.GetValue<bool>() == true;
    private static OwnVoicePolicy Policy(string? voice = "own123", bool active = true, string record = "record-1") =>
        new(record, voice, active, true, true, true, true);
    private const string Models = "[{\"model_id\":\"speech\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"},{\"language_id\":\"et\"}]},{\"model_id\":\"other_model\",\"can_do_voice_conversion\":true,\"languages\":[{\"language_id\":\"en\"},{\"language_id\":\"et\"}]},{\"model_id\":\"changer\",\"can_do_voice_conversion\":true,\"languages\":[{\"language_id\":\"en\"},{\"language_id\":\"et\"}]},{\"model_id\":\"eleven_multilingual_v2\",\"can_do_text_to_speech\":true,\"languages\":[{\"language_id\":\"en\"}]}]";
    private const string Voices = "{\"voices\":[{\"voice_id\":\"own123\",\"name\":\"Mine\",\"category\":\"cloned\",\"is_owner\":true,\"voice_verification\":{\"requires_verification\":true,\"is_verified\":true}},{\"voice_id\":\"stock123\",\"name\":\"Stock\",\"category\":\"premade\"},{\"voice_id\":\"other_voice\",\"name\":\"Other\",\"category\":\"premade\"}],\"has_more\":false}";
    private const string Plan = "{\"tier\":\"starter\",\"status\":\"active\",\"character_count\":0,\"character_limit\":10000,\"can_use_instant_voice_cloning\":true,\"voice_slots_used\":0,\"voice_limit\":10}";
    private static HttpResponseMessage Json(int code, string body) => new((HttpStatusCode)code) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private static HttpResponseMessage Audio(byte[] data, string mime = "application/octet-stream") => new(HttpStatusCode.OK)
    { Content = new ByteArrayContent(data) { Headers = { ContentType = new(mime) } } };
    private static HttpResponseMessage Discovery(HttpRequestMessage request) => request.RequestUri!.AbsolutePath switch
    {
        "/v1/models" => Json(200, Models), "/v2/voices" => Json(200, Voices),
        "/v1/user/subscription" => Json(200, Plan), _ => Json(404, "{}")
    };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        internal int PaidSends;
        internal int AllSends;
        internal byte[]? LastBody;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Interlocked.Increment(ref AllSends);
            if (request.Method == HttpMethod.Post || request.Method == HttpMethod.Delete)
            {
                Interlocked.Increment(ref PaidSends);
                LastBody = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct);
            }
            var reply = await respond(request);
            reply.RequestMessage = request;
            return reply;
        }
    }
    private static async Task Discover(ElevenLabsVoiceLab service)
    {
        await service.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await service.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
    }
    private static byte[] Pcm() => new byte[2400];
    private static byte[] Wav(int rate = 24000, int frames = 2400) => MakeWav(null, rate, frames);

    [Fact]
    public async Task RewriteMutationTableKeepsTimedSourceAndPreparationLocal()
    {
        var rows = Rows("rewriteMutations").ToArray();
        Assert.Equal(11, rows.Length);
        // 4.12 renders as "4.1" too, so this row shows that the quote binds the value, not only the prompt text.
        Assert.Equal(VoxClip.Core.Domain.Editing.EditingFormat.ToFixed1(4.1), VoxClip.Core.Domain.Editing.EditingFormat.ToFixed1(4.12));
        foreach (var row in rows)
        {
            var field = Text(row, "field");
            var service = new VoiceRewriteService(Catalog());
            var connector = new RewriteStub(ConnectorId.OpenAI);
            var words = new[] { Word(0, "Rough", 0, 0.5), Word(1, "passage", 0.6, 1.2) };
            var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.FullTake, words, "Improve it", "en", 4.1, 10, 12);
            var prepared = await service.PrepareAsync(input, connector, "chosen", TestContext.Current.CancellationToken);
            Assert.Equal(0, connector.DiscoveryCalls);
            Assert.Equal("openai", prepared.Review.Provider);
            Assert.Equal("chosen", prepared.Review.ModelId);
            Assert.Equal(input.RequestId, prepared.Review.RequestId);
            var approval = service.Approve(prepared, true);
            var modified = field switch
            {
                "scope" => input with { Scope = VoiceRewriteScope.Passage },
                "sourceText" => input with { SourceWords = [words[0] with { Text = "Changed" }, words[1]] },
                "sourceTiming" => input with { SourceWords = [words[0] with { End = 0.51 }, words[1]] },
                "instruction" => input with { Instruction = "Another instruction" },
                "language" => input with { Language = "et" },
                "targetSeconds" => input with { TargetSeconds = 4.12 },
                "minChars" => input with { MinChars = 11 },
                "maxChars" => input with { MaxChars = 13 },
                _ => input
            };
            var selected = field == "connector" ? new RewriteStub(ConnectorId.Anthropic) : connector;
            var model = field == "model" ? "other_model" : "chosen";
            if (Flag(row, "allowed"))
            {
                var proposal = await service.ProposeAsync(modified, selected, model, approval, TestContext.Current.CancellationToken);
                Assert.Equal("Better passage", proposal.ProposedText);
                Assert.Equal(words, proposal.SourceWords);
                Assert.Contains("SOURCE TRANSCRIPT (fullTake, en):", connector.LastRequest!.CachedBlock);
            }
            else Assert.Equal(VoiceLabErrorKind.ConsentRequired,
                (await Assert.ThrowsAsync<VoiceLabException>(() => service.ProposeAsync(modified, selected, model, approval, TestContext.Current.CancellationToken))).Kind);
            Assert.Equal(Flag(row, "allowed") ? 1 : 0, connector.Sends + (selected == connector ? 0 : selected.Sends));
        }
    }
    private sealed class RewriteStub(ConnectorId id, string? raw = null, Exception? failure = null) : ILlmConnector
    {
        public ConnectorId Id => id;
        public int DiscoveryCalls;
        public int Sends;
        public LlmRequest? LastRequest;
        public ConnectorStatus Status = new ConnectorStatus.Ready();
        public IReadOnlyList<LlmModel> Models = [new LlmModel("chosen", "Chosen", null, 32768, ModelSource.Discovered)];
        public int? Context = 32768;
        public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); DiscoveryCalls++; return Task.FromResult(Status); }
        public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct)
        { ct.ThrowIfCancellationRequested(); Assert.False(refresh); DiscoveryCalls++; return Task.FromResult(Models); }
        public Task<int?> GetContextTokensAsync(string model, CancellationToken ct)
        { ct.ThrowIfCancellationRequested(); Assert.Equal("chosen", model); DiscoveryCalls++; return Task.FromResult(Context); }
        public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
        {
            Sends++; LastRequest = request;
            if (failure is not null) throw failure;
            return Task.FromResult(new RawCompletion(raw ?? "{\"rewrite\":\"Better passage\"}", null, model, new StopKind.Complete(), null, "synthetic-request"));
        }
    }

    /// <summary><c>\A…\z</c>, not <c>^…$</c>: .NET lets <c>$</c> match before a final line break, which would put "en\n" into the prompt.</summary>
    [Theory]
    [InlineData("en\n")]
    [InlineData("en\r\n")]
    [InlineData("en ")]
    public async Task RewriteLanguageRejectsTrailingLineBreaksAndSpaces(string language)
    {
        var service = new VoiceRewriteService(Catalog());
        var connector = new RewriteStub(ConnectorId.OpenAI);
        var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "Hello", 0, 0.5)], "Improve it", language, 4.1, 10, 12);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.PrepareAsync(input, connector, "chosen", TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(0, connector.Sends);
    }

    [Fact]
    public async Task RewritePreflightPreservesApprovalUntilOneValidDispatch()
    {
        var service = new VoiceRewriteService(Catalog());
        var connector = new RewriteStub(ConnectorId.OpenAI);
        var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "Hello", 0, 0.5)], "Improve it", "en", 4.1, 10, 12);
        var approval = service.Approve(await service.PrepareAsync(input, connector, "chosen", TestContext.Current.CancellationToken), true);
        Assert.Equal(0, connector.DiscoveryCalls);

        var changed = input with { Instruction = "Change the instruction" };
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.ProposeAsync(changed, connector, "chosen", approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(0, connector.DiscoveryCalls);
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.ProposeAsync(input, connector, "chosen", approval, cancelled.Token));
        }
        Assert.Equal(0, connector.DiscoveryCalls);

        connector.Status = new ConnectorStatus.Unavailable("test-only unavailable");
        Assert.Equal(LlmErrorKind.Unavailable, (await Assert.ThrowsAsync<LlmException>(() =>
            service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken))).Error.Kind);
        connector.Status = new ConnectorStatus.Ready();
        connector.Models = [];
        Assert.Equal(LlmErrorKind.ModelNotFound, (await Assert.ThrowsAsync<LlmException>(() =>
            service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken))).Error.Kind);
        connector.Models = [new LlmModel("chosen", "Chosen", null, 32768, ModelSource.Discovered)];
        connector.Context = 512;
        Assert.Equal(LlmErrorKind.ContextTooLong, (await Assert.ThrowsAsync<LlmException>(() =>
            service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken))).Error.Kind);
        Assert.Equal(0, connector.Sends);

        connector.Context = 32768;
        var proposal = await service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken);
        Assert.Equal("Better passage", proposal.ProposedText);
        Assert.Equal(1, connector.Sends);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(1, connector.Sends);
    }

    [Fact]
    public async Task RewriteUnknownContextUsesCloudFallbackAndOutputCap()
    {
        var connector = new RewriteStub(ConnectorId.OpenAI) { Context = null,
            Models = [new LlmModel("chosen", "Chosen", null, null, ModelSource.Custom)] };
        var service = new VoiceRewriteService(Catalog());
        var longInput = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.FullTake,
            [Word(0, string.Join(' ', Enumerable.Repeat("word", 900)), 0, 1)], "Improve it", "en", 4.1, 10, 12);
        var approval = service.Approve(await service.PrepareAsync(longInput, connector, "chosen", TestContext.Current.CancellationToken), true);
        await service.ProposeAsync(longInput, connector, "chosen", approval, TestContext.Current.CancellationToken);
        Assert.Equal(1, connector.Sends);

        var capped = Catalog();
        capped.Provider(ConnectorId.OpenAI)["maxOutputTokensCap"] = 512;
        var cappedService = new VoiceRewriteService(capped);
        var tooLong = longInput with { RequestId = Guid.NewGuid() };
        Assert.Equal(LlmErrorKind.ContextTooLong, (await Assert.ThrowsAsync<LlmException>(() =>
            cappedService.PrepareAsync(tooLong, connector, "chosen", TestContext.Current.CancellationToken))).Error.Kind);
        Assert.Equal(1, connector.Sends);
    }

    [Fact]
    public async Task RewriteInvalidReplyAndNetworkLossConsumeApproval()
    {
        foreach (var connector in new[]
        {
            new RewriteStub(ConnectorId.OpenAI, raw: "not-json"),
            new RewriteStub(ConnectorId.OpenAI, failure: new HttpRequestException("synthetic loss"))
        })
        {
            var service = new VoiceRewriteService(Catalog());
            var input = new VoiceRewriteRequest(Guid.NewGuid(), VoiceRewriteScope.Passage, [Word(0, "Hello", 0, 0.5)], "Improve it", "en", 4.1, 10, 12);
            var approval = service.Approve(await service.PrepareAsync(input, connector, "chosen", TestContext.Current.CancellationToken), true);
            await Assert.ThrowsAnyAsync<Exception>(() => service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken));
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() =>
                service.ProposeAsync(input, connector, "chosen", approval, TestContext.Current.CancellationToken))).Kind);
            Assert.Equal(1, connector.Sends);
        }
    }

    [Fact]
    public async Task LanguageModesAndCloneFieldsMatchOutboundRequests()
    {
        using var handler = new Handler(request => Task.FromResult(request.Method == HttpMethod.Post ?
            request.RequestUri!.AbsolutePath.StartsWith("/v1/text-to-speech/", StringComparison.Ordinal) ? Json(200, TtsReply("Hi")) :
            request.RequestUri.AbsolutePath == "/v1/voices/add" ? Json(200, "{\"voice_id\":\"created123\",\"requires_verification\":false}") : Audio(Pcm()) : Discovery(request)));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        var request = VoiceLabTestCalls.CloneRequest(" Voice ä ");
        var consentSha256 = Convert.ToHexStringLower(SHA256.HashData(request.Samples[0].Wav));
        var before = handler.AllSends;
        var clone = service.PrepareClone(request, Policy(null));
        Assert.Equal(before, handler.AllSends);
        Assert.Equal("Voice ä", clone.Review.DisplayName);
        Assert.Equal("audio/wav", clone.Review.MimeType);
        Assert.Equal(consentSha256, clone.Review.ContentSha256);
        await service.DiscoverSubscriptionAsync(TestContext.Current.CancellationToken);
        var result = await service.CreateOwnCloneAsync(request, Policy(null), service.Approve(clone, true), TestContext.Current.CancellationToken);
        Assert.Equal("created123", result.VoiceId);
        var multipart = Encoding.UTF8.GetString(handler.LastBody!);
        Assert.Contains("name=\"name\"", multipart);
        Assert.Contains("\r\n\r\nVoice ä (VoxClip)\r\n", multipart);
        Assert.Contains("name=\"files\"; filename=\"consent-statement.wav\"", multipart);
        Assert.Contains("name=\"files\"; filename=\"sample-02.wav\"", multipart);
        Assert.Contains("\r\n\r\nVoxClip own-voice clone. Consent sha256:" + consentSha256 + ". Created 2026-10-26T09:15:42Z.\r\n", multipart);
        Assert.Contains("\r\n\r\n{\"language\":\"en\"}\r\n", multipart);
        Assert.DoesNotContain("filename*", multipart);
        Assert.DoesNotContain("text/plain", multipart);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.PrepareClone(request with
            { Samples = [request.Samples[0], new(VoiceLabCloneSampleRole.Training, Encoding.ASCII.GetBytes("synthetic-audio/mp4"))] }, Policy(null))).Kind);

        await Discover(service);
        foreach (var (model, mode, hasCode) in new[]
        {
            ("speech", VoiceLabLanguageModeKind.Explicit, true),
            ("eleven_multilingual_v2", VoiceLabLanguageModeKind.AutoDetected, false)
        })
        {
            var quote = service.PrepareSynthesis("Hi", model, VoiceLabVoiceChoice.Stock("stock123"), "en");
            Assert.Equal(mode, quote.Review.LanguageMode!.Kind);
            await service.SynthesizeAsync("Hi", model, VoiceLabVoiceChoice.Stock("stock123"), "en", service.Approve(quote, true), TestContext.Current.CancellationToken);
            Assert.Equal(hasCode, JsonNode.Parse(handler.LastBody!)!["language_code"] is not null);
        }
        var wav = Wav();
        var conversion = service.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en");
        Assert.Equal(VoiceLabLanguageModeKind.AutoDetected, conversion.Review.LanguageMode!.Kind);
        await service.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", service.Approve(conversion, true), TestContext.Current.CancellationToken);
        Assert.DoesNotContain("language_code", Encoding.UTF8.GetString(handler.LastBody!));
    }

    [Fact]
    public async Task DeclaredMediaTypesRequireAnExactAllowedType()
    {
        using var handler = new Handler(request => Task.FromResult(request.Method != HttpMethod.Post ? Discovery(request) :
            request.RequestUri!.AbsolutePath.StartsWith("/v1/text-to-speech/", StringComparison.Ordinal) ?
                new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(TtsReply("Hi"), Encoding.UTF8, "application/x-json") } :
                Audio(Pcm(), "application/x-octet-stream")));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        await Discover(service);
        var synth = service.Approve(service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
        Assert.Equal(VoiceLabErrorKind.InvalidAudio, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.SynthesizeAsync("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en", synth, TestContext.Current.CancellationToken))).Kind);
        var wav = Wav();
        var convert = service.Approve(service.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
        Assert.Equal(VoiceLabErrorKind.InvalidAudio, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", convert, TestContext.Current.CancellationToken))).Kind);
        Assert.Equal(2, handler.PaidSends);
    }

    [Fact]
    public async Task CallerRequestIdentityIsPartOfTheSingleUseQuote()
    {
        using var handler = new Handler(request => Task.FromResult(request.Method == HttpMethod.Post ? Audio(Pcm()) : Discovery(request)));
        using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
        await Discover(service);
        var wav = Wav();
        var selected = VoiceLabVoiceChoice.Stock("stock123");
        var callerId = Guid.NewGuid();
        var prepared = service.PrepareConversion(wav, "changer", selected, "en", 7, false, callerId);
        var approval = service.Approve(prepared, true);
        Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() =>
            service.ConvertAsync(wav, "changer", selected, "en", 7, false, approval, TestContext.Current.CancellationToken, Guid.NewGuid()))).Kind);
        Assert.Equal(0, handler.PaidSends);
        var result = await service.ConvertAsync(wav, "changer", selected, "en", 7, false, approval, TestContext.Current.CancellationToken, callerId);
        Assert.Equal(callerId, result.Receipt.ActionId);
        Assert.Equal(1, handler.PaidSends);
    }

    [Fact]
    public async Task VoiceChoiceTableBlocksUnsafeCategoriesBeforeDispatch()
    {
        var rows = Rows("voiceChoices").ToArray();
        Assert.Equal(10, rows.Length);
        foreach (var row in rows)
        {
            var category = Text(row, "category");
            var owner = Flag(row, "owner");
            var choice = Text(row, "choice");
            var verified = choice != "own_unverified";
            var voiceJson = new JsonObject
            {
                ["voices"] = new JsonArray(new JsonObject { ["voice_id"] = "own123", ["name"] = "Selected", ["category"] = category,
                    ["is_owner"] = owner, ["voice_verification"] = new JsonObject { ["requires_verification"] = choice.StartsWith("own", StringComparison.Ordinal), ["is_verified"] = verified } }),
                ["has_more"] = false
            }.ToJsonString();
            using var handler = new Handler(request => Task.FromResult(request.RequestUri!.AbsolutePath == "/v2/voices" ? Json(200, voiceJson) : Discovery(request)));
            using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
            await Discover(service);
            var selected = choice == "stock" ? VoiceLabVoiceChoice.Stock("own123") : VoiceLabVoiceChoice.Own("own123", Policy(active: choice != "own_inactive"));
            if (Flag(row, "allowed")) Assert.Equal("own123", service.PrepareSynthesis("Hi", "speech", selected, "en").Review.VoiceId);
            else Assert.Throws<VoiceLabException>(() => service.PrepareSynthesis("Hi", "speech", selected, "en"));
            Assert.Equal(0, handler.PaidSends);
        }
    }

    [Fact]
    public async Task QuoteMutationTableBindsInputsEstimateAndDestination()
    {
        var rows = Rows("quoteMutations").ToArray();
        Assert.Equal(9, rows.Length);
        foreach (var row in rows)
        {
            var field = Text(row, "field");
            using var handler = new Handler(request => Task.FromResult(request.Method == HttpMethod.Post ?
                request.RequestUri!.AbsolutePath.StartsWith("/v1/text-to-speech/", StringComparison.Ordinal) ?
                    Json(200, TtsReply("Hi")) : Audio(Pcm()) : Discovery(request)));
            using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Eu);
            await Discover(service);
            var requestId = Guid.NewGuid();
            var wav = Wav();
            var own = VoiceLabVoiceChoice.Own("own123", Policy());
            var prepared = field == "text" ? service.PrepareSynthesis("Hi", "speech", own, "en", VoiceLabTestCalls.Speech, requestId) :
                service.PrepareConversion(wav, "changer", own, "en", 7, false, requestId);
            Assert.Equal(requestId, prepared.Review.RequestId);
            Assert.Equal("elevenlabs", prepared.Review.Provider);
            Assert.Equal(ElevenLabsRegion.Eu, prepared.Review.Region);
            Assert.NotNull(prepared.Review.ContentSha256);
            Assert.True(prepared.Review.ConsentPolicy!.RecordActive);
            Assert.Equal("record-1", prepared.Review.ConsentRecordId);
            var approval = service.Approve(prepared, true);
            if (field == "estimate") approval = new(approval.Token, approval.Fingerprint, approval.Estimate with { Units = approval.Estimate.Units + 1 }, approval.Review);
            var changed = wav.ToArray(); changed[^1] = 1;
            async Task Send() => _ = field switch
            {
                "text" => await service.SynthesizeAsync("Changed words", "speech", own, "en", VoiceLabTestCalls.Speech, approval, TestContext.Current.CancellationToken, requestId),
                "region" => await OtherRegionSend(),
                _ => await service.ConvertAsync(field == "audioByte" ? changed : wav,
                    field == "model" ? "other_model" : "changer",
                    field == "voice" ? VoiceLabVoiceChoice.Stock("other_voice") :
                    field == "consentRecord" ? VoiceLabVoiceChoice.Own("own123", Policy(record: "other_record")) : own,
                    field == "language" ? "et" : "en", 7, false, approval, TestContext.Current.CancellationToken, requestId)
            };
            async Task<VoiceLabAudioResult> OtherRegionSend()
            {
                using var other = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Us);
                await Discover(other);
                return await other.ConvertAsync(wav, "changer", own, "en", 7, false, approval, TestContext.Current.CancellationToken, requestId);
            }
            if (Flag(row, "allowed")) await Send();
            else await Assert.ThrowsAnyAsync<Exception>(Send);
            Assert.Equal(Flag(row, "allowed") ? 1 : 0, handler.PaidSends);
        }
    }

    [Fact]
    public async Task ReplayTableCountsBillableSendsAcrossAmbiguousOutcomes()
    {
        var rows = Rows("replay").ToArray();
        Assert.Equal(7, rows.Length);
        foreach (var row in rows)
        {
            var eventName = Text(row, "event");
            var attempts = 0;
            using var handler = new Handler(request =>
            {
                if (request.Method != HttpMethod.Post) return Task.FromResult(Discovery(request));
                var attempt = Interlocked.Increment(ref attempts);
                if (eventName.StartsWith("429", StringComparison.Ordinal)) return Task.FromResult(Json(429, "busy"));
                if (eventName.StartsWith("network", StringComparison.Ordinal)) throw new HttpRequestException("synthetic loss");
                if (eventName == "new_quote_after_failure" && attempt == 1) return Task.FromResult(Json(429, "busy"));
                return Task.FromResult(eventName.StartsWith("invalid", StringComparison.Ordinal) ? Audio([0]) : Audio(Pcm()));
            });
            using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
            await Discover(service);
            var wav = Wav();
            var voice = VoiceLabVoiceChoice.Stock("stock123");
            var quote = service.Approve(service.PrepareConversion(wav, "changer", voice, "en"), true);
            Task Send() => service.ConvertAsync(wav, "changer", voice, "en", quote, TestContext.Current.CancellationToken);
            if (eventName == "concurrent_duplicate")
            {
                var outcomes = await Task.WhenAll(Capture(Send()), Capture(Send()));
                Assert.Equal(1, outcomes.Count(error => error is VoiceLabException { Kind: VoiceLabErrorKind.ConsentRequired }));
            }
            else
            {
                var first = await Capture(Send());
                if (eventName == "new_quote_after_failure") Assert.Equal(VoiceLabErrorKind.RateLimited, Assert.IsType<VoiceLabException>(first).Kind);
                if (eventName != "first_send") Assert.IsType<VoiceLabException>(await Capture(Send()));
                if (eventName == "new_quote_after_failure")
                {
                    quote = service.Approve(service.PrepareConversion(wav, "changer", voice, "en"), true);
                    _ = await Capture(Send());
                }
            }
            Assert.Equal(row["billableSends"]!.GetValue<int>(), handler.PaidSends);
        }
    }
    private static async Task<Exception?> Capture(Task task) { try { await task; return null; } catch (Exception error) { return error; } }

    [Fact]
    public async Task DiscoveryTableRejectsDuplicateAndUnboundedPages()
    {
        var rows = Rows("discovery").ToArray();
        Assert.Equal(5, rows.Length);
        foreach (var row in rows)
        {
            var eventName = Text(row, "event");
            var page = 0;
            using var handler = new Handler(request =>
            {
                if (eventName == "duplicate_model_id") return Task.FromResult(Json(200, "[{\"model_id\":\"x\"},{\"model_id\":\"x\"}]"));
                page++;
                var voices = eventName switch
                {
                    "duplicate_voice_id_same_page" => "[{\"voice_id\":\"x\",\"name\":\"One\",\"category\":\"premade\"},{\"voice_id\":\"x\",\"name\":\"Two\",\"category\":\"premade\"}]",
                    "duplicate_voice_id_next_page" => "[{\"voice_id\":\"x\",\"name\":\"One\",\"category\":\"premade\"}]",
                    _ => "[]"
                };
                var cursor = eventName == "repeated_cursor" ? "same" : "page" + page;
                return Task.FromResult(Json(200, "{\"voices\":" + voices + ",\"has_more\":true,\"next_page_token\":\"" + cursor + "\"}"));
            });
            using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
            var error = eventName == "duplicate_model_id" ?
                await Assert.ThrowsAsync<VoiceLabException>(() => service.DiscoverModelsAsync(TestContext.Current.CancellationToken)) :
                await Assert.ThrowsAsync<VoiceLabException>(() => service.DiscoverVoicesAsync(TestContext.Current.CancellationToken));
            Assert.Equal(Text(row, "error") == "responseTooLarge" ? VoiceLabErrorKind.ResponseTooLarge : VoiceLabErrorKind.MalformedResponse, error.Kind);
            Assert.Equal(0, handler.PaidSends);
        }
    }

    [Fact]
    public async Task AudioTableClassifiesContainersAndRawHeaderLikeSamples()
    {
        var rows = Rows("audio").ToArray();
        Assert.Equal(8, rows.Length);
        foreach (var row in rows)
        {
            var format = Text(row, "format");
            var pcm = Pcm();
            var prefix = Convert.FromHexString(Text(row, "prefixHex"));
            prefix.CopyTo(pcm, 0);
            switch (format)
            {
                case "riff_wave_container": pcm = Wav(); break;
                case "id3_container": pcm[0] = (byte)'I'; pcm[1] = (byte)'D'; pcm[2] = (byte)'3'; pcm[3] = 3; break;
                case "two_mp3_frames": prefix.CopyTo(pcm, 417); break;
                case "mp4_container": BinaryWriteBigEndian(pcm, 24); break;
                case "odd_pcm_length": Array.Resize(ref pcm, 2401); break;
            }
            using var handler = new Handler(request => Task.FromResult(request.Method == HttpMethod.Post ? Json(200, TtsReply("Hi", pcm)) : Discovery(request)));
            using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
            await Discover(service);
            var quote = service.Approve(service.PrepareSynthesis("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en"), true);
            if (Flag(row, "valid")) Assert.Equal(pcm, (await service.SynthesizeAsync("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en", quote, TestContext.Current.CancellationToken)).Pcm);
            else Assert.Equal(VoiceLabErrorKind.InvalidAudio, (await Assert.ThrowsAsync<VoiceLabException>(() => service.SynthesizeAsync("Hi", "speech", VoiceLabVoiceChoice.Stock("stock123"), "en", quote, TestContext.Current.CancellationToken))).Kind);
            Assert.Equal(1, handler.PaidSends);
        }
    }
    private static void BinaryWriteBigEndian(byte[] bytes, int size) => System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(bytes, size);
    private static string TtsReply(string text, byte[]? pcm = null) => new JsonObject
    {
        ["audio_base64"] = Convert.ToBase64String(pcm ?? Pcm()),
        ["alignment"] = new JsonObject { ["characters"] = new JsonArray(text.Select(c => (JsonNode?)JsonValue.Create(c.ToString())).ToArray()),
            ["character_start_times_seconds"] = new JsonArray(text.Select((_, i) => (JsonNode?)JsonValue.Create(i * 0.01)).ToArray()),
            ["character_end_times_seconds"] = new JsonArray(text.Select((_, i) => (JsonNode?)JsonValue.Create((i + 1) * 0.01)).ToArray()) }
    }.ToJsonString();

    [Fact]
    public async Task ConversionInputTableChecksExactWavBytesAndBoundaries()
    {
        var rows = Rows("conversionInputs").ToArray();
        Assert.Equal(31, rows.Length);
        foreach (var row in rows)
        {
            var wav = MakeWav(row, row["rate"]?.GetValue<int>() ?? 24000, row["frames"]?.GetValue<int>() ?? 2400);
            using var handler = new Handler(request => Task.FromResult(request.Method == HttpMethod.Post ? Audio(Pcm()) : Discovery(request)));
            using var service = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(), handler, ElevenLabsRegion.Default);
            await Discover(service);
            VoiceLabPreparedAction? quote = null;
            if (Flag(row, "valid"))
            {
                quote = service.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en");
                Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(wav)), quote.Review.ContentSha256);
                var approval = service.Approve(quote, true);
                await service.ConvertAsync(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en", approval, TestContext.Current.CancellationToken);
                Assert.True(handler.LastBody!.AsSpan().IndexOf(wav) >= 0, Text(row, "case"));
            }
            else Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => service.PrepareConversion(wav, "changer", VoiceLabVoiceChoice.Stock("stock123"), "en")).Kind);
            Assert.Equal(Flag(row, "valid") ? 1 : 0, handler.PaidSends);
        }
    }

    private static byte[] MakeWav(JsonNode? row, int rate, int frames)
    {
        var mutation = row?["mutation"]?.GetValue<string>();
        var fmt = new byte[mutation == "fmt18" ? 18 : 16];
        BitConverter.TryWriteBytes(fmt.AsSpan(0), (short)(mutation == "floatFormat" ? 3 : 1));
        BitConverter.TryWriteBytes(fmt.AsSpan(2), (short)(mutation == "stereo" ? 2 : 1));
        BitConverter.TryWriteBytes(fmt.AsSpan(4), rate);
        BitConverter.TryWriteBytes(fmt.AsSpan(8), rate * 2 + (mutation == "badByteRate" ? 1 : 0));
        BitConverter.TryWriteBytes(fmt.AsSpan(12), (short)(mutation == "badAlign" ? 1 : 2));
        BitConverter.TryWriteBytes(fmt.AsSpan(14), (short)(mutation == "pcm8" ? 8 : 16));
        var data = new byte[checked(frames * 2 + (mutation == "oddPayload" ? 1 : 0))];
        var chunks = new List<(string Name, byte[] Payload)>();
        if (Flag(row ?? new JsonObject(), "ancillary")) chunks.Add(("JUNK", [1, 2, 3]));
        if (mutation == "dataBeforeFmt") chunks.Add(("data", data));
        if (mutation != "missingFmt") chunks.Add(("fmt ", fmt));
        if (Flag(row ?? new JsonObject(), "ancillary")) chunks.Add(("LIST", [4, 5]));
        if (mutation is not ("missingData" or "dataBeforeFmt")) chunks.Add(("data", data));
        if (mutation == "duplicateFmt") chunks.Add(("fmt ", fmt));
        if (mutation == "duplicateData") chunks.Add(("data", data));
        if (Flag(row ?? new JsonObject(), "ancillary")) chunks.Add(("cue ", [6]));
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream, Encoding.ASCII, true);
        writer.Write("RIFF"u8); writer.Write(0); writer.Write("WAVE"u8);
        foreach (var (name, payload) in chunks)
        {
            writer.Write(Encoding.ASCII.GetBytes(name)); writer.Write(payload.Length); writer.Write(payload);
            if ((payload.Length & 1) != 0) writer.Write((byte)0);
        }
        if (mutation == "missingPad") { writer.Write("JUNK"u8); writer.Write(1); writer.Write((byte)7); }
        var wav = stream.ToArray();
        BitConverter.TryWriteBytes(wav.AsSpan(4), wav.Length - 8);
        if (mutation == "riffShort") BitConverter.TryWriteBytes(wav.AsSpan(4), wav.Length - 9);
        if (mutation == "riffLong") BitConverter.TryWriteBytes(wav.AsSpan(4), wav.Length - 7);
        if (mutation == "truncateFile") Array.Resize(ref wav, wav.Length - 1);
        if (mutation == "overflowChunk") BitConverter.TryWriteBytes(wav.AsSpan(16), uint.MaxValue);
        if (mutation == "truncatedChunk")
        {
            var index = wav.AsSpan().IndexOf("data"u8);
            BitConverter.TryWriteBytes(wav.AsSpan(index + 4), data.Length + 2);
        }
        return wav;
    }
}
