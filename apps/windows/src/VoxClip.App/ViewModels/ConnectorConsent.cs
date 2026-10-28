using VoxClip.Core.Services.LLM;

namespace VoxClip.App.ViewModels;

internal enum ConnectorConsentAction { FindClips, Rewrite, Test }

internal static class ConnectorConsent
{
    internal static string? Text(ConnectorConsentAction action, ConnectorId id, string label, int words, CliDetectionInfo? detection)
    {
        if (id is not (ConnectorId.ClaudeCode or ConnectorId.Codex)) return action switch
        {
            ConnectorConsentAction.FindClips => $"Find clips sends this project's transcript ({words} words, no audio or video) to {label} using your API key.",
            ConnectorConsentAction.Rewrite => $"Rewrite sends these {words} words (no audio or video) to {label} using your API key.",
            _ => $"Test sends a short test request to {label} using your API key. Nothing from your projects is sent."
        };
        if (detection?.AuthMethod is not { Length: > 0 } method ||
            !detection.UsesApiKey && method is not ("oauth" or "claudeAi" or "claude.ai" or "chatgpt")) return null;
        var claude = id == ConnectorId.ClaudeCode;
        var cli = claude ? "Claude Code" : "Codex";
        var provider = claude ? "Anthropic" : "OpenAI";
        var plan = claude ? "Claude" : "ChatGPT";
        var subject = action switch { ConnectorConsentAction.Rewrite => "These words are sent", ConnectorConsentAction.Test => "A short test request is sent", _ => "The transcript is sent" };
        var verb = action == ConnectorConsentAction.Rewrite ? "count" : "counts";
        var billing = detection.UsesApiKey ? $" and billed to the API key {cli} is signed in with." : $" and {verb} toward your {plan} plan's usage.";
        return $"VoxClip will run your installed {cli} with your own sign-in. {subject} to {provider}" + billing;
    }
}
