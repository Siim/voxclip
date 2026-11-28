#pragma warning disable CS1591

namespace VoxClip.Core.Services.LLM;

public sealed record AgentChatApproval
{
    public ConnectorId Connector { get; }
    public string Model { get; }
    public (decimal Minimum, decimal Maximum)? EstimatedUSD { get; }
    public string Action => "agentChat";
    public string Billing => $"Billed to your {(Connector is ConnectorId.OpenAI or ConnectorId.Codex ? "OpenAI" : "Anthropic")} key";
    internal string ThreadId { get; }
    private Guid Nonce { get; } = Guid.NewGuid();

    internal AgentChatApproval(ConnectorId connector, string model, (decimal Minimum, decimal Maximum)? estimatedUSD, string threadId)
    {
        Connector = connector;
        Model = model;
        EstimatedUSD = estimatedUSD;
        ThreadId = threadId;
    }

    internal static bool? UsesKey(string? auth, ConnectorId connector)
    {
        var method = auth?.Trim().ToLowerInvariant().Replace('-', '_').Replace('.', '_');
        if (method is "api_key" or "apikey") return true;
        if (method == "plan" || (connector == ConnectorId.ClaudeCode ? method is "claude_ai" or "claudeai" or "oauth" or "oauth_token" : method == "chatgpt")) return false;
        return null;
    }
}
