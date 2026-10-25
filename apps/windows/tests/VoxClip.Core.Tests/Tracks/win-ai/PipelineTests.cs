using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Services.LLM;
using Xunit;
using static VoxClip.Core.Tests.Tracks.WinAi.AiTestSupport;

namespace VoxClip.Core.Tests.Tracks.WinAi;

[Trait("Track", "win-ai")]
public sealed class PipelineTests
{
    private static ClipFinderRequest Input(int count = 100) => new(Words(count), new Dictionary<string, string>(), new HashSet<string>(), ClipPreset.Best, "  Funny bits  ", "en", ConnectorId.OpenAI, "gpt-5.6-terra", Snap: false);
    private static RawCompletion Clips(string model, int start = 0, int end = 20, string title = "Clip") => new(null,
        new JsonObject { ["clips"] = new JsonArray(new JsonObject { ["title"] = title, ["reason"] = "A complete thought.", ["score"] = 9, ["start_word"] = start, ["end_word"] = end }) }, model, new StopKind.Complete(), null, null);

    [Fact]
    public async Task EarlierFallbackIsRetainedWhenLaterWindowsUseThePrimary()
    {
        var catalog = Catalog();
        var primary = catalog.Provider(ConnectorId.OpenAI)["defaultModel"]!.GetValue<string>();
        var fallback = catalog.Fallback(ConnectorId.OpenAI, primary)!;
        var first = true;
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, model, _) =>
        {
            if (first && model == primary) { first = false; throw LlmErrors.Create(LlmErrorKind.Overloaded, "OpenAI"); }
            return Task.FromResult(Clips(model));
        });
        var finder = new ClipFinder(catalog, new MemoryKeys(), new Redactor(), _ => connector);
        Assert.Null(finder.LastUsedFallback);
        var result = await finder.FindClipsAsync(Input(9000) with { Model = primary }, null, TestContext.Current.CancellationToken);
        Assert.Equal(3, connector.Requests.Count);
        Assert.Equal(fallback, result.Model);
        Assert.True(finder.LastUsedFallback);
        var next = await finder.FindClipsAsync(Input() with { Model = primary }, null, TestContext.Current.CancellationToken);
        Assert.Equal(primary, next.Model);
        Assert.False(finder.LastUsedFallback);
        await finder.FindClipsAsync(Input() with { DryRun = true }, null, TestContext.Current.CancellationToken);
        Assert.Null(finder.LastUsedFallback);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(129)]
    public async Task UnusableAnsweringModelUsesTheRequestedId(int length)
    {
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => Task.FromResult(Clips(new string('x', length))));
        var finder = new ClipFinder(Catalog(), new MemoryKeys(), new Redactor(), _ => connector);
        var input = Input();
        var result = await finder.FindClipsAsync(input, null, TestContext.Current.CancellationToken);
        Assert.Equal(input.Model, result.Model);
        Assert.False(finder.LastUsedFallback);
    }

    [Fact]
    public async Task ResultHashAndIdsUseTheWholeTakeAndPreserveEdits()
    {
        var catalog = Catalog();
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, model, _) => Task.FromResult(Clips(model, title: " \ufeff ")));
        var input = Input();
        var corrections = new Dictionary<string, string> { ["w2"] = "corrected" };
        var cuts = new HashSet<string> { "w3" };
        input = input with { Corrections = corrections, CutWordIds = cuts };
        var finder = new ClipFinder(catalog, new MemoryKeys(null), new Redactor(), _ => connector);
        var result = await finder.FindClipsAsync(input, null, TestContext.Current.CancellationToken);
        Assert.Equal("Funny bits", result.Instructions);
        Assert.Equal("openai", result.Provider);
        Assert.Equal("w0", Assert.Single(result.Clips).StartWordId);
        Assert.Equal("w20", result.Clips[0].EndWordId);
        Assert.StartsWith("w0 w1 corrected", result.Clips[0].Title, StringComparison.Ordinal);
        var prompts = new ClipPrompts(catalog);
        var block = prompts.Block(ClipText.Lines(ClipText.Entries(input.Words, corrections)));
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(block))), result.InputSha256);
        Assert.Equal("corrected", Assert.Single(corrections).Value);
        Assert.Equal("w3", Assert.Single(cuts));
    }

    [Fact]
    public async Task DryRunRendersWithoutStatusContextOrGeneration()
    {
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, _, _) => throw new InvalidOperationException());
        var finder = new ClipFinder(Catalog(), new MemoryKeys(null), new Redactor(), _ => connector);
        var result = await finder.FindClipsAsync(Input(9000) with { DryRun = true }, null, TestContext.Current.CancellationToken);
        Assert.Empty(result.Clips);
        Assert.Equal(0, connector.StatusCalls);
        Assert.Equal(0, connector.ContextCalls);
        Assert.Empty(connector.Requests);
        Assert.Equal(2, finder.DryRunRequests.Count);
        Assert.Contains("[0-40]", finder.DryRunRequests[0].CachedBlock!, StringComparison.Ordinal);
        Assert.DoesNotContain("[0-40]", finder.DryRunRequests[1].CachedBlock!, StringComparison.Ordinal);
    }

    [Fact]
    public async Task FailedPreflightDoesNotProbeContext()
    {
        var connector = new ScriptedConnector(ConnectorId.Ollama, (_, _, _) => throw new InvalidOperationException()) { Status = new ConnectorStatus.NotRunning("http://127.0.0.1:11434") };
        var finder = new ClipFinder(Catalog(), new MemoryKeys(null), new Redactor(), _ => connector);
        var exception = await Assert.ThrowsAsync<LlmException>(() => finder.FindClipsAsync(Input() with { Connector = ConnectorId.Ollama }, null, TestContext.Current.CancellationToken));
        Assert.Equal(LlmErrorKind.NotRunning, exception.Error.Kind);
        Assert.Equal(0, connector.ContextCalls);
        Assert.Empty(connector.Requests);
    }

    [Fact]
    public async Task WindowsAndConcurrentRunsAreSequential()
    {
        var active = 0;
        var maximum = 0;
        var connector = new ScriptedConnector(ConnectorId.OpenAI, async (_, model, ct) =>
        {
            maximum = Math.Max(maximum, Interlocked.Increment(ref active));
            await Task.Delay(5, ct);
            Interlocked.Decrement(ref active);
            return Clips(model);
        });
        var finder = new ClipFinder(Catalog(), new MemoryKeys(null), new Redactor(), _ => connector);
        await Task.WhenAll(finder.FindClipsAsync(Input(9000), null, TestContext.Current.CancellationToken), finder.FindClipsAsync(Input(9000), null, TestContext.Current.CancellationToken));
        Assert.Equal(1, maximum);
        Assert.Equal(4, connector.Requests.Count);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LaterFailureOrCancelReturnsNoPartialResult(bool cancel)
    {
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var sends = 0;
        var connector = new ScriptedConnector(ConnectorId.OpenAI, (_, model, _) =>
        {
            if (++sends == 1) return Task.FromResult(Clips(model));
            if (cancel) { cancellation.Cancel(); throw new OperationCanceledException(cancellation.Token); }
            throw LlmErrors.Create(LlmErrorKind.Server, "OpenAI", status: 500);
        });
        var finder = new ClipFinder(Catalog(), new MemoryKeys(null), new Redactor(), _ => connector);
        var input = Input(9000);
        var exception = await Assert.ThrowsAsync<LlmException>(() => finder.FindClipsAsync(input, null, cancellation.Token));
        Assert.Equal(cancel ? LlmErrorKind.Cancelled : LlmErrorKind.Server, exception.Error.Kind);
        Assert.Empty(input.CutWordIds);
        Assert.Empty(input.Corrections);
        Assert.Equal(2, sends);
    }

    [Theory]
    [InlineData("sonnet", "claude-sonnet-5-5", false)]
    [InlineData("claude-sonnet-5-5", "claude-sonnet-5-5-20261021", false)]
    [InlineData("sonnet", "claude-haiku-5-5", true)]
    [InlineData("default", "claude-sonnet-5-5", false)]
    public async Task ClaudeAliasesAreNotMistakenForFallback(string selected, string answering, bool fallback)
    {
        var connector = new ScriptedConnector(ConnectorId.ClaudeCode, (_, _, _) => Task.FromResult(new RawCompletion("{\"ok\":true,\"echo\":\"voxclip\"}", null, answering, new StopKind.Complete(), null, null)));
        var result = await new LlmRunner(new MemoryKeys(null), Catalog(), new Redactor()).RunAsync(Catalog().TestRequest(ConnectorId.ClaudeCode), connector, selected, TestContext.Current.CancellationToken);
        Assert.Equal(fallback, result.UsedFallback);
        Assert.Single(connector.Requests);
    }

    [Theory]
    [InlineData(ConnectorId.Ollama)]
    [InlineData(ConnectorId.LmStudio)]
    public async Task LocalServer503UsesProviderTaxonomy(ConnectorId id)
    {
        using var handler = new StubHttp((request, _, _) => Task.FromResult(request.RequestUri!.AbsolutePath == "/api/show" ? Response(200, "{\"capabilities\":[\"completion\"],\"model_info\":{\"model.context_length\":32768}}") : Response(503, "{\"error\":{\"message\":\"server busy\"}}")));
        using var http = new HttpClient(handler);
        var connector = new LlmConnector(id, Catalog(), http, new MemoryKeys(null), new Redactor(), (_, _) => Task.CompletedTask);
        var exception = await Assert.ThrowsAsync<LlmException>(() => connector.SendAsync(Catalog().TestRequest(id), "local", TestContext.Current.CancellationToken));
        Assert.Equal(id == ConnectorId.Ollama ? LlmErrorKind.Server : LlmErrorKind.Overloaded, exception.Error.Kind);
        Assert.Equal(id == ConnectorId.Ollama ? 4 : 3, handler.Requests.Count);
    }
}

internal sealed class ScriptedConnector(ConnectorId id, Func<LlmRequest, string, CancellationToken, Task<RawCompletion>> respond) : ILlmConnector
{
    public ConnectorId Id => id;
    internal ConnectorStatus Status { get; set; } = new ConnectorStatus.Ready();
    internal int StatusCalls { get; private set; }
    internal int ContextCalls { get; private set; }
    internal int ContextTokens { get; set; } = 128000;
    internal Func<string, CancellationToken, Task<int?>>? Context { get; init; }
    internal List<LlmRequest> Requests { get; } = [];
    public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); StatusCalls++; return Task.FromResult(Status); }
    public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>([]);
    public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) { ct.ThrowIfCancellationRequested(); ContextCalls++; return Context?.Invoke(model, ct) ?? Task.FromResult<int?>(ContextTokens); }
    public Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct) { Requests.Add(request); return respond(request, model, ct); }
}
