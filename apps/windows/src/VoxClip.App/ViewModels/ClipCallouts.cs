using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

/// <summary>The Find clips callouts under the sidebar actions, with design §13's copy and actions. A connector that is not
/// ready reads as AI spec §5 words it, and every failure ends "Your edits are saved." (architecture §10.1 rule 1), as the
/// Core's own messages do.</summary>
public static class ClipCallouts
{
    public const string SetUp = "Set up AI…";
    public const string SignInHelp = "Sign-in help";
    public const string Retry = "Retry";
    private const string Saved = "Your edits are saved.";

    /// <summary>§13 "Clips: no connector".</summary>
    public static SidebarCallout NoConnector { get; } = new("Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.",
        "You can also select words and press Ctrl+K to make a clip yourself.", SetUp);

    /// <summary>The connector llm.connector names now (AI spec §11 gate 4), from the catalogue's entries; null when the setting
    /// is empty or names no connector this PC offers, which is §13 "Clips: no connector".</summary>
    public static T? Chosen<T>(string selected, IEnumerable<T> catalogue, Func<T, string> wireId) where T : class =>
        selected.Length == 0 ? null : catalogue.FirstOrDefault(entry => wireId(entry) == selected);

    /// <summary>A connector's name in copy: a CLI's short name, from its catalogue label ("Claude Code (installed CLI)" reads
    /// "Claude Code"); API-key and local connectors keep their label.</summary>
    public static string ConnectorName(string label, string group) =>
        group == "cli" && label.IndexOf(" (", StringComparison.Ordinal) is > 0 and var cut ? label[..cut] : label;

    /// <summary>The chosen connector is not ready when Find clips runs: §13's CLI and local-server rows, else the §5 message
    /// with Retry. <paramref name="label"/> is the catalogue label; the CLI rows use the short name.</summary>
    public static SidebarCallout NotReady(ConnectorId connector, string label, ConnectorStatus status, string? installHint, string? signInHint)
    {
        var cli = ConnectorName(label, "cli");
        var ollama = connector == ConnectorId.Ollama;
        return status switch
        {
            ConnectorStatus.CliMissing => Problem($"{cli} isn't installed. {installHint}", ""),
            ConnectorStatus.CliSignedOut => Problem($"{cli} isn't signed in. {signInHint}", SignInHelp),
            ConnectorStatus.NotRunning local => Problem(ollama ? $"Ollama isn't running at {local.Url}. Start Ollama and try again."
                : $"LM Studio's server isn't running at {local.Url}. Start it from LM Studio's Developer tab.", ""),
            ConnectorStatus.NeedsKey => Problem($"Add your {label} API key in Settings › {SettingsSections.ProvidersAndKeys}.", Retry),
            ConnectorStatus.NoModels => Problem(ollama ? "Ollama has no chat models. Run `ollama pull <model>`, then refresh." : "Load or download a model in LM Studio, then refresh.", Retry),
            ConnectorStatus.CliTooOld old => Problem(string.IsNullOrWhiteSpace(old.Version) || old.Version == "unknown"
                ? $"Your {cli} is too old for VoxClip. Update it, then try again." : $"Your {cli} {old.Version} is too old for VoxClip. Update it, then try again.", Retry),
            ConnectorStatus.Unavailable unavailable => Problem(unavailable.Reason, Retry),
            _ => Problem("", Retry)
        };
    }

    /// <summary>§13 "Clips: any other AI failure": the failure's §5 message, then "Your edits are saved.", with Retry.</summary>
    public static SidebarCallout Failed(string message) => Problem(message, Retry);

    private static SidebarCallout Problem(string message, string action)
    {
        message = message.Trim();
        if (!message.EndsWith(Saved, StringComparison.Ordinal)) message = $"{message} {Saved}".TrimStart();
        return new("", message, action);
    }
}
