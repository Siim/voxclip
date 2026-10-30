using System.Text.Json.Nodes;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Domain.Shared;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class HttpConformanceTests
{
    [Theory]
    [InlineData(ConnectorId.OpenAI, "gpt")]
    [InlineData(ConnectorId.Xai, "grok")]
    public async Task TextModelPickersExcludeVoiceLiveAudioAndRealtime(ConnectorId id, string prefix)
    {
        string[] excluded = [$"{prefix}-live-1", $"{prefix}-voice-2.0", $"{prefix}-voice-3.0", $"{prefix}-audio-preview", $"{prefix}-realtime-preview", $"{prefix}-transcribe", $"{prefix}-tts", $"{prefix}-image-1"];
        var accepted = $"{prefix}-text-custom";
        var body = new JsonObject { ["data"] = new JsonArray(excluded.Append(accepted).Select(model => (JsonNode)new JsonObject { ["id"] = model, ["created"] = 1 }).ToArray()) };
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, body.ToJsonString())));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(id, Catalog(), client, new MemoryKeys(), new Redactor());
        var models = await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
        Assert.Contains(models, model => model.Id == accepted);
        Assert.DoesNotContain(models, model => excluded.Contains(model.Id));
    }

    [Theory]
    [InlineData("[false,true]", "false")]
    [InlineData("[\"high\",\"medium\",\"low\"]", "\"low\"")]
    [InlineData("[\"high\",\"medium\"]", "\"medium\"")]
    [InlineData("[true]", null)]
    [InlineData("[\"false\"]", null)]
    [InlineData("[]", null)]
    [InlineData("null", null)]
    [InlineData("[\"tiny\",\"huge\"]", null)]
    public async Task OllamaUsesOnlyAdvertisedThinkingControls(string values, string? expected)
    {
        var details = "{\"capabilities\":[\"completion\",\"thinking\"],\"model_info\":{\"model.context_length\":32768},\"thinking\":{\"values\":" + values + "}}";
        using var handler = new StubHttp((request, _, _) => Task.FromResult(Response(200, request.RequestUri!.AbsolutePath == "/api/show" ? details : Completion(ConnectorId.Ollama))));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Ollama, Catalog(), client, new MemoryKeys(), new Redactor());
        await connector.SendAsync(Catalog().TestRequest(ConnectorId.Ollama), "local", TestContext.Current.CancellationToken);
        EqualJson(expected is null ? null : JsonNode.Parse(expected), handler.Requests[^1].Body!["think"]);
        Assert.Equal(2, handler.Requests.Count);
    }

    [Theory]
    [InlineData("gemini-3.5-flash-lite")]
    [InlineData("gemini-3.8-flash")]
    [InlineData("gemini-3.1-pro-preview")]
    public async Task GeminiCuratedModelsRetainCompatibleSchemaField(string model)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, Completion(ConnectorId.Gemini))));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Gemini, Catalog(), client, new MemoryKeys(), new Redactor());
        var request = Catalog().TestRequest(ConnectorId.Gemini);
        await connector.SendAsync(request, model, TestContext.Current.CancellationToken);
        var generation = handler.Requests.Single().Body!["generationConfig"]!;
        EqualJson(request.Schema, generation["responseJsonSchema"]);
        Assert.Equal("application/json", generation["responseMimeType"]!.GetValue<string>());
        Assert.Null(generation["responseFormat"]);
        Assert.Null(generation["responseSchema"]);
    }

    [Fact]
    public async Task GeminiUsageIncludesBilledThinkingTokens()
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"{}\"}]}}],\"usageMetadata\":{\"candidatesTokenCount\":12,\"thoughtsTokenCount\":80}}")));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Gemini, Catalog(), client, new MemoryKeys(), new Redactor());
        var result = await connector.SendAsync(Catalog().TestRequest(ConnectorId.Gemini), "gemini-3.8-flash", TestContext.Current.CancellationToken);
        Assert.Equal(92, result.Usage!.Output);
        var generation = handler.Requests.Single().Body!["generationConfig"]!;
        Assert.Equal(2048, generation["maxOutputTokens"]!.GetValue<int>());
        Assert.Equal("LOW", generation["thinkingConfig"]!["thinkingLevel"]!.GetValue<string>());
        Assert.Null(generation["thinkingConfig"]!["thinkingBudget"]);
    }

    [Theory]
    [InlineData("MAX_TOKENS", "")]
    [InlineData("MAX_TOKENS", "{\"ok\":true,\"echo\":\"vox")]
    [InlineData("MAX_TOKENS", "{\"ok\":true,\"echo\":\"voxclip\"}")]
    [InlineData("CONTINUATION", "")]
    [InlineData("CONTINUATION", "{\"ok\":true,\"echo\":\"vox")]
    [InlineData("CONTINUATION", "{\"ok\":true,\"echo\":\"voxclip\"}")]
    [InlineData("MALFORMED_RESPONSE", "")]
    [InlineData("MALFORMED_RESPONSE", "{\"ok\":true,\"echo\":\"vox")]
    [InlineData("MALFORMED_RESPONSE", "{\"ok\":true,\"echo\":\"voxclip\"}")]
    public async Task GeminiRunnerRejectsIncompleteOutputsWithoutRetries(string reason, string text)
    {
        var body = new JsonObject { ["candidates"] = new JsonArray(new JsonObject { ["finishReason"] = reason, ["content"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = text }) } }) };
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, body.ToJsonString())));
        using var client = new HttpClient(handler);
        var catalog = Catalog();
        var keys = new MemoryKeys();
        var delays = new List<TimeSpan>();
        var connector = new LlmConnector(ConnectorId.Gemini, catalog, client, keys, new Redactor(), (duration, _) => { delays.Add(duration); return Task.CompletedTask; });
        var runner = new LlmRunner(keys, catalog, new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(catalog.TestRequest(ConnectorId.Gemini), connector, "gemini-3.8-flash", TestContext.Current.CancellationToken));
        Assert.Equal(reason == "MALFORMED_RESPONSE" ? LlmErrorKind.Server : LlmErrorKind.Truncated, failure.Error.Kind);
        Assert.Equal(reason == "MALFORMED_RESPONSE" ? VoxClipErrorCode.ProviderError : VoxClipErrorCode.LlmInvalidOutput, failure.Error.Code);
        Assert.Equal(reason == "MALFORMED_RESPONSE" ? (int?)500 : null, failure.Error.Status);
        Assert.Equal(reason == "MALFORMED_RESPONSE" ? "Google Gemini had a server error (500). Try again. Your edits are saved." : "The clip suggestions were incomplete. Please try again. Your edits are saved.", failure.Error.UserMessage);
        Assert.Single(handler.Requests);
        Assert.Empty(delays);
    }

    public static TheoryData<string> GeminiFinishReasons => new("FINISH_REASON_UNSPECIFIED", "STOP", "MAX_TOKENS", "SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "MALFORMED_FUNCTION_CALL", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER", "NO_IMAGE", "IMAGE_RECITATION", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS", "MISSING_THOUGHT_SIGNATURE", "MALFORMED_RESPONSE", "ESCALATION", "PUP_LIMITED_DISABLED", "CONTINUATION", "", "FUTURE_REASON");

    [Theory]
    [MemberData(nameof(GeminiFinishReasons))]
    public async Task GeminiFinishReasonsNeverCompleteUnlessStopped(string reason)
    {
        var body = new JsonObject { ["candidates"] = new JsonArray(new JsonObject { ["finishReason"] = reason, ["content"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = "{\"ok\":true,\"echo\":\"voxclip\"}" }) } }) };
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, body.ToJsonString())));
        using var client = new HttpClient(handler);
        var keys = new MemoryKeys();
        var connector = new LlmConnector(ConnectorId.Gemini, Catalog(), client, keys, new Redactor());
        string[] refused = ["SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER", "IMAGE_RECITATION", "ESCALATION"];
        if (reason is "STOP" or "MAX_TOKENS" or "CONTINUATION" || refused.Contains(reason))
        {
            var result = await connector.SendAsync(Catalog().TestRequest(ConnectorId.Gemini), "gemini-3.8-flash", TestContext.Current.CancellationToken);
            StopKind expected = reason == "STOP" ? new StopKind.Complete() : refused.Contains(reason) ? new StopKind.Refused(reason) : new StopKind.Truncated();
            Assert.Equal(expected, result.Stop);
        }
        else
        {
            var runner = new LlmRunner(keys, Catalog(), new Redactor());
            var failure = await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(Catalog().TestRequest(ConnectorId.Gemini), connector, "gemini-3.8-flash", TestContext.Current.CancellationToken));
            Assert.Equal(reason == "PUP_LIMITED_DISABLED" ? LlmErrorKind.Unavailable : LlmErrorKind.Server, failure.Error.Kind);
        }
        Assert.Single(handler.Requests);
    }

    public static TheoryData<string, LlmErrorKind> ResponseCodes => new()
    {
        { "server_error", LlmErrorKind.Server }, { "vector_store_timeout", LlmErrorKind.Server },
        { "rate_limit_exceeded", LlmErrorKind.RateLimited }, { "invalid_prompt", LlmErrorKind.Refused },
        { "bio_policy", LlmErrorKind.Refused }, { "misalignment_policy_violation", LlmErrorKind.Refused },
        { "image_content_policy_violation", LlmErrorKind.Refused }, { "data_residency_mismatch", LlmErrorKind.Unavailable },
        { "invalid_image", LlmErrorKind.BadRequest }, { "invalid_image_format", LlmErrorKind.BadRequest },
        { "invalid_base64_image", LlmErrorKind.BadRequest }, { "invalid_image_url", LlmErrorKind.BadRequest },
        { "image_too_large", LlmErrorKind.BadRequest }, { "image_too_small", LlmErrorKind.BadRequest },
        { "image_parse_error", LlmErrorKind.BadRequest }, { "invalid_image_mode", LlmErrorKind.BadRequest },
        { "image_file_too_large", LlmErrorKind.BadRequest }, { "unsupported_image_media_type", LlmErrorKind.BadRequest },
        { "empty_image_file", LlmErrorKind.BadRequest }, { "failed_to_download_image", LlmErrorKind.BadRequest },
        { "image_file_not_found", LlmErrorKind.BadRequest }, { "unknown", LlmErrorKind.Server },
        { "model_not_found", LlmErrorKind.Server }, { "context_length_exceeded", LlmErrorKind.Server },
        { "insufficient_quota", LlmErrorKind.Server }
    };

    [Theory]
    [MemberData(nameof(ResponseCodes))]
    public async Task OpenAiFailedResponseUsesDocumentedCodesWithoutRetries(string code, LlmErrorKind expected)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, new JsonObject { ["status"] = "failed", ["error"] = new JsonObject { ["code"] = code } }.ToJsonString())));
        using var client = new HttpClient(handler);
        var delays = new List<TimeSpan>();
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor(), (duration, _) => { delays.Add(duration); return Task.CompletedTask; });
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(ConnectorId.OpenAI), "gpt-5.6-sol", TestContext.Current.CancellationToken));
        Assert.Equal(expected, failure.Error.Kind);
        if (expected == LlmErrorKind.Server) Assert.Equal(500, failure.Error.Status);
        if (expected == LlmErrorKind.BadRequest) Assert.Equal(400, failure.Error.Status);
        Assert.Single(handler.Requests);
        Assert.Empty(delays);
    }

    [Fact]
    public async Task AnthropicContextExhaustionDoesNotCorrectPartialJson()
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, "{\"stop_reason\":\"model_context_window_exceeded\",\"content\":[{\"type\":\"text\",\"text\":\"{\"}]}")));
        using var client = new HttpClient(handler);
        var keys = new MemoryKeys();
        var connector = new LlmConnector(ConnectorId.Anthropic, Catalog(), client, keys, new Redactor());
        var runner = new LlmRunner(keys, Catalog(), new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => runner.RunAsync(Catalog().TestRequest(ConnectorId.Anthropic), connector, "claude-sonnet-5-5", TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Truncated, failure.Error.Kind);
        Assert.Single(handler.Requests);
    }

    [Theory]
    [InlineData("not-loaded", 4096)]
    [InlineData("loading", 4096)]
    [InlineData("", 4096)]
    [InlineData("loaded", 131072)]
    public async Task LmStudioRequiresLoadedStateForWorkingContext(string state, int expected)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, new JsonObject { ["state"] = state, ["max_context_length"] = 131072 }.ToJsonString())));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.LmStudio, Catalog(), client, new MemoryKeys(), new Redactor());
        Assert.Equal(expected, await connector.GetContextTokensAsync("local", TestContext.Current.CancellationToken));
    }

    [Theory]
    [InlineData(8192, 8192)]
    [InlineData(0, 131072)]
    [InlineData(-1, 131072)]
    public async Task LmStudioPrefersOnlyPositiveLoadedContext(int loaded, int expected)
    {
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, new JsonObject { ["state"] = "loaded", ["loaded_context_length"] = loaded, ["max_context_length"] = 131072 }.ToJsonString())));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.LmStudio, Catalog(), client, new MemoryKeys(), new Redactor());
        Assert.Equal(expected, await connector.GetContextTokensAsync("local", TestContext.Current.CancellationToken));
    }
}
