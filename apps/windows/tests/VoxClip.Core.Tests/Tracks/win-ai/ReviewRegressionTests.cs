using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class ReviewRegressionTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FeatureGatesCarryOnlyThePromptMessage(bool noWords)
    {
        var catalog = Catalog();
        var finder = new ClipFinder(catalog, new MemoryKeys(null), new Redactor(), _ => throw new InvalidOperationException("No connector access before feature gates."));
        var input = new ClipFinderRequest(Words(noWords ? 0 : 20), new Dictionary<string, string>(), new HashSet<string>(), ClipPreset.Custom, "\ufeff \t", "en", ConnectorId.OpenAI, "model");
        var failure = await Assert.ThrowsAsync<ClipFinderGateException>(() => finder.FindClipsAsync(input, null, TestContext.Current.CancellationToken));
        Assert.Equal(noWords ? ClipFinderGateKind.NoWords : ClipFinderGateKind.NeedInstructions, failure.Kind);
        Assert.Equal(new ClipPrompts(catalog).Clips["messages"]![noWords ? "noWords" : "needInstructions"]!.GetValue<string>(), failure.UserMessage);
        Assert.Equal(failure.UserMessage, failure.Message);
    }

    [Theory]
    [InlineData(ConnectorId.Ollama)]
    [InlineData(ConnectorId.LmStudio)]
    public async Task LocalWindowsSendTheReserveUsedByTheirBudget(ConnectorId id)
    {
        var catalog = Catalog();
        var connector = new ScriptedConnector(id, (_, model, _) => Task.FromResult(new RawCompletion(null, new JsonObject { ["clips"] = new JsonArray() }, model, new StopKind.Complete(), null, null))) { ContextTokens = 4096 };
        var finder = new ClipFinder(catalog, new MemoryKeys(null), new Redactor(), _ => connector);
        var input = new ClipFinderRequest(Words(1000), new Dictionary<string, string>(), new HashSet<string>(), ClipPreset.Best, "", "en", id, "local-4096");
        await finder.FindClipsAsync(input, null, TestContext.Current.CancellationToken);
        Assert.NotEmpty(connector.Requests);
        Assert.All(connector.Requests, request => Assert.Equal(1024, request.MaxOutputTokens));
        var prompts = new ClipPrompts(catalog);
        var lines = ClipText.Lines(ClipText.Entries(input.Words, input.Corrections));
        var tighten = prompts.Plan(lines, "normal", "", input.Words[^1].End, 4096, 4096, tighten: true, localServer: true, model: "local-4096");
        Assert.Equal(1024, tighten.OutputReserve);
        Assert.True(tighten.Budget >= 600);
        Assert.Equal(1024, prompts.TightenRequest(tighten.Windows[0].Lines, "I", "en", tighten.OutputReserve).MaxOutputTokens);
        using var handler = new StubHttp((message, _, _) => Task.FromResult(Response(200, message.RequestUri!.AbsolutePath == "/api/show" ? "{\"model_info\":{\"local.context_length\":4096},\"capabilities\":[\"completion\"]}" : Completion(id))));
        using var client = new HttpClient(handler);
        var http = new LlmConnector(id, catalog, client, new MemoryKeys(null), new Redactor());
        await http.SendAsync(connector.Requests[0], "local-4096", TestContext.Current.CancellationToken);
        var body = handler.Requests[^1].Body!;
        Assert.Equal(1024, id == ConnectorId.Ollama ? body["options"]!["num_predict"]!.GetValue<int>() : body["max_tokens"]!.GetValue<int>());
    }

    [Fact]
    public void PlannerContextErrorNamesTheSelectedModel()
    {
        var prompts = new ClipPrompts(Catalog());
        var lines = ClipText.Lines(ClipText.Entries(Words(20), new Dictionary<string, string>()));
        var failure = Assert.Throws<LlmException>(() => prompts.Plan(lines, "best", "", 20, 1000, 4096, model: "tiny-model"));
        Assert.Equal("tiny-model", failure.Error.Model);
        Assert.Contains("for tiny-model.", failure.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(ConnectorId.OpenAI, false)]
    [InlineData(ConnectorId.OpenAI, true)]
    [InlineData(ConnectorId.Ollama, false)]
    [InlineData(ConnectorId.Ollama, true)]
    [InlineData(ConnectorId.LmStudio, false)]
    [InlineData(ConnectorId.LmStudio, true)]
    public async Task ModelRefreshDistinguishesItsDeadlineFromCallerCancel(ConnectorId id, bool cancel)
    {
        var catalog = Catalog();
        catalog.Data["policy"]!["timeoutsSeconds"]!["modelList"] = cancel ? 10 : 0.05;
        using var handler = new StubHttp(async (_, _, token) => { await Task.Delay(Timeout.InfiniteTimeSpan, token); return Response(200, "{}"); });
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(id, catalog, client, new MemoryKeys(), new Redactor());
        using var cancellation = new CancellationTokenSource();
        if (cancel) cancellation.CancelAfter(50);
        if (cancel || id is ConnectorId.Ollama or ConnectorId.LmStudio)
        {
            var failure = await Assert.ThrowsAsync<LlmException>(() => connector.GetModelsAsync(true, cancellation.Token));
            Assert.Equal(cancel ? LlmErrorKind.Cancelled : LlmErrorKind.Timeout, failure.Error.Kind);
        }
        else Assert.NotEmpty(await connector.GetModelsAsync(true, cancellation.Token));
        if (cancel) Assert.Null(connector.LastRefreshError);
        else Assert.Contains("took too long", connector.LastRefreshError!, StringComparison.Ordinal);
        Assert.Single(handler.Requests);
    }

    [Theory]
    [InlineData(ConnectorId.Ollama)]
    [InlineData(ConnectorId.LmStudio)]
    public async Task LocalStatusTimeoutIsNotUserCancellation(ConnectorId id)
    {
        var catalog = Catalog();
        catalog.Data["policy"]!["timeoutsSeconds"]!["status"] = 0.05;
        using var handler = new StubHttp(async (_, _, token) => { await Task.Delay(Timeout.InfiniteTimeSpan, token); return Response(200, "{}"); });
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(id, catalog, client, new MemoryKeys(), new Redactor());
        Assert.IsType<ConnectorStatus.NotRunning>(await connector.GetStatusAsync(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ModelRefreshKeepsTheLastGoodCacheAfterTimeout()
    {
        var catalog = Catalog();
        catalog.Data["policy"]!["timeoutsSeconds"]!["modelList"] = 0.05;
        using var handler = new StubHttp(async (_, number, token) =>
        {
            if (number > 1) await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return Response(200, "{\"data\":[{\"id\":\"gpt-custom\"}]}");
        });
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, catalog, client, new MemoryKeys(), new Redactor());
        var first = await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
        var second = await connector.GetModelsAsync(true, TestContext.Current.CancellationToken);
        Assert.Equal(first, second);
        Assert.Contains("took too long", connector.LastRefreshError!, StringComparison.Ordinal);
    }

    [Fact]
    public async Task EachAttemptHasItsOwnTimeoutAndBackoffUsesOnlyCallerToken()
    {
        var tokens = new List<CancellationToken>();
        var started = Enumerable.Range(0, 3).Select(_ => new TaskCompletionSource<CancellationToken>(TaskCreationOptions.RunContinuationsAsynchronously)).ToArray();
        var release = Enumerable.Range(0, 3).Select(_ => new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).ToArray();
        using var caller = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        using var handler = new StubHttp(async (_, number, token) =>
        {
            started[number - 1].SetResult(token);
            await release[number - 1].Task.WaitAsync(token);
            return Response(number < 3 ? 500 : 200, number < 3 ? "{}" : Completion(ConnectorId.OpenAI));
        });
        using var client = new HttpClient(handler);
        var keys = new AttemptKeys();
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, keys, new Redactor(), (_, token) => { tokens.Add(token); return Task.CompletedTask; });
        var pending = connector.SendAsync(Request(ConnectorId.OpenAI) with { Timeout = TimeSpan.FromSeconds(30) }, "gpt-custom", caller.Token);
        for (var attempt = 0; attempt < started.Length; attempt++)
        {
            var token = await started[attempt].Task.WaitAsync(caller.Token);
            Assert.True(token.CanBeCanceled);
            Assert.False(token.IsCancellationRequested);
            release[attempt].SetResult();
        }
        await pending;
        Assert.Equal(3, handler.Requests.Count);
        Assert.Equal(3, keys.Tokens.Count);
        Assert.Equal(3, keys.Tokens.Distinct().Count());
        Assert.All(keys.Tokens, token => Assert.NotEqual(caller.Token, token));
        Assert.Equal(2, tokens.Count);
        Assert.All(tokens, token => Assert.Equal(caller.Token, token));
    }

    private sealed class AttemptKeys : IKeyProvider
    {
        internal List<CancellationToken> Tokens { get; } = [];
        public Task<string?> GetKeyAsync(string account, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            Tokens.Add(ct);
            return Task.FromResult<string?>("test-placeholder-value");
        }
    }

    [Theory]
    [InlineData(400, "{}", LlmErrorKind.BadRequest)]
    [InlineData(401, "{}", LlmErrorKind.Unauthorized)]
    [InlineData(403, "{}", LlmErrorKind.Unauthorized)]
    [InlineData(404, "{}", LlmErrorKind.ModelNotFound)]
    [InlineData(429, "{\"error\":{\"code\":\"insufficient_quota\"}}", LlmErrorKind.QuotaExceeded)]
    public async Task LongRetryHintNeverOverridesNonRetryableErrors(int status, string body, LlmErrorKind expected)
    {
        using var handler = new StubHttp((_, _, _) => { var response = Response(status, body); response.Headers.TryAddWithoutValidation("retry-after", "60"); return Task.FromResult(response); });
        using var client = new HttpClient(handler);
        var catalog = Catalog();
        var connector = new LlmConnector(ConnectorId.OpenAI, catalog, client, new MemoryKeys(), new Redactor());
        var failure = await Assert.ThrowsAsync<LlmException>(() => new LlmRunner(new MemoryKeys(), catalog, new Redactor()).RunAsync(Request(ConnectorId.OpenAI), connector, "gpt-5.6-terra", TestContext.Current.CancellationToken));
        Assert.Equal(expected, failure.Error.Kind);
        Assert.Single(handler.Requests);
    }

    [Theory]
    [InlineData(ConnectorId.Ollama)]
    [InlineData(ConnectorId.LmStudio)]
    public async Task RealSharedTransportDoesNotFollowRedirects(ConnectorId id)
    {
        using var first = new TcpListener(IPAddress.Loopback, 0);
        using var second = new TcpListener(IPAddress.Loopback, 0);
        first.Start(); second.Start();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var serve = Task.Run(async () =>
        {
            using var socket = await first.AcceptTcpClientAsync(deadline.Token);
            var stream = socket.GetStream();
            using var reader = new StreamReader(stream, leaveOpen: true);
            while (!string.IsNullOrEmpty(await reader.ReadLineAsync(deadline.Token))) { }
            var response = $"HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:{((IPEndPoint)second.LocalEndpoint).Port}/stolen\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(response), deadline.Token);
        }, deadline.Token);
        var connector = new LlmConnector(id, Catalog(), LlmRuntime.Http, new MemoryKeys(), new Redactor(), baseUrl: $"http://127.0.0.1:{((IPEndPoint)first.LocalEndpoint).Port}");
        var failure = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Request(id), "model", deadline.Token));
        Assert.Equal(LlmErrorKind.BadRequest, failure.Error.Kind);
        await serve;
        Assert.False(second.Pending());
    }

    [Theory]
    [InlineData(LlmFeature.ClipFinder, "clipFinder")]
    [InlineData(LlmFeature.AiTighten, "aiTighten")]
    [InlineData(LlmFeature.Test, "test")]
    public async Task HttpAttemptsLogCanonicalFeatureIds(LlmFeature feature, string wire)
    {
        var log = new CaptureLog();
        using var handler = new StubHttp((_, _, _) => Task.FromResult(Response(200, Completion(ConnectorId.OpenAI))));
        using var client = new HttpClient(handler);
        var connector = new LlmConnector(ConnectorId.OpenAI, Catalog(), client, new MemoryKeys(), new Redactor(), onDiagnostic: message => log.Write(VoxClip.Core.Services.Logging.LogLevel.Info, "llm", message));
        await connector.SendAsync(Request(ConnectorId.OpenAI) with { Feature = feature }, "model", TestContext.Current.CancellationToken);
        Assert.Contains("feature=" + wire + " ", Assert.Single(log.Lines), StringComparison.Ordinal);
    }
}
