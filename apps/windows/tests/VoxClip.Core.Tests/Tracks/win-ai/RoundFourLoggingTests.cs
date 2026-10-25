using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using VoxClip.Tests.Support;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class RoundFourLoggingTests
{
    [Fact]
    public async Task RemovedOllamaModelContextReportsExactlyOneError()
    {
        var catalog = Catalog();
        using var handler = new StubHttp(async (request, _, cancellation) =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/version") return Response(200, "{}");
            if (path == "/api/tags") return Response(200, "{\"models\":[{\"name\":\"installed:1b\"}]}");
            Assert.Equal("/api/show", path);
            var body = JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellation));
            return body!["model"]!.GetValue<string>() == "removed:latest" ? Response(404, "{}") :
                Response(200, "{\"capabilities\":[\"completion\"],\"model_info\":{\"test.context_length\":4096}}");
        });
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.Ollama, catalog, http, new MemoryKeys(null), new Redactor());
        var errors = new List<(LlmErrorKind Kind, string Message)>();
        var runner = new LlmRunner(new MemoryKeys(null), catalog, new Redactor(), (kind, message) => errors.Add((kind, message)));
        var finder = new ClipFinder(runner, _ => connector, FixtureLoader.SharedRoot);
        var failure = await Assert.ThrowsAsync<LlmException>(() => finder.FindClipsAsync(Input(ConnectorId.Ollama, "removed:latest"), null, TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.ModelNotFound, failure.Error.Kind);
        Assert.Equal(LlmErrorKind.ModelNotFound, Assert.Single(errors).Kind);
        Assert.DoesNotContain(handler.Requests, request => request.Url.EndsWith("/api/chat", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("context", LlmErrorKind.Unavailable)]
    [InlineData("preflight", LlmErrorKind.MissingKey)]
    [InlineData("generation", LlmErrorKind.Unavailable)]
    [InlineData("noConnector", LlmErrorKind.NoConnector)]
    [InlineData("cancellation", LlmErrorKind.Cancelled)]
    public async Task PipelineFailuresReportOnceAndRedactBeforeTruncating(string stage, LlmErrorKind expected)
    {
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var failure = new LlmException(new(LlmErrorKind.Unavailable, VoxClipErrorCode.ProviderError, "test-only-value " + new string('x', 300)));
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => throw failure)
        {
            Status = stage == "preflight" ? new ConnectorStatus.NeedsKey() : new ConnectorStatus.Ready(),
            Context = (_, _) =>
            {
                if (stage == "context") throw failure;
                if (stage == "cancellation") { cancellation.Cancel(); throw new OperationCanceledException(cancellation.Token); }
                return Task.FromResult<int?>(128000);
            }
        };
        var errors = new List<(LlmErrorKind Kind, string Message)>();
        var runner = new LlmRunner(new MemoryKeys(), Catalog(), new Redactor(["test-only-value"]), (kind, message) => errors.Add((kind, message)));
        var finder = new ClipFinder(runner, _ => connector, FixtureLoader.SharedRoot);
        var input = Input(stage == "noConnector" ? (ConnectorId)int.MaxValue : ConnectorId.OpenAI, "chat");
        var thrown = await Assert.ThrowsAsync<LlmException>(() => finder.FindClipsAsync(input, null, cancellation.Token));
        Assert.Equal(expected, thrown.Error.Kind);
        var error = Assert.Single(errors);
        Assert.Equal(expected, error.Kind);
        Assert.True(error.Message.Length <= 200);
        Assert.DoesNotContain("test-only-value", error.Message, StringComparison.Ordinal);
        if (stage is "context" or "generation") Assert.StartsWith("[REDACTED]", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ContextLoggingCallbackCannotMaskTheFailure()
    {
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => throw new InvalidOperationException())
        { Context = (_, _) => throw LlmErrors.Create(LlmErrorKind.Network, "OpenAI") };
        var runner = new LlmRunner(new MemoryKeys(), Catalog(), new Redactor(), (_, _) => throw new IOException("test sink failure"));
        var finder = new ClipFinder(runner, _ => connector, FixtureLoader.SharedRoot);
        var failure = await Assert.ThrowsAsync<LlmException>(() => finder.FindClipsAsync(Input(ConnectorId.OpenAI, "chat"), null, TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.Network, failure.Error.Kind);
    }

    private static ClipFinderRequest Input(ConnectorId connector, string model) =>
        new(Words(20), new Dictionary<string, string>(), new HashSet<string>(), ClipPreset.Best, null, "en", connector, model);
}
