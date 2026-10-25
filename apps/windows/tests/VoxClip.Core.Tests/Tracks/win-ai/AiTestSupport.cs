using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.Transcript;
using VoxClip.Core.Services.LLM;
using VoxClip.Core.Services.Logging;
using VoxClip.Tests.Support;
using Xunit;

namespace VoxClip.Core.Tests.Tracks.WinAi;

internal static class AiTestSupport
{
    internal static LlmCatalog Catalog() => new(FixtureLoader.SharedRoot);
    internal static TimedWord Word(int index, string? text = null, double? start = null, double? end = null, WordKind kind = WordKind.Word) =>
        new("w" + index, text ?? "w" + index, kind, start ?? index, end ?? index + 0.8, null, null, null, null, TimingSource.Native);
    internal static TimedWord[] Words(int count) => Enumerable.Range(0, count).Select(index => Word(index)).ToArray();
    internal static LlmRequest Request(ConnectorId id)
    {
        var request = Catalog().TestRequest(id);
        return request with { Feature = LlmFeature.ClipFinder, System = "S", CachedBlock = "B", Instruction = "I", MaxOutputTokens = 16000, Effort = Effort.Medium };
    }
    internal static HttpResponseMessage Response(int status, string json) => new((HttpStatusCode)status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
    internal static string Completion(ConnectorId id, string text = "{\"ok\":true,\"echo\":\"voxclip\"}")
    {
        var escaped = JsonValue.Create(text)!.ToJsonString();
        return id switch
        {
            ConnectorId.Anthropic => "{\"content\":[{\"type\":\"text\",\"text\":" + escaped + "}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":12,\"output_tokens\":3}}",
            ConnectorId.OpenAI => "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":" + escaped + "}]}]}",
            ConnectorId.Gemini => "{\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"hidden\"},{\"text\":" + escaped + "}]},\"finishReason\":\"STOP\"}]}",
            ConnectorId.Ollama => "{\"message\":{\"content\":" + escaped + "},\"done_reason\":\"stop\"}",
            _ => "{\"choices\":[{\"message\":{\"content\":" + escaped + "},\"finish_reason\":\"stop\"}]}"
        };
    }
    internal static void EqualJson(JsonNode? expected, JsonNode? actual) => Assert.True(JsonNode.DeepEquals(expected, actual), $"Expected {expected?.ToJsonString()}, received {actual?.ToJsonString()}");
    internal static JsonNode Fixture(string name)
    {
        var path = Path.Combine(FixtureLoader.SharedRoot, "fixtures", "llm", name + ".json");
        RequireFixtures(File.Exists(path));
        return JsonNode.Parse(File.ReadAllText(path))!;
    }
    internal static void RequireFixtures(bool present)
    {
        if (present) return;
        if (Environment.GetEnvironmentVariable("VOXCLIP_SHARED_DIR") is not null) Assert.Fail("VOXCLIP_SHARED_DIR must contain fixtures/llm and every requested fixture.");
        Assert.Skip("Shared LLM fixtures are absent; set VOXCLIP_SHARED_DIR to the newest shared directory.");
    }
}

internal sealed class MemoryKeys(string? value = "test-placeholder-value") : IKeyProvider
{
    internal List<string> Accounts { get; } = [];
    public Task<string?> GetKeyAsync(string account, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Accounts.Add(account); return Task.FromResult(value); }
}

internal sealed class StubHttp(Func<HttpRequestMessage, int, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
{
    internal List<(string Url, JsonObject? Body, Dictionary<string, string> Headers)> Requests { get; } = [];
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? null : JsonNode.Parse(await request.Content.ReadAsStringAsync(cancellationToken))!.AsObject();
        var headers = request.Headers.ToDictionary(pair => pair.Key, pair => string.Join(pair.Key.Equals("User-Agent", StringComparison.OrdinalIgnoreCase) ? " " : ",", pair.Value), StringComparer.OrdinalIgnoreCase);
        if (request.Content?.Headers.ContentType is { } contentType) headers["Content-Type"] = contentType.ToString();
        Requests.Add((request.RequestUri!.AbsoluteUri, body, headers));
        return await respond(request, Requests.Count, cancellationToken);
    }
}

internal sealed class CaptureLog : ILog
{
    private readonly List<string> secrets = [];
    internal List<string> Lines { get; } = [];
    public void RegisterSecret(string secret) => secrets.Add(secret);
    public void Write(LogLevel level, string category, string message) => Lines.Add(new Redactor(secrets).Redact(message));
    public Task<IReadOnlyList<string>> ReadRecentAsync(int count, CancellationToken ct) => Task.FromResult<IReadOnlyList<string>>(Lines.TakeLast(count).ToArray());
    public Task FlushAsync(CancellationToken ct) => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
