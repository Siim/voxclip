using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

public sealed class VoiceLabDialogueTests
{
    private static JsonNode Cases() => JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/dialogue-cases.json"))!;
    private static CancellationToken Ct => TestContext.Current.CancellationToken;
    private static readonly VoiceLabVoiceChoice Voice = VoiceLabVoiceChoice.Stock("voice123");
    private sealed record Request(string Method, Uri Uri, string Key, string? ContentType, byte[] Body);
    private sealed class Handler(JsonNode root, JsonNode response, HttpStatusCode status = HttpStatusCode.OK) : HttpMessageHandler
    {
        internal readonly List<Request> Requests = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            JsonNode reply;
            var code = HttpStatusCode.OK;
            if (request.Method == HttpMethod.Get)
                reply = root["discovery"]![request.RequestUri!.AbsolutePath == "/v1/models" ? "models" : "voices"]!;
            else
            {
                Requests.Add(new(request.Method.Method, request.RequestUri!, request.Headers.GetValues("xi-api-key").Single(),
                    request.Content!.Headers.ContentType?.ToString(), await request.Content.ReadAsByteArrayAsync(ct)));
                reply = response;
                code = status;
            }
            return new(code) { RequestMessage = request, Content = new StringContent(reply.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
    private static ElevenLabsVoiceLab Client(Handler handler) => ElevenLabsVoiceLab.ForTesting(new MemoryKeys("synthetic-key"), handler, ElevenLabsRegion.Default);
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ScribeRequestsBindConditionalAudioEventsAndKeepOnlyWordRows(bool tagged)
    {
        var reply = JsonNode.Parse("""{"language_code":"en","words":[{"type":"word","text":"Hi","start":0.1,"end":0.2},{"type":"audio_event","text":"[laughs]","start":0.2,"end":0.4}]}""")!;
        using var handler = new Handler(Cases(), reply);
        using var client = ElevenLabsVoiceLab.ForTesting(new MemoryKeys("synthetic-key"), handler, ElevenLabsRegion.Default, boundary: "voxclip-tags-wire");
        var policy = new OwnVoicePolicy("record", "voice123", true, true, true, true, true);
        var prepared = client.PrepareQa("en", policy.RecordId, Guid.NewGuid(), tagged);
        var expectedFingerprint = VoiceLabActionGate.Fingerprint(ElevenLabsRegion.Default.ToString(), "scribe_v2", "en", policy.RecordId,
            VoiceLabTakeProcessing.MaximumQaSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (tagged) expectedFingerprint = VoiceLabActionGate.Fingerprint(expectedFingerprint, "tag_audio_events=true");
        Assert.Equal(VoiceLabActionGate.BoundFingerprint(expectedFingerprint, prepared.Estimate, prepared.Review), prepared.Fingerprint);
        var approval = client.Approve(prepared, true);
        await Assert.ThrowsAsync<VoiceLabException>(() => client.TranscribeQaAsync(new float[24000], 24000, "en", policy, approval, Ct, tagAudioEvents: !tagged));
        Assert.Empty(handler.Requests);
        var transcript = await client.TranscribeQaAsync(new float[24000], 24000, "en", policy, approval, Ct, tagAudioEvents: tagged);
        Assert.Equal("Hi", Assert.Single(transcript.Words).Text);
        var body = Encoding.UTF8.GetString(Assert.Single(handler.Requests).Body);
        Assert.Contains("name=\"tag_audio_events\"\r\n\r\n" + (tagged ? "true" : "false") + "\r\n", body);
        if (!tagged)
        {
            var untagged = client.PrepareQa("en", policy.RecordId, Guid.NewGuid());
            await client.TranscribeQaAsync(new float[24000], 24000, "en", policy, client.Approve(untagged, true), Ct);
            Assert.Equal(handler.Requests[0].Body, handler.Requests[1].Body);
        }
    }
    private static async Task Discover(ElevenLabsVoiceLab client)
    {
        await client.DiscoverModelsAsync(Ct);
        await client.DiscoverVoicesAsync(Ct);
    }
    [Fact]
    public async Task NormalizedFallbackPreservesBracketTimingsForEdgeExpressions()
    {
        var root = Cases();
        var response = root["responses"]![0]!["response"]!.DeepClone();
        response["audio_base64"] = Convert.ToBase64String(new byte[48000 * 3]);
        response["alignment"] = null;
        response["normalized_alignment"] = JsonNode.Parse("""{"characters":["[laughs]"," ","Hi"," ","[sighs]"],"character_start_times_seconds":[0.2,0.5,1,1.2,1.6],"character_end_times_seconds":[0.5,1,1.2,1.6,2.4]}""");
        response["voice_segments"]![0]!["character_end_index"] = 5;
        response["voice_segments"]![0]!["end_time_seconds"] = 2.4;
        using var handler = new Handler(root, response);
        using var client = Client(handler);
        await Discover(client);
        var result = await Speak(client, "[laughs] Hi [sighs]");
        var raw = Assert.IsAssignableFrom<IReadOnlyList<VoiceLabCharacterTiming>>(result.RawAlignment);
        var extended = VoiceLabAudioTags.ExtendEdges([new("Hi", 1, 1.2, true)], new float[24000 * 3], 24000,
            [new(0, "laughs"), new(1, "sighs")], 1, "eleven_v4", raw);
        Assert.Equal(.2, extended[0].Start);
        Assert.Equal(2.4, extended[0].End);
        Assert.Equal((.2 - VoiceLabPatchConstants.TTS_TRIM_LEAD, 2.4 + VoiceLabPatchConstants.TTS_TRIM_TAIL), VoiceLabAlignment.Trim(extended, 3));
    }
    private static Task<VoiceLabAudioResult> Speak(ElevenLabsVoiceLab client, string text = "Hi", string model = "eleven_v4",
        VoiceLabSpeechOptions? options = null, VoiceLabAuthorization? approval = null, Guid? requestId = null, VoiceLabRequestAcceptance? acceptance = null)
    {
        var id = requestId ?? Guid.NewGuid();
        options ??= new(0);
        return client.SynthesizeAsync(text, model, Voice, "en", options,
            approval ?? client.Approve(client.PrepareSynthesis(text, model, Voice, "en", options, id), true), Ct, id, acceptance);
    }
    [Fact]
    public void EverySharedCapabilityRouteIsReplayedAndDefaultStaysMultilingualV2()
    {
        var root = Cases();
        Assert.Equal(12, root["routes"]!.AsArray().Count);
        var models = new List<VoiceLabModel>();
        foreach (var row in root["routes"]!.AsArray())
        {
            var model = new VoiceLabModel(row!["modelId"]!.GetValue<string>(), "Account display name", ["en"],
                row["can_do_text_to_speech"]!.GetValue<bool>(), false, null, null);
            var expected = row["route"]?.GetValue<string>();
            Assert.Equal(expected is null ? null : Enum.Parse<VoiceLabSpeechRoute>(expected, true), model.SpeechRoute);
            Assert.Equal(expected is not null, model.SupportsTimestampedTts);
            models.Add(model);
        }
        var choices = models.Where(model => model.SupportsTimestampedTts).ToArray();
        Assert.Contains(choices, model => model.Id == "eleven_v4");
        Assert.DoesNotContain(choices, model => model.Id == "eleven_v4_turbo");
        Assert.Equal("eleven_multilingual_v2", VoiceLabModel.PatchDefault(models)?.Id);
        Assert.Equal("future_speech_model", VoiceLabModel.PatchDefault(models.Where(model => model.Id != "eleven_multilingual_v2").ToArray())?.Id);
        Assert.Equal("eleven_v4", VoiceLabModel.PatchDefault([models[0]])?.Id);
        Assert.Null(VoiceLabModel.PatchDefault([]));
    }
    [Fact]
    public void PatchDefaultPrefersV3OverDialogueWhenNeitherModelTakesContext()
    {
        var v4 = new VoiceLabModel("eleven_v4", "Dialogue", ["en"], true, false, null, null);
        var v3 = new VoiceLabModel("eleven_v3", "TTS", ["en"], true, false, null, null);
        Assert.Equal("eleven_v3", VoiceLabModel.PatchDefault([v4, v3])?.Id);
        Assert.Equal("eleven_v3", VoiceLabModel.PatchDefault([v3, v4])?.Id);
        Assert.Equal("eleven_v4", VoiceLabModel.PatchDefault([v4])?.Id);
    }
    [Theory]
    [InlineData("eleven_v4")]
    [InlineData("eleven_v3")]
    public async Task OwnVoiceQuoteCannotUseAnotherClonesConsent(string model)
    {
        var root = Cases();
        root["discovery"]!["voices"]!["voices"] = new JsonArray(new[] { "cloneA", "cloneB" }.Select(id => (JsonNode)new JsonObject
        { ["voice_id"] = id, ["name"] = id, ["category"] = "cloned", ["is_owner"] = true }).ToArray());
        using var handler = new Handler(root, root["responses"]![0]!["response"]!);
        using var client = Client(handler);
        await Discover(client);
        var first = new OwnVoicePolicy("recordA", "cloneA", true, true, true, true, true);
        var other = new OwnVoicePolicy("recordB", "cloneB", true, true, true, true, true);
        var id = Guid.NewGuid();
        var quote = client.PrepareSynthesis("Hi", model, VoiceLabVoiceChoice.Own("cloneA", first), "en", new(0), id);
        Assert.Equal("cloneA", quote.Review.VoiceId);
        Assert.Equal(first.RecordId, quote.Review.ConsentRecordId);
        var approval = client.Approve(quote, true);
        foreach (var voice in new[] { "cloneA", "cloneB" })
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() => client.SynthesizeAsync(
                "Hi", model, VoiceLabVoiceChoice.Own(voice, other), "en", new(0), approval, Ct, id))).Kind);
        Assert.Empty(handler.Requests);
    }
    [Fact]
    public async Task SharedDialogueRequestMatchesEveryByte()
    {
        var root = Cases();
        Assert.Equal("voxclip-voice-lab-dialogue-cases/1", root["schema"]!.GetValue<string>());
        Assert.Equal(1, root["version"]!.GetValue<int>());
        Assert.Single(root["requests"]!.AsArray());
        foreach (var row in root["requests"]!.AsArray())
        {
            var input = row!["input"]!;
            using var handler = new Handler(root, root["responses"]![0]!["response"]!);
            using var client = Client(handler);
            await Discover(client);
            var options = new VoiceLabSpeechOptions(input["seed"]!.GetValue<uint>(), input["previousText"]!.GetValue<string>(), input["nextText"]!.GetValue<string>());
            var quote = client.PrepareSynthesis("Hi", "eleven_v4", Voice, "en", options, Guid.NewGuid());
            Assert.Equal("/v1/text-to-dialogue/with-timestamps?output_format=pcm_24000", quote.Review.Endpoint);
            var result = await Speak(client, input["text"]!.GetValue<string>(), input["modelId"]!.GetValue<string>(), options);
            Assert.Equal("/v1/text-to-dialogue/with-timestamps", result.Receipt.Endpoint);
            var request = Assert.Single(handler.Requests);
            var expected = row["request"]!;
            Assert.Equal(expected["method"]!.GetValue<string>(), request.Method);
            Assert.Equal(expected["path"]!.GetValue<string>(), request.Uri.AbsolutePath);
            Assert.Equal("?output_format=" + expected["query"]!["output_format"]!.GetValue<string>(), request.Uri.Query);
            Assert.Equal("synthetic-key", request.Key);
            Assert.Equal(expected["headers"]!["content-type"]!.GetValue<string>(), request.ContentType);
            Assert.Equal(Encoding.UTF8.GetBytes(expected["bodyUTF8"]!.GetValue<string>()), request.Body);
            Assert.Equal(expected["bodyLength"]!.GetValue<int>(), request.Body.Length);
            Assert.Equal(expected["bodySha256"]!.GetValue<string>(), Convert.ToHexStringLower(SHA256.HashData(request.Body)));
            Assert.True(JsonNode.DeepEquals(expected["json"], JsonNode.Parse(request.Body)));
        }
    }
    public static IEnumerable<object[]> ResponseCases() => Cases()["responses"]!.AsArray().Select(row => new object[] { row!["case"]!.GetValue<string>() });
    [Theory]
    [MemberData(nameof(ResponseCases))]
    public async Task SharedDialogueResponses(string name)
    {
        var root = Cases();
        Assert.Equal(25, root["responses"]!.AsArray().Count);
        var row = root["responses"]!.AsArray().Single(row => row!["case"]!.GetValue<string>() == name)!;
        using var handler = new Handler(root, row["response"]!);
        using var client = Client(handler);
        await Discover(client);
        var text = row["text"]?.GetValue<string>() ?? root["responseInput"]!["text"]!.GetValue<string>();
        var expected = row["expected"]!.GetValue<string>();
        if (expected == "success" || name == "alignment_null")
        {
            var result = await Speak(client, text);
            Assert.Equal(text, string.Concat(result.Alignment!.Select(timing => timing.Character)));
            Assert.Equal(960, result.Pcm.Length);
        }
        else
            Assert.Equal(Enum.Parse<VoiceLabErrorKind>(expected, true), (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client, text))).Kind);
        Assert.Single(handler.Requests);
    }
    [Theory]
    [InlineData("eleven_v4", "segments_wrong_voice", VoiceLabErrorKind.MalformedResponse, true)]
    [InlineData("eleven_v3", "alignment_null", VoiceLabErrorKind.InvalidAlignment, true)]
    [InlineData("eleven_v4", "alignment_null", VoiceLabErrorKind.InvalidAudio, false)]
    [InlineData("eleven_v3", "alignment_null", VoiceLabErrorKind.InvalidAudio, false)]
    public async Task FailedSpeechSurfacesValidatedPcmWithoutTimestamps(string model, string name, VoiceLabErrorKind kind, bool validPcm)
    {
        var root = Cases();
        var response = root["responses"]!.AsArray().Single(row => row!["case"]!.GetValue<string>() == name)!["response"]!.DeepClone();
        if (!validPcm) response["audio_base64"] = Convert.ToBase64String(new byte[1]);
        using var handler = new Handler(root, response);
        using var client = Client(handler);
        await Discover(client);
        var acceptance = new VoiceLabRequestAcceptance();
        var id = Guid.NewGuid();
        Assert.Equal(kind, (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client, model: model, requestId: id, acceptance: acceptance))).Kind);
        Assert.True(acceptance.Accepted);
        Assert.Single(handler.Requests);
        if (!validPcm) { Assert.Null(acceptance.UnalignedAudio); return; }
        var raw = acceptance.UnalignedAudio;
        Assert.NotNull(raw);
        Assert.Null(raw.Alignment);
        Assert.Equal(Convert.FromBase64String(response["audio_base64"]!.GetValue<string>()), raw.Pcm);
        Assert.Equal(24000, raw.SampleRate);
        Assert.Equal(id, raw.Receipt.ActionId);
        Assert.Equal(model, raw.Receipt.ModelId);
        Assert.Equal("voice123", raw.Receipt.VoiceId);
    }
    [Fact]
    public async Task IncapableSpeechModelNeverReceivesBracketTags()
    {
        var root = Cases();
        using var handler = new Handler(root, root["responses"]![0]!["response"]!);
        using var client = Client(handler);
        await Discover(client);
        await Speak(client, "[laughs]Hi", "eleven_multilingual_v2");
        Assert.Equal("Hi", JsonNode.Parse(Assert.Single(handler.Requests).Body)!["text"]!.GetValue<string>().Trim());
    }
    [Theory]
    [InlineData("eleven_v3")]
    [InlineData("eleven_v4")]
    [InlineData("eleven_multilingual_v2")]
    public async Task TaggedSpeechQuotesAndSendsOnlyTheExactModelRequest(string model)
    {
        var root = Cases();
        var text = VoiceLabAudioTags.RequestText("Hi", [new(1, "laughs")], model);
        var response = root["responses"]![0]!["response"]!.DeepClone();
        response["alignment"] = new JsonObject
        {
            ["characters"] = new JsonArray(text.Select(character => (JsonNode)JsonValue.Create(character.ToString())!).ToArray()),
            ["character_start_times_seconds"] = new JsonArray(text.Select((_, index) => (JsonNode)JsonValue.Create(index * .0005)!).ToArray()),
            ["character_end_times_seconds"] = new JsonArray(text.Select((_, index) => (JsonNode)JsonValue.Create((index + 1) * .0005)!).ToArray())
        };
        using var handler = new Handler(root, response);
        using var client = Client(handler);
        await Discover(client);
        var id = Guid.NewGuid();
        var action = client.PrepareSynthesis(text, model, Voice, "en", new(0), id);
        Assert.Equal(text.Length, action.Estimate.Units);
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text))), action.Review.ContentSha256);
        var approval = client.Approve(action, true);
        if (model != "eleven_multilingual_v2")
        {
            Assert.Equal(VoiceLabErrorKind.ConsentRequired, (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client, "Hi", model, approval: approval, requestId: id))).Kind);
            Assert.Empty(handler.Requests);
        }
        await Speak(client, text, model, approval: approval, requestId: id);
        var sent = JsonNode.Parse(Assert.Single(handler.Requests).Body)!;
        Assert.Equal(text, (model == "eleven_v4" ? sent["inputs"]![0]!["text"] : sent["text"])!.GetValue<string>());
        Assert.Null(sent["previous_text"]);
        Assert.Null(sent["next_text"]);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SharedNormalizedFallbacksUseRawSegmentBoundsAndTypedWords(bool missingOriginal)
    {
        var vectors = JsonNode.Parse(FixtureLoader.ReadText("fixtures/voice-lab/audio-tag-cases.json"))!;
        foreach (var row in vectors["dialogueFallbacks"]!.AsArray())
        {
            var root = Cases();
            var response = root["responses"]![0]!["response"]!.DeepClone();
            response["normalized_alignment"] = row!["normalized_alignment"]!.DeepClone();
            if (missingOriginal) response.AsObject().Remove("alignment"); else response["alignment"] = null;
            response["voice_segments"]![0]!["character_end_index"] = row["segmentEnd"]!.DeepClone();
            using var handler = new Handler(root, response);
            using var client = Client(handler);
            await Discover(client);
            var result = await Speak(client, row["typed"]!.GetValue<string>());
            Assert.NotNull(result.RawAlignment);
            Assert.Equal(row["normalized_alignment"]!["characters"]!.AsArray().Select(value => value!.GetValue<string>()), result.RawAlignment.Select(time => time.Character));
            var alignment = Assert.IsAssignableFrom<IReadOnlyList<VoiceLabCharacterTiming>>(result.Alignment);
            var words = VoiceLabAlignment.Words(alignment.Select(time => time.Character).ToArray(), alignment.Select(time => time.Start).ToArray(),
                alignment.Select(time => time.End).ToArray(), row["typed"]!.GetValue<string>());
            Assert.Equal(row["expectedWords"]!.AsArray().Select(value => value!.GetValue<string>()), words.Select(word => word.Text));
        }
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NoTimingAndMalformedNonNullOriginalNeverGetRescued(bool malformedOriginal)
    {
        var root = Cases();
        var response = root["responses"]![0]!["response"]!.DeepClone();
        response["normalized_alignment"] = malformedOriginal ? response["alignment"]!.DeepClone() : null;
        response["alignment"] = malformedOriginal ? new JsonObject() : null;
        using var handler = new Handler(root, response);
        using var client = Client(handler);
        await Discover(client);
        Assert.Equal(VoiceLabErrorKind.InvalidAlignment, (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client))).Kind);
    }
    [Fact]
    public async Task SpeechAndDialogueQuotesCannotAuthorizeTheOtherRoute()
    {
        var root = Cases();
        using var handler = new Handler(root, root["responses"]![0]!["response"]!);
        using var client = Client(handler);
        await Discover(client);
        var endpoints = new List<string>();
        foreach (var (from, to) in new[] { ("eleven_v3", "eleven_v4"), ("eleven_v4", "eleven_v3") })
        {
            var id = Guid.NewGuid();
            var approval = client.Approve(client.PrepareSynthesis("Hi", from, Voice, "en", new(0), id), true);
            endpoints.Add(approval.Review.Endpoint);
            Assert.Equal(VoiceLabErrorKind.ConsentRequired,
                (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client, model: to, approval: approval, requestId: id))).Kind);
        }
        // The route itself is bound, not only the model id.
        Assert.StartsWith("/v1/text-to-speech/", endpoints[0], StringComparison.Ordinal);
        Assert.StartsWith("/v1/text-to-dialogue/with-timestamps?", endpoints[1], StringComparison.Ordinal);
        Assert.NotEqual(endpoints[0], endpoints[1]);
        Assert.Empty(handler.Requests);
    }
    [Fact]
    public async Task DialoguePermissionRefusalNamesTheSpeechPermission()
    {
        var root = Cases();
        using var handler = new Handler(root, JsonNode.Parse("{\"detail\":{\"code\":\"missing_permissions\"}}")!, HttpStatusCode.Forbidden);
        using var client = Client(handler);
        await Discover(client);
        var refusal = await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client));
        Assert.Equal(VoiceLabErrorKind.PermissionMissing, refusal.Kind);
        Assert.Equal("text_to_speech", refusal.Detail);
        Assert.Single(handler.Requests);
    }
    [Fact]
    public async Task DialogueOmitsAndDoesNotBindContext()
    {
        var root = Cases();
        using var handler = new Handler(root, root["responses"]![0]!["response"]!);
        using var client = Client(handler);
        await Discover(client);
        var id = Guid.NewGuid();
        var approval = client.Approve(client.PrepareSynthesis("Hi", "eleven_v4", Voice, "en", new(0, "old", "context"), id), true);
        await Speak(client, options: new(0, "changed", "after approval"), approval: approval, requestId: id);
        var body = JsonNode.Parse(Assert.Single(handler.Requests).Body)!;
        foreach (var field in new[] { "previous_text", "next_text", "future_text" }) Assert.Null(body[field]);
    }
    [Fact]
    public async Task DialogueLengthIsRefusedBeforeQuoteOrSend()
    {
        var root = Cases();
        using var handler = new Handler(root, root["responses"]![0]!["response"]!);
        using var client = Client(handler);
        await Discover(client);
        var longText = new string('a', 2001);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, Assert.Throws<VoiceLabException>(() => client.PrepareSynthesis(longText, "eleven_v4", Voice, "en", new(0), Guid.NewGuid())).Kind);
        var id = Guid.NewGuid();
        var approval = client.Approve(client.PrepareSynthesis("Hi", "eleven_v4", Voice, "en", new(0), id), true);
        Assert.Equal(VoiceLabErrorKind.InvalidInput, (await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client, longText, approval: approval, requestId: id))).Kind);
        client.PrepareSynthesis(new string('a', 2000), "eleven_v4", Voice, "en", new(0), Guid.NewGuid());
        Assert.Empty(handler.Requests);
    }
    [Theory]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.InternalServerError)]
    public async Task DialogueFailureNeverRetries(HttpStatusCode status)
    {
        var root = Cases();
        using var handler = new Handler(root, new JsonObject(), status);
        using var client = Client(handler);
        await Discover(client);
        await Assert.ThrowsAsync<VoiceLabException>(() => Speak(client));
        Assert.Single(handler.Requests);
    }
}
