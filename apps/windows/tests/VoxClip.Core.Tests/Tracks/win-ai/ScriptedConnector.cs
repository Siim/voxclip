using System.Text.Json.Nodes;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Tests.Tracks.WinAi;

internal sealed class ScriptedConnector : ILlmConnector
{
    internal sealed class Exhausted : Exception;
    internal delegate Task<RawCompletion> Reply(LlmRequest request, string model, CancellationToken cancellationToken);

    private readonly List<LlmRequest> requests = [];
    private readonly Func<int, LlmRequest, string, CancellationToken, Task<RawCompletion>> respond;
    public ConnectorId Id { get; }
    internal string? AuthMethod { get; }
    public string? KnownCliAuthMethod => AuthMethod;
    internal ConnectorStatus Status { get; set; } = new ConnectorStatus.Ready();
    internal int StatusCalls { get; private set; }
    internal int ContextCalls { get; private set; }
    internal int ContextTokens { get; set; } = 128000;
    internal Func<string, CancellationToken, Task<int?>>? Context { get; init; }
    internal IReadOnlyList<LlmRequest> Requests { get { lock (requests) return requests.ToArray(); } }

    private ScriptedConnector(ConnectorId id, string? authMethod, Func<int, LlmRequest, string, CancellationToken, Task<RawCompletion>> respond)
    {
        Id = id;
        AuthMethod = authMethod;
        this.respond = respond;
    }

    internal ScriptedConnector(ConnectorId id, Func<LlmRequest, string, CancellationToken, Task<RawCompletion>> respond)
        : this(id, "plan", (_, request, model, ct) => respond(request, model, ct)) { }

    internal ScriptedConnector(IReadOnlyList<Reply> script, ConnectorId id = ConnectorId.ClaudeCode, string? authMethod = "plan")
        : this(id, authMethod, (index, request, model, ct) => index < script.Count ? script[index](request, model, ct) : throw new Exhausted()) { }

    internal ScriptedConnector(IEnumerable<JsonNode?> replies, ConnectorId id = ConnectorId.ClaudeCode, string? authMethod = "plan")
        : this(replies.Select<JsonNode?, Reply>(reply => (_, model, _) => Task.FromResult(
            new RawCompletion(null, reply?.DeepClone(), model, new StopKind.Complete(), null, null))).ToArray(), id, authMethod) { }

    public Task<ConnectorStatus> GetStatusAsync(CancellationToken ct) { ct.ThrowIfCancellationRequested(); StatusCalls++; return Task.FromResult(Status); }
    public Task<IReadOnlyList<LlmModel>> GetModelsAsync(bool refresh, CancellationToken ct) => Task.FromResult<IReadOnlyList<LlmModel>>([]);
    public Task<int?> GetContextTokensAsync(string model, CancellationToken ct) { ct.ThrowIfCancellationRequested(); ContextCalls++; return Context?.Invoke(model, ct) ?? Task.FromResult<int?>(ContextTokens); }

    public async Task<RawCompletion> SendAsync(LlmRequest request, string model, CancellationToken ct)
    {
        int index;
        lock (requests)
        {
            index = requests.Count;
            requests.Add(request);
        }
        return await respond(index, request, model, ct);
    }
}
