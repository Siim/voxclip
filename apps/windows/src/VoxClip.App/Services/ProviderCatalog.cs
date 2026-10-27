using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Services.LLM;

namespace VoxClip.App.Services;

internal sealed record ProviderEntry(ConnectorId Id, string WireId, string Label, string Group, string? Account, string DefaultModel, string DataFlow, JsonElement Metadata)
{
    internal bool Cloud => Group == "apiKey";
    internal bool Cli => Group == "cli";
    public override string ToString() => Label;
}

internal static class ProviderCatalog
{
    internal static async Task<IReadOnlyList<ProviderEntry>> ReadAsync(CancellationToken ct)
    {
        if (App.Services.SharedRoot is null) return [];
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(App.Services.SharedRoot, "catalog", "llm-providers.json"), ct));
        var entries = new List<ProviderEntry>();
        foreach (var entry in document.RootElement.GetProperty("connectors").EnumerateArray())
        {
            if (entry.TryGetProperty("enabled", out var enabled) && !enabled.GetBoolean()) continue;
            if (!entry.GetProperty("platforms").EnumerateArray().Any(platform => platform.GetString() == "windows")) continue;
            var id = entry.GetProperty("id").GetString()!;
            var connector = id switch { "anthropic" => ConnectorId.Anthropic, "openai" => ConnectorId.OpenAI, "xai" => ConnectorId.Xai, "gemini" => ConnectorId.Gemini, "ollama" => ConnectorId.Ollama, "lmstudio" => ConnectorId.LmStudio, "claude-code" => ConnectorId.ClaudeCode, "codex" => ConnectorId.Codex, _ => (ConnectorId?)null };
            if (connector is null) continue;
            var group = entry.GetProperty("group").GetString()!;
            var account = entry.TryGetProperty("auth", out var auth) && auth.TryGetProperty("keyAccount", out var key) ? key.GetString() : null;
            var dataFlow = group == "apiKey" ? "Sends transcript text only. No audio or video." : group == "cli" ? "Sends transcript text through your installed CLI. Counts toward your plan." : "Transcript text stays on this computer. No audio or video is sent.";
            if (id == "claude-code") dataFlow = "runs your installed Claude Code. " + dataFlow;
            entries.Add(new(connector.Value, id, entry.GetProperty("label").GetString()!, group, account,
                entry.TryGetProperty("defaultModel", out var model) ? model.GetString() ?? "" : "", dataFlow, entry.Clone()));
        }
        return entries;
    }

    /// <summary>A Find clips message from shared/prompts/clip-finder.json (AI spec §5: feature-level messages come from the prompt
    /// files' <c>messages</c> objects); null when the file can't be read.</summary>
    internal static async Task<string?> ClipMessageAsync(string key, CancellationToken ct)
    {
        if (App.Services.SharedRoot is null) return null;
        try
        {
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(App.Services.SharedRoot, "prompts", "clip-finder.json"), ct));
            return document.RootElement.TryGetProperty("messages", out var messages) && messages.TryGetProperty(key, out var message) ? message.GetString() : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    internal static string Status(ConnectorStatus status) => status switch
    {
        ConnectorStatus.Ready => "Ready", ConnectorStatus.NeedsKey => "Add an API key", ConnectorStatus.CliMissing => "Not installed. Install the CLI and sign in outside VoxClip.",
        ConnectorStatus.CliSignedOut => "Sign in in your terminal, then check again.", ConnectorStatus.CliTooOld => "Update your installed CLI, then check again.",
        ConnectorStatus.NotRunning => "Local server isn't running.", ConnectorStatus.NoModels => "No chat model installed.", _ => "Connector unavailable in this development build. No request was sent."
    };
    internal static string ShortStatus(ConnectorStatus status) => status switch
    {
        ConnectorStatus.Ready => "● Ready", ConnectorStatus.NeedsKey => "● Key missing",
        ConnectorStatus.NotRunning or ConnectorStatus.NoModels => "● Not running",
        ConnectorStatus.CliMissing => "● Not found", ConnectorStatus.CliSignedOut => "● Not signed in",
        ConnectorStatus.CliTooOld => "● Too old", _ => "● Unavailable"
    };

    internal static async Task TestAsync(ProviderEntry entry, string model, CancellationToken ct)
    {
        var connector = App.Services.Connector(entry.Id);
        var status = await connector.GetStatusAsync(ct);
        if (status is not ConnectorStatus.Ready) throw new InvalidOperationException("Connector is not ready.");
        var catalog = LlmCatalog.Load(App.Services.SharedRoot!);
        var result = await new LlmRunner(App.Services.Keys, catalog, new VoxClip.Core.Domain.Shared.Redactor()).TestAsync(connector, model, ct);
        if (!result.Passed) throw new InvalidDataException("The connector did not return the expected test response.");
    }

    internal static async Task<bool> ConsentAsync(ProviderEntry entry, Microsoft.UI.Xaml.XamlRoot root, CancellationToken ct)
    {
        if (!entry.Cloud && !entry.Cli || App.Services.Get("llm.cloudConsent." + entry.WireId, false)) return true;
        if (!await Controls.Ui.ConfirmAsync(root, "Use this connector?", entry.DataFlow + " Your media and edits stay here. You can change providers in Settings.", "Continue")) return false;
        await App.Services.SetAsync("llm.cloudConsent." + entry.WireId, true, ct);
        return true;
    }
}
