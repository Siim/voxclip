using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class HttpConnectorTests
{
    [Theory]
    [InlineData(ConnectorId.Anthropic)]
    [InlineData(ConnectorId.OpenAI)]
    [InlineData(ConnectorId.Xai)]
    [InlineData(ConnectorId.Gemini)]
    [InlineData(ConnectorId.Ollama)]
    [InlineData(ConnectorId.LmStudio)]
    public async Task EveryConnectorMatchesItsCompleteGoldenRequest(ConnectorId id)
    {
        var catalog = Catalog();
        var model = catalog.Provider(id)["defaultModel"]?.GetValue<string>() ?? "local-test";
        using var handler = new StubHttp((request, _, _) => Task.FromResult(Response(200, request.RequestUri!.AbsolutePath == "/api/show" ? "{\"capabilities\":[\"completion\",\"thinking\"],\"model_info\":{\"test.context_length\":32768}}" : Completion(id))));
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        var keys = new MemoryKeys();
        var connector = new LlmConnector(id, catalog, client, keys, new Redactor());
        var canonical = Request(id);
        var result = await connector.SendAsync(canonical, model, TestContext.Current.CancellationToken);
        var sent = handler.Requests[^1];
        var schema = canonical.Schema.DeepClone();
        var escapedModel = JsonValue.Create(model)!.ToJsonString();
        var expected = JsonNode.Parse(id switch
        {
            ConnectorId.Anthropic => "{\"model\":" + escapedModel + ",\"max_tokens\":16000,\"system\":\"S\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"B\",\"cache_control\":{\"type\":\"ephemeral\"}},{\"type\":\"text\",\"text\":\"I\"}]}],\"output_config\":{\"effort\":\"medium\",\"format\":{\"type\":\"json_schema\",\"schema\":{}}},\"fallbacks\":\"default\"}",
            ConnectorId.OpenAI => "{\"model\":" + escapedModel + ",\"instructions\":\"S\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"B\"},{\"type\":\"input_text\",\"text\":\"I\"}]}],\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"connection_test\",\"strict\":true,\"schema\":{}}},\"max_output_tokens\":16000,\"reasoning\":{\"effort\":\"medium\"},\"store\":false,\"prompt_cache_key\":\"placeholder\"}",
            ConnectorId.Gemini => "{\"systemInstruction\":{\"parts\":[{\"text\":\"S\"}]},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"B\"},{\"text\":\"I\"}]}],\"generationConfig\":{\"maxOutputTokens\":16000,\"responseMimeType\":\"application/json\",\"responseJsonSchema\":{}}}",
            ConnectorId.Ollama => "{\"model\":" + escapedModel + ",\"stream\":false,\"messages\":[{\"role\":\"system\",\"content\":\"S\"},{\"role\":\"user\",\"content\":\"B\\n\\nI\"}],\"format\":{},\"options\":{\"num_ctx\":8192,\"num_predict\":4096,\"temperature\":0},\"think\":false,\"keep_alive\":\"10m\"}",
            _ => "{\"model\":" + escapedModel + ",\"messages\":[{\"role\":\"system\",\"content\":\"S\"},{\"role\":\"user\",\"content\":\"B\\n\\nI\"}],\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"connection_test\",\"strict\":true,\"schema\":{}}}}"
        })!.AsObject();
        switch (id)
        {
            case ConnectorId.Anthropic: expected["output_config"]!["format"]!["schema"] = schema; Assert.Equal("2026-10-21", sent.Headers["anthropic-version"]); Assert.Equal("server-side-fallback-2026-07-01", sent.Headers["anthropic-beta"]); break;
            case ConnectorId.OpenAI: expected["text"]!["format"]!["schema"] = schema; expected["prompt_cache_key"] = "voxclip-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("B")))[..16]; break;
            case ConnectorId.Gemini: expected["generationConfig"]!["responseJsonSchema"] = schema; Assert.Equal("test-placeholder-value", sent.Headers["x-goog-api-key"]); Assert.DoesNotContain("key=", sent.Url, StringComparison.OrdinalIgnoreCase); break;
            case ConnectorId.Ollama: expected["format"] = schema; break;
            default: expected["response_format"]!["json_schema"]!["schema"] = schema; expected[id == ConnectorId.Xai ? "max_completion_tokens" : "max_tokens"] = id == ConnectorId.Xai ? 16000 : 4096; if (id == ConnectorId.LmStudio) expected["temperature"] = 0; break;
        }
        EqualJson(expected, sent.Body);
        Assert.IsType<StopKind.Complete>(result.Stop);
        Assert.DoesNotContain("hidden", result.Text ?? "");
        if (id is ConnectorId.Ollama or ConnectorId.LmStudio) Assert.Empty(keys.Accounts); else Assert.All(keys.Accounts, account => Assert.Equal("llm-api-key-" + LlmCatalog.WireId(id), account));
    }

    [Fact]
    public async Task TestRequestsOmitCacheAndUnsupportedEffort()
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, Completion(ConnectorId.OpenAI))));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor());
        await connector.SendAsync(Catalog().TestRequest(ConnectorId.OpenAI), "custom-chat", TestContext.Current.CancellationToken);
        var body = handler.Requests[0].Body!;
        Assert.False(body.ContainsKey("reasoning")); Assert.False(body.ContainsKey("prompt_cache_key"));
        Assert.Single(body["input"]![0]!["content"]!.AsArray());
    }

    [Theory]
    [InlineData(429)]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    [InlineData(504)]
    [InlineData(529)]
    public async Task RetriesUseThreeAttemptsAndOneThenTwoSecondBackoff(int status)
    {
        using var handler = new StubHttp((_, number, _) => Task.FromResult(Response(number < 3 ? status : 200, number < 3 ? "{\"error\":{\"message\":\"busy\"}}" : Completion(ConnectorId.OpenAI))));
        using var client = new HttpClient(handler);
        var delays = new List<TimeSpan>();
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor(), (wait, _) => { delays.Add(wait); return Task.CompletedTask; });
        await connector.SendAsync(Catalog().TestRequest(ConnectorId.OpenAI), "model", TestContext.Current.CancellationToken);
        Assert.Equal(3, handler.Requests.Count); Assert.Equal(new[] { TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2) }, delays);
    }

    [Theory]
    [InlineData("3", 3, 3)]
    [InlineData("40", 1, 0)]
    public async Task RetryAfterHintsOverrideBackoffAndLongHintsStop(string hint, int attempts, int wait)
    {
        using var handler = new StubHttp((_, number, _) =>
        {
            var response = Response(number == 1 ? 429 : 200, number == 1 ? "{}" : Completion(ConnectorId.OpenAI));
            if (number == 1) response.Headers.TryAddWithoutValidation("Retry-After", hint);
            return Task.FromResult(response);
        });
        using var client = new HttpClient(handler);
        var delays = new List<TimeSpan>();
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor(), (value, _) => { delays.Add(value); return Task.CompletedTask; });
        if (hint == "40") Assert.Equal(LlmErrorKind.RateLimited, (await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(ConnectorId.OpenAI), "model", TestContext.Current.CancellationToken))).Error.Kind);
        else await connector.SendAsync(Catalog().TestRequest(ConnectorId.OpenAI), "model", TestContext.Current.CancellationToken);
        Assert.Equal(hint == "3" ? 2 : attempts, handler.Requests.Count);
        Assert.Equal(wait == 0 ? Array.Empty<TimeSpan>() : new[] { TimeSpan.FromSeconds(wait) }, delays);
    }

    [Theory]
    [InlineData(ConnectorId.OpenAI, 429, "{\"error\":{\"code\":\"insufficient_quota\"}}", LlmErrorKind.QuotaExceeded)]
    [InlineData(ConnectorId.Anthropic, 402, "{\"error\":{\"type\":\"billing_error\"}}", LlmErrorKind.QuotaExceeded)]
    [InlineData(ConnectorId.Gemini, 400, "{\"error\":{\"details\":[{\"reason\":\"API_KEY_INVALID\"}]}}", LlmErrorKind.Unauthorized)]
    [InlineData(ConnectorId.Xai, 400, "{\"error\":{\"message\":\"API key invalid\"}}", LlmErrorKind.Unauthorized)]
    [InlineData(ConnectorId.OpenAI, 401, "{}", LlmErrorKind.Unauthorized)]
    [InlineData(ConnectorId.OpenAI, 403, "{}", LlmErrorKind.Unauthorized)]
    [InlineData(ConnectorId.OpenAI, 404, "{}", LlmErrorKind.ModelNotFound)]
    [InlineData(ConnectorId.OpenAI, 400, "{\"error\":{\"code\":\"context_length_exceeded\"}}", LlmErrorKind.ContextTooLong)]
    [InlineData(ConnectorId.OpenAI, 400, "{\"error\":{\"message\":\"bad input\"}}", LlmErrorKind.BadRequest)]
    [InlineData(ConnectorId.Gemini, 504, "{}", LlmErrorKind.Timeout)]
    public async Task PermanentErrorsNeverRetry(ConnectorId id, int status, string body, LlmErrorKind expected)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(status, body)));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(id, Catalog(), client, new MemoryKeys(), new Redactor(), (_, _) => Task.CompletedTask);
        var exception = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(id), "model", TestContext.Current.CancellationToken));
        Assert.Equal(expected, exception.Error.Kind); Assert.Single(handler.Requests); Assert.EndsWith("Your edits are saved.", exception.Error.UserMessage);
    }

    [Fact]
    public async Task RunnerUsesOnlyOneFallbackModelAndCorrectsJsonOnlyOnce()
    {
        using var handler = new StubHttp((_, number, _) => Task.FromResult(number <= 3 ? Response(529, "{\"error\":{\"type\":\"overloaded_error\"}}") : Response(200, Completion(ConnectorId.Anthropic, number == 4 ? "not JSON" : "```json\n{\"ok\":true,\"echo\":\"voxclip\"}\n```"))));
        using var client = new HttpClient(handler);
        var catalog = Catalog(); var keys = new MemoryKeys(); var redactor = new Redactor();
        var connector = new LlmConnector(ConnectorId.Anthropic, catalog, client, keys, redactor, (_, _) => Task.CompletedTask);
        var result = await new LlmRunner(keys, catalog, redactor).RunAsync(catalog.TestRequest(connector.Id), connector, "claude-opus-5-5", TestContext.Current.CancellationToken);
        Assert.True(result.UsedFallback); Assert.Equal("claude-sonnet-5-5", result.Model); Assert.Equal(5, handler.Requests.Count);
        Assert.All(handler.Requests.Take(3), sent => Assert.Equal("claude-opus-5-5", sent.Body!["model"]!.GetValue<string>()));
        Assert.Contains("Your previous reply was not valid JSON", handler.Requests[^1].Body!["messages"]![0]!["content"]![0]!["text"]!.GetValue<string>());
    }

    [Fact]
    public async Task AnthropicBetaRejectionRetriesWithoutBetaAndRemembersIt()
    {
        using var handler = new StubHttp((_, number, _) => Task.FromResult(number == 1 ? Response(400, "{\"error\":{\"message\":\"unexpected anthropic-beta value\"}}") : Response(200, Completion(ConnectorId.Anthropic))));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Anthropic, Catalog(), client, new MemoryKeys(), new Redactor());
        await connector.SendAsync(Catalog().TestRequest(connector.Id), "claude-opus-5-5", TestContext.Current.CancellationToken);
        await connector.SendAsync(Catalog().TestRequest(connector.Id), "claude-opus-5-5", TestContext.Current.CancellationToken);
        Assert.True(handler.Requests[0].Headers.ContainsKey("anthropic-beta"));
        Assert.All(handler.Requests.Skip(1), sent => { Assert.False(sent.Headers.ContainsKey("anthropic-beta")); Assert.False(sent.Body!.ContainsKey("fallbacks")); });
    }

    [Fact]
    public async Task GeminiRetryInfoOfFortyFiveSecondsStopsImmediately()
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(429, "{\"error\":{\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"45s\"}]}}")));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Gemini, Catalog(), client, new MemoryKeys(), new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(connector.Id), "models/gemini-test/path", TestContext.Current.CancellationToken));
        Assert.Equal(TimeSpan.FromSeconds(45), failure.Error.RetryAfter); Assert.Single(handler.Requests); Assert.DoesNotContain("key=", handler.Requests[0].Url);
        Assert.Contains("gemini-test%2Fpath", handler.Requests[0].Url);
    }

    [Theory]
    [InlineData(ConnectorId.Anthropic, "{\"stop_reason\":\"max_tokens\"}", LlmErrorKind.Truncated)]
    [InlineData(ConnectorId.Anthropic, "{\"stop_reason\":\"refusal\",\"stop_details\":{\"category\":\"safety\"}}", LlmErrorKind.Refused)]
    [InlineData(ConnectorId.OpenAI, "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}", LlmErrorKind.Truncated)]
    [InlineData(ConnectorId.OpenAI, "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\"}]}]}", LlmErrorKind.Refused)]
    [InlineData(ConnectorId.Gemini, "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\"}]}", LlmErrorKind.Truncated)]
    [InlineData(ConnectorId.Gemini, "{\"candidates\":[{\"finishReason\":\"SAFETY\"}]}", LlmErrorKind.Refused)]
    [InlineData(ConnectorId.Xai, "{\"choices\":[{\"finish_reason\":\"length\"}]}", LlmErrorKind.Truncated)]
    public async Task StopKindsAreNeverRetriedOrCorrected(ConnectorId id, string body, LlmErrorKind kind)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, body)));
        using var client = new HttpClient(handler); var catalog = Catalog(); var keys = new MemoryKeys();
        var connector = new LlmConnector(id, catalog, client, keys, new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => new LlmRunner(keys, catalog, new Redactor()).RunAsync(catalog.TestRequest(id), connector, "model", TestContext.Current.CancellationToken));
        Assert.Equal(kind, failure.Error.Kind); Assert.Single(handler.Requests);
    }

    /// <summary>An Anthropic reply body whose text answers the connection test, with raw members appended.</summary>
    private static string StrictBody(string extra = "") =>
        "{\"model\":\"claude-sonnet-5-5\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true,\\\"echo\\\":\\\"VoxClip\\\"}\"}]" + extra + "}";

    /// <summary>A body <paramref name="levels"/> deep: the object and arrays in a key nobody reads.</summary>
    private static string NestedBody(int levels) => StrictBody(",\"x\":" + new string('[', levels - 1) + new string(']', levels - 1));

    public static TheoryData<string, string, bool> StrictBodies() => new()
    {
        { "zero with an exponent", StrictBody(",\"x\":0e1"), true },
        { "JavaScript whitespace around", "" + (char)0xFEFF + (char)0xA0 + StrictBody() + (char)0x3000 + "\n", true },
        { "512 levels", NestedBody(512), true },
        { "513 levels", NestedBody(513), false },
        { "unpaired surrogate escape", StrictBody(",\"x\":\"" + (char)92 + "ud800\""), false },
        { "code fence", "```json\n" + StrictBody() + "\n```", false },
        { "prose before", "Result: " + StrictBody(), false }
    };

    /// <summary>ai.md §4.5: an HTTP response body is one strict JSON value of at most 512 levels, read whole after jsTrim with no
    /// code fence or balanced-object scan. A body that is not one gives no reply.</summary>
    [Theory]
    [MemberData(nameof(StrictBodies))]
    public async Task ResponseBodyIsOneStrictEnvelope(string label, string body, bool accepted)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, body)));
        using var client = new HttpClient(handler);
        var catalog = Catalog();
        var connector = new LlmConnector(ConnectorId.Anthropic, catalog, client, new MemoryKeys(), new Redactor());
        var request = catalog.TestRequest(ConnectorId.Anthropic);
        JsonObject? reply = null;
        try { reply = LlmOutput.Validate(await connector.SendAsync(request, "model", TestContext.Current.CancellationToken), request.Schema).Object; }
        catch (LlmException) { }
        Assert.True(accepted == (reply?["ok"] is JsonValue ok && ok.TryGetValue<bool>(out var value) && value), label);
    }

    [Fact]
    public async Task TimeoutIsDistinctFromCancellationAndNeitherRetries()
    {
        using var handler = new StubHttp(async (_, _, ct) => { await Task.Delay(Timeout.InfiniteTimeSpan, ct); return Response(200, "{}"); });
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor());
        var request = Catalog().TestRequest(connector.Id) with { Timeout = TimeSpan.FromMilliseconds(35) };
        Assert.Equal(LlmErrorKind.Timeout, (await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(request, "model", TestContext.Current.CancellationToken))).Error.Kind);
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(35));
        var cancelled = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(request with { Timeout = TimeSpan.FromSeconds(30) }, "model", cancel.Token));
        Assert.Equal(LlmErrorKind.Cancelled, cancelled.Error.Kind); Assert.Empty(cancelled.Message); Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public async Task CancellationDuringBackoffStopsAndTransportDescriptionsAreNeverLogged()
    {
        using var cancellation = new CancellationTokenSource();
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(429, "{}")));
        using var client = new HttpClient(handler); var sink = new CaptureLog();
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor(), (_, token) => { cancellation.Cancel(); return Task.Delay(1000, token); }, onDiagnostic: message => sink.Write(VoxClip.Core.Services.Logging.LogLevel.Info, "llm", message));
        Assert.Equal(LlmErrorKind.Cancelled, (await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(connector.Id), "model", cancellation.Token))).Error.Kind);
        Assert.Single(handler.Requests);
        using var throwing = new StubHttp((_, _, _) => throw new HttpRequestException("https://host/?key=do-not-log-this-value"));
        using var failingClient = new HttpClient(throwing);
        var failing = new LlmConnector(ConnectorId.Gemini, Catalog(), failingClient, new MemoryKeys(), new Redactor(), onDiagnostic: message => sink.Write(VoxClip.Core.Services.Logging.LogLevel.Info, "llm", message));
        Assert.Equal(LlmErrorKind.Network, (await Assert.ThrowsAsync<LlmException>(() => failing.SendAsync(Catalog().TestRequest(failing.Id), "model", TestContext.Current.CancellationToken))).Error.Kind);
        Assert.DoesNotContain(sink.Lines, line => line.Contains("do-not-log", StringComparison.Ordinal) || line.Contains("test-placeholder", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ConnectionResetRetriesButOtherSocketErrorsDoNot()
    {
        using var handler = new StubHttp((_, number, _) => number == 1 ? throw new HttpRequestException("lost", new IOException("read failed", new SocketException((int)SocketError.ConnectionReset))) : Task.FromResult(Response(200, Completion(ConnectorId.OpenAI))));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor(), (_, _) => Task.CompletedTask);
        await connector.SendAsync(Catalog().TestRequest(connector.Id), "model", TestContext.Current.CancellationToken);
        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public void ExtractionTracksEscapesAndStructuralValidationDropsOnlyBadItems()
    {
        var parsed = LlmOutput.Extract("explanation {\"clips\":[{\"title\":\"brace } and \\\" quote\",\"reason\":\"\",\"score\":7,\"start_word\":5.5,\"end_word\":30},{\"title\":42}]} trailing");
        Assert.NotNull(parsed);
        var schema = new ClipPrompts(Catalog()).Clips["output"]!["schema"]!.AsObject();
        var validated = LlmOutput.Validate(new(null, parsed, "m", new StopKind.Complete(), null, null), schema);
        Assert.Equal(1, validated.Dropped); Assert.Equal(5.5, Assert.Single(validated.Object!["clips"]!.AsArray())!["start_word"]!.GetValue<double>());
    }

    [Fact]
    public async Task OpenAiRefreshFiltersSortsMergesAndKeepsSelectedModel()
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, "{\"data\":[{\"id\":\"gpt-new\",\"created\":30},{\"id\":\"gpt-audio\",\"created\":40},{\"id\":\"o3\",\"created\":20},{\"id\":\"gpt-5.6-luna\",\"created\":10}]}")));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor());
        connector.SelectModel("gpt-6.1-sol");
        var models = await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
        Assert.Equal(new[] { "gpt-5.6-luna", "gpt-new", "o3", "gpt-6.1-sol" }, models.Select(model => model.Id));
        Assert.Contains("not listed for this key", models[^1].Name);
        Assert.Equal(models, await connector.GetModelsAsync(false, TestContext.Current.CancellationToken)); Assert.Single(handler.Requests);
    }

    /// <summary>The model-list cache records its fetch time in the canonical form (editing §10.1).</summary>
    [Fact]
    public async Task RefreshedModelListRecordsItsFetchTimeInCanonicalForm()
    {
        var directory = Directory.CreateTempSubdirectory("voxclip-model-list-");
        try
        {
            var cacheFile = Path.Combine(directory.FullName, "llm-models.json");
            using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, "{\"data\":[{\"id\":\"gpt-new\",\"created\":30}]}")));
            using var client = new HttpClient(handler);
            var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor(), cacheFile: cacheFile);
            await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
            var saved = JsonNode.Parse(await File.ReadAllTextAsync(cacheFile, TestContext.Current.CancellationToken))!;
            var fetchedAt = saved[LlmCatalog.WireId(ConnectorId.OpenAI)]!["fetchedAt"]!.GetValue<string>();
            Assert.Equal(UtcTimestamp.Format(connector.ModelsFetchedAt!.Value), fetchedAt);
            Assert.Matches(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", fetchedAt);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public async Task LocalContextAndThinkingComeFromNativeOllamaDetails()
    {
        using var handler = new StubHttp((request, _, _) => Task.FromResult(Response(200, request.RequestUri!.AbsolutePath == "/api/show" ? "{\"model_info\":{\"qwen.context_length\":16000},\"capabilities\":[\"completion\"]}" : "{\"message\":{\"content\":\"{}\"},\"done_reason\":\"length\"}")));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Ollama, Catalog(), client, new EmptyKeys(), new Redactor());
        Assert.Equal(16000, await connector.GetContextTokensAsync("local", TestContext.Current.CancellationToken));
        var result = await connector.SendAsync(Request(connector.Id), "local", TestContext.Current.CancellationToken);
        Assert.IsType<StopKind.Truncated>(result.Stop); Assert.False(handler.Requests[^1].Body!.ContainsKey("think"));
        Assert.Equal(8192, handler.Requests[^1].Body!["options"]!["num_ctx"]!.GetValue<int>());
    }
}
