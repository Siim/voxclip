using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.Speech;
using VoxClip.Core.Services.VoiceLab;
using VoxClip.Core.Tests.Tracks.WinAi;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.VoiceLab;

/// <summary>Consumes shared/fixtures/voice-lab/request-cases.json as its README describes.</summary>
[Trait("Track", "voice-lab")]
public sealed class VoiceLabRequestGoldenTests
{
    private const string Key = "synthetic-voice-lab-key";
    private static JsonObject Cases()
    {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureLoader.SharedRoot, "fixtures", "voice-lab", "request-cases.json")))!.AsObject();
        Assert.Equal("voxclip-voice-lab-requests/1", root["schema"]!.GetValue<string>());
        return root;
    }
    private static OwnVoicePolicy CreatePolicy => new("record-1", null, true, true, true, true, true);
    /// <summary>The lab uses the shared multipart boundary, so whole request bodies can be compared.</summary>
    private static string Boundary(JsonNode root) => root["multipartBoundary"]!.GetValue<string>();

    private sealed record PaidRequest(string Method, Uri Url, string? ApiKey, string? ContentType, byte[] Body);
    /// <summary>Serves the shared discovery replies, records each paid request, and answers it with a valid synthetic reply.</summary>
    private sealed class PaidRecorder(JsonNode discovery) : HttpMessageHandler
    {
        internal List<PaidRequest> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            HttpResponseMessage reply;
            if (request.Method == HttpMethod.Get)
                reply = Json(path switch { "/v1/models" => discovery["models"]!, "/v2/voices" => discovery["voices"]!, _ => discovery["subscription"]! });
            else
            {
                var body = request.Content is null ? [] : await request.Content.ReadAsByteArrayAsync(ct);
                Requests.Add(new(request.Method.Method, request.RequestUri, request.Headers.TryGetValues("xi-api-key", out var keys) ? keys.Single() : null,
                    request.Content?.Headers.ContentType?.ToString(), body));
                reply = path == "/v1/voices/add" ? Json(new JsonObject { ["voice_id"] = "created123", ["requires_verification"] = false }) :
                    path.StartsWith("/v1/voice-changer/", StringComparison.Ordinal)
                        ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[4800]) { Headers = { ContentType = new("application/octet-stream") } } }
                        : Json(new JsonObject
                        {
                            ["audio_base64"] = Convert.ToBase64String(new byte[4800]),
                            ["alignment"] = new JsonObject
                            {
                                ["characters"] = new JsonArray(JsonNode.Parse(body)!["text"]!.GetValue<string>()),
                                ["character_start_times_seconds"] = new JsonArray(0), ["character_end_times_seconds"] = new JsonArray(0.05)
                            }
                        });
            }
            reply.RequestMessage = request;
            return reply;
        }
        private static HttpResponseMessage Json(JsonNode node) =>
            new(HttpStatusCode.OK) { Content = new StringContent(node.ToJsonString(), Encoding.UTF8, "application/json") };
    }
    private static async Task Discover(ElevenLabsVoiceLab lab)
    {
        await lab.DiscoverModelsAsync(TestContext.Current.CancellationToken);
        await lab.DiscoverVoicesAsync(TestContext.Current.CancellationToken);
        await lab.DiscoverSubscriptionAsync(TestContext.Current.CancellationToken);
    }
    /// <summary>Runs each row and names the row in any failure.</summary>
    private static async Task ForEachRow(JsonArray rows, Func<JsonNode, Task> check)
    {
        foreach (var row in rows)
        {
            try { await check(row!); }
            catch (Exception error) { throw new InvalidOperationException(row!["case"]!.GetValue<string>() + ": " + error.Message, error); }
        }
    }

    private static byte[] Wav(JsonNode spec) => VoiceLabTestCalls.SyntheticWav(spec["rate"]!.GetValue<int>(), spec["frames"]!.GetValue<int>(),
        (short)(spec["fill"]?.GetValue<int>() ?? 0), spec["junkBytes"]?.GetValue<int>() ?? 0, (short)(spec["mutation"]?.GetValue<string>() == "stereo" ? 2 : 1));
    private static VoiceLabCloneRequest CloneRequest(JsonNode input, JsonNode defaults)
    {
        string Text(string key) => (input[key] ?? defaults[key])!.GetValue<string>();
        var samples = new List<VoiceLabCloneSample>();
        foreach (var spec in input["samples"]!.AsArray())
        {
            var role = spec!["role"]!.GetValue<string>() switch
            {
                "consentStatement" => VoiceLabCloneSampleRole.ConsentStatement, "training" => VoiceLabCloneSampleRole.Training,
                var other => throw new InvalidDataException(other)
            };
            var wav = Wav(spec);
            for (var i = 0; i < (spec["count"]?.GetValue<int>() ?? 1); i++) samples.Add(new(role, wav));
        }
        return new(Text("displayName"), Text("language"), samples,
            DateTimeOffset.Parse(Text("createdAt"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind),
            (input["removeBackgroundNoise"] ?? defaults["removeBackgroundNoise"])!.GetValue<bool>());
    }

    private abstract record Call;
    private sealed record CloneCall(VoiceLabCloneRequest Request) : Call;
    private sealed record SpeechCall(string Text, string Model, string Voice, string Language, VoiceLabSpeechOptions Options) : Call;
    private sealed record ConversionCall(byte[] Audio, string Model, string Voice, string Language, uint Seed, bool CleanAudioOn) : Call;
    /// <summary>Builds a call from a case input, with an optional quote mutation row applied.</summary>
    private static Call MakeCall(string operation, JsonNode source, JsonNode? mutation = null)
    {
        var input = source.DeepClone();
        var field = mutation?["field"]!.GetValue<string>() ?? "same";
        if (mutation?["value"] is { } value) input[field] = value.DeepClone();
        string Text(string key) => input[key]!.GetValue<string>();
        switch (operation)
        {
            case "createClone":
                if (mutation?["swap"] is { } swap)
                {
                    var samples = input["samples"]!.AsArray();
                    int first = swap[0]!.GetValue<int>(), second = swap[1]!.GetValue<int>();
                    if (field == "sampleOrder")
                    {
                        var item = samples[first]!.DeepClone();
                        samples[first] = samples[second]!.DeepClone();
                        samples[second] = item;
                    }
                    else
                    {
                        var role = samples[first]!["role"]!.GetValue<string>();
                        samples[first]!["role"] = samples[second]!["role"]!.GetValue<string>();
                        samples[second]!["role"] = role;
                    }
                }
                var request = CloneRequest(input, input);
                if (field == "sampleByte")
                {
                    var index = mutation!["index"]!.GetValue<int>();
                    var bytes = request.Samples[index].Wav.ToArray();
                    bytes[^1] ^= 1;
                    request = request with { Samples = request.Samples.Select((sample, position) => position == index ? sample with { Wav = bytes } : sample).ToArray() };
                }
                return new CloneCall(request);
            case "textToSpeech":
                return new SpeechCall(Text("text"), Text("modelId"), Text("voiceId"), Text("language"),
                    new(input["seed"]!.GetValue<uint>(), input["previousText"]?.GetValue<string>(), input["nextText"]?.GetValue<string>()));
            default:
                return new ConversionCall(Wav(input["audio"]!), Text("modelId"), Text("voiceId"), Text("language"),
                    input["seed"]!.GetValue<uint>(), input["cleanAudioOn"]!.GetValue<bool>());
        }
    }
    private static VoiceLabPreparedAction Prepare(ElevenLabsVoiceLab lab, Call call, Guid id) => call switch
    {
        CloneCall clone => lab.PrepareClone(clone.Request, CreatePolicy, id),
        SpeechCall speech => lab.PrepareSynthesis(speech.Text, speech.Model, VoiceLabVoiceChoice.Stock(speech.Voice), speech.Language, speech.Options, id),
        ConversionCall conversion => lab.PrepareConversion(conversion.Audio, conversion.Model, VoiceLabVoiceChoice.Stock(conversion.Voice), conversion.Language,
            conversion.Seed, conversion.CleanAudioOn, id),
        _ => throw new InvalidDataException(call.ToString())
    };
    private static Task Dispatch(ElevenLabsVoiceLab lab, Call call, VoiceLabAuthorization approval, Guid id) => call switch
    {
        CloneCall clone => lab.CreateOwnCloneAsync(clone.Request, CreatePolicy, approval, TestContext.Current.CancellationToken, id),
        SpeechCall speech => lab.SynthesizeAsync(speech.Text, speech.Model, VoiceLabVoiceChoice.Stock(speech.Voice), speech.Language, speech.Options,
            approval, TestContext.Current.CancellationToken, id),
        ConversionCall conversion => lab.ConvertAsync(conversion.Audio, conversion.Model, VoiceLabVoiceChoice.Stock(conversion.Voice), conversion.Language,
            conversion.Seed, conversion.CleanAudioOn, approval, TestContext.Current.CancellationToken, id),
        _ => throw new InvalidDataException(call.ToString())
    };

    private sealed record Part(string[] Headers, byte[] Body);
    /// <summary>Splits a multipart body at the given boundary; each part keeps its raw header lines in order.</summary>
    private static List<Part> Parts(byte[] body, string boundary)
    {
        var opening = Encoding.ASCII.GetBytes("--" + boundary + "\r\n");
        var delimiter = Encoding.ASCII.GetBytes("\r\n--" + boundary);
        var span = body.AsSpan();
        Assert.True(span.StartsWith(opening));
        var cursor = opening.Length;
        var parts = new List<Part>();
        while (true)
        {
            var end = span[cursor..].IndexOf(delimiter);
            Assert.True(end >= 0);
            var part = span.Slice(cursor, end);
            var split = part.IndexOf("\r\n\r\n"u8);
            parts.Add(new(Encoding.UTF8.GetString(part[..split]).Split("\r\n"), part[(split + 4)..].ToArray()));
            cursor += end + delimiter.Length;
            if (span[cursor..].StartsWith("--"u8)) return parts;
            cursor += 2;
        }
    }
    private static void Compare(PaidRequest paid, JsonNode expected, string boundary)
    {
        Assert.Equal(expected["method"]!.GetValue<string>(), paid.Method);
        Assert.Equal(expected["path"]!.GetValue<string>(), paid.Url.AbsolutePath);
        Assert.Equal(expected["query"]!.AsObject().ToDictionary(pair => pair.Key, pair => pair.Value!.GetValue<string>()),
            paid.Url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(pair => pair.Split('=', 2))
                .ToDictionary(pair => Uri.UnescapeDataString(pair[0]), pair => pair.Length > 1 ? Uri.UnescapeDataString(pair[1]) : ""));
        foreach (var (field, value) in expected["headers"]!.AsObject())
        {
            if (field == "xi-api-key") { Assert.Equal(Key, paid.ApiKey); Assert.Equal("[REDACTED]", value!.GetValue<string>()); }
            else Assert.Equal(value!.GetValue<string>(), paid.ContentType);
        }
        if (expected["json"] is { } json)
        {
            Assert.True(JsonNode.DeepEquals(json, JsonNode.Parse(paid.Body)), "JSON body differs: " + Encoding.UTF8.GetString(paid.Body));
            return;
        }
        // The whole body must match byte for byte; the parts show where a difference is.
        Assert.Equal(expected["bodyLength"]!.GetValue<int>(), paid.Body.Length);
        Assert.Equal(expected["bodySha256"]!.GetValue<string>(), Convert.ToHexStringLower(SHA256.HashData(paid.Body)));
        var parts = Parts(paid.Body, boundary);
        var wanted = expected["multipart"]!.AsArray();
        Assert.Equal(wanted.Count, parts.Count);
        for (var i = 0; i < parts.Count; i++)
        {
            var want = wanted[i]!;
            Assert.Equal(want["headers"]!.AsArray().Select(line => line!.GetValue<string>()), parts[i].Headers);
            if (want["value"] is { } text) Assert.Equal(Encoding.UTF8.GetBytes(text.GetValue<string>()), parts[i].Body);
            else Assert.Equal(want["sha256"]!.GetValue<string>(), Convert.ToHexStringLower(SHA256.HashData(parts[i].Body)));
        }
    }

    [Fact]
    public async Task RequestGoldensMatchSharedCases()
    {
        var root = Cases();
        var cases = root["cases"]!.AsArray();
        Assert.Equal(21, cases.Count);
        await ForEachRow(cases, async row =>
        {
            using var handler = new PaidRecorder(root["discovery"]!);
            using var lab = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(Key), handler, ElevenLabsRegion.Default, boundary: Boundary(root));
            await Discover(lab);
            var call = MakeCall(row["operation"]!.GetValue<string>(), row["input"]!);
            var id = Guid.NewGuid();
            await Dispatch(lab, call, lab.Approve(Prepare(lab, call, id), true), id);
            Compare(Assert.Single(handler.Requests), row["request"]!, Boundary(root));
        });
    }

    [Fact]
    public async Task QuoteMutationsBindNewFields()
    {
        var root = Cases();
        var rows = root["quoteMutations"]!.AsArray();
        Assert.Equal(18, rows.Count);
        await ForEachRow(rows, async row =>
        {
            var baseCase = root["cases"]!.AsArray().Single(item => item!["case"]!.GetValue<string>() == row["base"]!.GetValue<string>())!;
            var operation = baseCase["operation"]!.GetValue<string>();
            using var handler = new PaidRecorder(root["discovery"]!);
            using var lab = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(Key), handler, ElevenLabsRegion.Default, boundary: Boundary(root));
            await Discover(lab);
            var id = Guid.NewGuid();
            var approval = lab.Approve(Prepare(lab, MakeCall(operation, baseCase["input"]!), id), true);
            var send = Dispatch(lab, MakeCall(operation, baseCase["input"]!, row), approval, id);
            var refusal = row["error"]?.GetValue<string>() == "invalidInput" ? VoiceLabErrorKind.InvalidInput : VoiceLabErrorKind.ConsentRequired;
            if (row["allowed"]!.GetValue<bool>()) await send;
            else Assert.Equal(refusal, (await Assert.ThrowsAsync<VoiceLabException>(() => send)).Kind);
            Assert.Equal(row["allowed"]!.GetValue<bool>() ? 1 : 0, handler.Requests.Count);
        });
    }

    [Fact]
    public async Task CloneInputsFollowSharedTable()
    {
        var root = Cases();
        var rows = root["cloneInputs"]!.AsArray();
        Assert.Equal(42, rows.Count);
        using var handler = new PaidRecorder(root["discovery"]!);
        using var lab = ElevenLabsVoiceLab.ForTesting(new MemoryKeys(Key), handler, ElevenLabsRegion.Default, boundary: Boundary(root));
        await Discover(lab);
        await ForEachRow(rows, row =>
        {
            var error = Record.Exception(() => lab.PrepareClone(CloneRequest(row, root["cloneDefaults"]!), CreatePolicy, Guid.NewGuid()));
            Assert.True(row["valid"]!.GetValue<bool>() ? error is null : error is VoiceLabException { Kind: VoiceLabErrorKind.InvalidInput }, error?.ToString());
            return Task.CompletedTask;
        });
        Assert.Empty(handler.Requests);
    }

    /// <summary>Display names trim with string.Trim (char.IsWhiteSpace) and §8.5 context with Rune.IsWhiteSpace;
    /// both must be exactly the shared White_Space list.</summary>
    [Fact]
    public void WhiteSpaceMatchesSharedList()
    {
        var shared = Cases()["whiteSpace"]!.AsArray().Select(value => value!.GetValue<int>()).ToArray();
        Assert.Equal(25, shared.Length);
        Assert.Equal(shared, Enumerable.Range(0, 0x110000).Where(value => Rune.IsValid(value) && Rune.IsWhiteSpace(new Rune(value))));
        Assert.Equal(shared, Enumerable.Range(0, 0x10000).Where(value => char.IsWhiteSpace((char)value)));
    }

    /// <summary>Display names refuse char.IsControl, which must be General Category Cc: U+0000–U+001F and U+007F–U+009F.</summary>
    [Fact]
    public void ControlCharactersAreGeneralCategoryCc()
    {
        int[] control = [.. Enumerable.Range(0x00, 0x20), .. Enumerable.Range(0x7F, 0x21)];
        Assert.Equal(control, Enumerable.Range(0, 0x10000).Where(value => char.IsControl((char)value)));
        Assert.Equal(control, Enumerable.Range(0, 0x110000).Where(value => Rune.IsValid(value) && Rune.GetUnicodeCategory(new Rune(value)) == UnicodeCategory.Control));
    }
}
