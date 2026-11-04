using System.Text.Json;
using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

/// <summary>The chosen AI as the status bar and Settings name it, with the effort AI decisions send (AI §2.1).</summary>
public static class AiEffortLabel
{
    /// <summary>The effort AI decisions send on a catalog connector: Claude Code and Anthropic extra high, OpenAI, Gemini and the
    /// Codex default high; null for xAI and local servers, which ignore effort.</summary>
    public static Effort? DecisionEffort(JsonElement connector) =>
        EffortLevel.Resolve(EffortLevel.Decision, connector.TryGetProperty("effort", out var effort) && effort.ValueKind == JsonValueKind.Object
            && effort.TryGetProperty("values", out var values) && values.ValueKind == JsonValueKind.Array
                ? values.EnumerateArray().Select(value => value.GetString()).OfType<string>() : []);

    /// <summary>"Claude Code · Opus (latest) · extra high": the short name, the chosen model's catalog name (else its id) and the
    /// decision effort, each left out when empty.</summary>
    public static string Status(string shortName, JsonElement connector, string model)
    {
        var name = model;
        if (connector.TryGetProperty("models", out var models) && models.ValueKind == JsonValueKind.Array)
            foreach (var item in models.EnumerateArray())
                if (item.TryGetProperty("id", out var id) && id.GetString() == model && item.TryGetProperty("name", out var named)) name = named.GetString() ?? model;
        return string.Join(" · ", new[] { shortName, name, DecisionEffort(connector)?.Label() ?? "" }.Where(part => part.Length > 0));
    }

    /// <summary>Settings' line under the model: "AI decisions use extra high effort."; null when the connector ignores effort.</summary>
    public static string? SettingsNote(JsonElement connector) => DecisionEffort(connector) is { } effort ? $"AI decisions use {effort.Label()} effort." : null;
}
