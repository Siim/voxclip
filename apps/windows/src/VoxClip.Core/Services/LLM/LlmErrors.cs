using System.Globalization;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Services.LLM;

internal static class LlmErrors
{
    internal static LlmException Create(LlmErrorKind kind, string label, string model = "", LlmFeature feature = LlmFeature.Test,
        int? status = null, string? detail = null, TimeSpan? retryAfter = null, IRedactor? redactor = null)
    {
        if (kind is LlmErrorKind.PlanLimit or LlmErrorKind.CliMissing or LlmErrorKind.CliTooOld or LlmErrorKind.CliSignedOut or LlmErrorKind.CliFailed)
            label = label.StartsWith("Claude Code", StringComparison.Ordinal) ? "Claude Code" : label.StartsWith("Codex", StringComparison.Ordinal) ? "Codex" : label;
        var safe = new Redactor().Redact((redactor ?? new Redactor()).Redact(detail ?? ""));
        safe = safe[..Math.Min(200, safe.Length)];
        var code = kind switch
        {
            LlmErrorKind.NoConnector or LlmErrorKind.MissingKey => VoxClipErrorCode.KeyMissing,
            LlmErrorKind.Unauthorized => VoxClipErrorCode.KeyRejected,
            LlmErrorKind.RateLimited or LlmErrorKind.PlanLimit or LlmErrorKind.Overloaded => VoxClipErrorCode.RateLimited,
            LlmErrorKind.Network => VoxClipErrorCode.Offline,
            LlmErrorKind.NoModels => VoxClipErrorCode.ModelMissing,
            LlmErrorKind.CliMissing or LlmErrorKind.CliTooOld => VoxClipErrorCode.CliNotInstalled,
            LlmErrorKind.CliSignedOut => VoxClipErrorCode.CliNotSignedIn,
            LlmErrorKind.InvalidOutput or LlmErrorKind.Truncated => VoxClipErrorCode.LlmInvalidOutput,
            LlmErrorKind.UnsupportedLanguage => VoxClipErrorCode.LocaleUnsupported,
            LlmErrorKind.Cancelled => VoxClipErrorCode.Cancelled,
            _ => VoxClipErrorCode.ProviderError
        };
        var message = kind switch
        {
            LlmErrorKind.NoConnector => "Choose how VoxClip finds clips: your API key, a model on this computer, or an installed CLI.",
            LlmErrorKind.MissingKey => $"Add your {label} API key in Settings › AI.",
            LlmErrorKind.Unauthorized => $"{label} rejected the API key. Check it in Settings › AI.",
            LlmErrorKind.QuotaExceeded => $"{label} says this account is out of credit or over its quota.",
            LlmErrorKind.RateLimited => $"{label} is rate limiting this key. " + (retryAfter is null ? "Try again in a minute." : $"Try again in {Math.Ceiling(retryAfter.Value.TotalSeconds).ToString(CultureInfo.InvariantCulture)} s."),
            LlmErrorKind.PlanLimit => $"Your {label} plan's usage limit is reached. {safe}",
            LlmErrorKind.Overloaded => $"{label} is overloaded right now. Try again shortly or pick another model.",
            LlmErrorKind.Server => $"{label} had a server error ({status}). Try again.",
            LlmErrorKind.Network => $"Couldn't reach {label}. Check your internet connection.",
            LlmErrorKind.Timeout => $"{label} took too long to answer. Try again, or pick a faster model.",
            LlmErrorKind.ModelNotFound => $"{label} doesn't offer the model \"{model}\" to this account. Pick another model or refresh the list.",
            LlmErrorKind.ContextTooLong => $"This transcript is too long for {model}. Pick a model with a larger context.",
            LlmErrorKind.BadRequest => $"{label} rejected the request ({status}): {safe}",
            LlmErrorKind.Refused => feature switch { LlmFeature.ClipFinder => "Clips could not be suggested for this recording.", LlmFeature.AiTighten => "The model declined to tighten this recording.", LlmFeature.VoiceRewrite => "The model declined to rewrite this recording.", _ => "The model declined the test request." },
            LlmErrorKind.Truncated => feature == LlmFeature.AiTighten ? "The tighten suggestions were incomplete. Please try again." : feature == LlmFeature.VoiceRewrite ? "The rewrite was incomplete. Please try again." : "The clip suggestions were incomplete. Please try again.",
            LlmErrorKind.InvalidOutput => "The model's answer wasn't in the expected format. Try again or pick another model.",
            LlmErrorKind.NotRunning => label == "Ollama" ? $"Ollama isn't running at {safe}. Start Ollama and try again." : $"LM Studio's server isn't running at {safe}. Start it from LM Studio's Developer tab.",
            LlmErrorKind.NoModels => label == "Ollama" ? "Ollama has no chat models. Run `ollama pull <model>`, then refresh." : "Load or download a model in LM Studio, then refresh.",
            LlmErrorKind.CliMissing => $"{label} isn't installed. {safe}",
            LlmErrorKind.CliTooOld => string.IsNullOrWhiteSpace(safe) || safe == "unknown" ? $"Your {label} is too old for VoxClip. Update it, then try again." : $"Your {label} {safe} is too old for VoxClip. Update it, then try again.",
            LlmErrorKind.CliSignedOut => label == "Claude Code" ? "Claude Code isn't signed in. Open Terminal, run claude, and sign in." : "Codex isn't signed in. Open Terminal and run codex login.",
            LlmErrorKind.CliFailed => $"{label} stopped with an error: {safe}",
            LlmErrorKind.Cancelled => "",
            _ => safe
        };
        if (kind != LlmErrorKind.Cancelled) message = message.TrimEnd() + " Your edits are saved.";
        message = (redactor ?? new Redactor()).Redact(message);
        return new(new(kind, code, message, status, retryAfter, model, safe));
    }
}
