using System.Text.Json.Nodes;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Domain.Shared;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

public sealed class HttpConformanceTests
{
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
