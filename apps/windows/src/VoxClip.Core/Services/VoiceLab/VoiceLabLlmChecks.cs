using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>What the Voice Lab LLM sends share (ai.md §12.8): the nonbillable preflight, the estimate, the prompt binding and the
/// check of the reply's model and stop.</summary>
internal static class VoiceLabLlmChecks
{
    /// <summary>ai.md §12.8: a model id is 1 to 256 UTF-8 bytes of well-formed text with no control character (Cc).</summary>
    internal static bool IsValidModel(string? model) => model is not null && string.Equals(EditingAlgorithms.WellFormed(model), model, StringComparison.Ordinal) &&
        Encoding.UTF8.GetByteCount(model) is >= 1 and <= 256 && !model.Any(char.IsControl);

    /// <summary>ai.md §12.8: the output cap is the prompt's, the connector's, or 512 tokens and at least one and a half times the
    /// source, whichever is least. It is null when that cannot hold the source.</summary>
    internal static int? MaxOutputTokens(int sourceTokens, int promptCap, int? connectorCap)
    {
        var cap = Math.Min(Math.Min(promptCap, connectorCap ?? promptCap), Math.Max(512, (int)Math.Ceiling(sourceTokens * 1.5)));
        return cap >= sourceTokens ? cap : null;
    }

    /// <summary>ai.md §12.8: what a send needs, <c>est()</c> of its whole text and compact schema, plus its output cap and 64 tokens.</summary>
    internal static int RequiredTokens(LlmCatalog catalog, LlmRequest request) =>
        catalog.Estimate(request.System + request.CachedBlock + request.Instruction + request.Schema.ToJsonString()) + request.MaxOutputTokens + 64;

    /// <summary>ai.md §12.8: a send fits a context of at least 512 tokens when it needs at most ⌊context × safety factor⌋, the
    /// product taken in binary64.</summary>
    internal static bool ContextFits(int context, int required, double safetyFactor) => context >= 512 && required <= (int)Math.Floor(context * safetyFactor);

    internal static void CheckContext(LlmCatalog catalog, LlmRequest request, string model, int context)
    {
        if (!ContextFits(context, RequiredTokens(catalog, request), catalog.Data["policy"]!["tokenEstimate"]!["contextSafetyFactor"]!.GetValue<double>()))
            throw LlmErrors.Create(LlmErrorKind.ContextTooLong, "", model, LlmFeature.VoiceRewrite);
    }

    internal static LlmException StatusFailure(LlmCatalog catalog, ConnectorStatus status, ConnectorId connector, string model)
    {
        var kind = status switch
        {
            ConnectorStatus.NeedsKey => LlmErrorKind.MissingKey,
            ConnectorStatus.NotRunning => LlmErrorKind.NotRunning,
            ConnectorStatus.NoModels => LlmErrorKind.NoModels,
            ConnectorStatus.CliMissing => LlmErrorKind.CliMissing,
            ConnectorStatus.CliTooOld => LlmErrorKind.CliTooOld,
            ConnectorStatus.CliSignedOut => LlmErrorKind.CliSignedOut,
            _ => LlmErrorKind.Unavailable
        };
        var detail = status switch
        {
            ConnectorStatus.NotRunning local => local.Url,
            ConnectorStatus.CliTooOld old => old.Version,
            ConnectorStatus.CliMissing => catalog.Provider(connector)["cli"]?["installHint"]?.GetValue<string>(),
            ConnectorStatus.Unavailable unavailable => unavailable.Reason,
            _ => null
        };
        return LlmErrors.Create(kind, catalog.Provider(connector)["label"]!.GetValue<string>(), model, LlmFeature.VoiceRewrite, detail: detail);
    }

    /// <summary>The quote's estimate (voice-lab §8.1 and §8.9.1): <c>est()</c> of the whole rendered request (ai.md §11.5), in
    /// tokens, with no known price.</summary>
    internal static VoiceLabEstimate Estimate(LlmCatalog catalog, ConnectorId connector, VoiceLabOperation operation, LlmRequest request) =>
        new(LlmCatalog.WireId(connector), operation, catalog.Estimate(request.System + request.CachedBlock + request.Instruction), "token",
            null, null, "unknown");

    /// <summary>Reads a shared prompt file once: its JSON, read as <see cref="LlmCatalog.ReadAsset"/> reads an asset, and the SHA-256
    /// of its bytes after CRLF→LF, which the quote binds (voice-lab §8.1), so any edit to the file refuses an earlier quote while a
    /// checkout's line endings do not.</summary>
    internal static (JsonObject Document, string Sha256) ReadPrompt(LlmCatalog catalog, string relative)
    {
        try
        {
            var bytes = File.ReadAllBytes(Path.Combine(catalog.SharedRoot, relative));
            using var reader = new StreamReader(new MemoryStream(bytes), Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            var document = JsonNode.Parse(reader.ReadToEnd())!.AsObject();
            if (document["schemaVersion"]?.GetValue<int>() != 1) throw new JsonException();
            var normal = new List<byte>(bytes.Length);
            for (var index = 0; index < bytes.Length; index++)
                if (bytes[index] != 0x0D || index + 1 == bytes.Length || bytes[index + 1] != 0x0A) normal.Add(bytes[index]);
            return (document, VoiceLabActionGate.ContentHash(normal.ToArray()));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        }
    }

    /// <summary>ai.md §12.8: the answering model must be the quoted one. Claude Code's curated models are aliases, so there
    /// <c>sonnet</c>, <c>opus</c> or <c>haiku</c> accepts an id starting <c>claude-&lt;alias&gt;-</c> and <c>default</c> any
    /// <c>claude-</c> id. An HTTP connector also takes a dated snapshot of the selected id, <c>&lt;selected&gt;-YYYY-MM-DD</c> or
    /// <c>&lt;selected&gt;-YYYYMMDD</c>. Every other answer needs the exact id. Ids compare ordinally.</summary>
    internal static bool AnsweredBy(ConnectorId connector, string selected, string answered) =>
        string.Equals(answered, selected, StringComparison.Ordinal) || connector switch
        {
            ConnectorId.ClaudeCode => selected == "default"
                ? answered.StartsWith("claude-", StringComparison.Ordinal)
                : selected is "sonnet" or "opus" or "haiku" && answered.StartsWith("claude-" + selected + "-", StringComparison.Ordinal),
            ConnectorId.Anthropic or ConnectorId.OpenAI or ConnectorId.Xai or ConnectorId.Gemini or ConnectorId.Ollama or ConnectorId.LmStudio =>
                answered.Length > selected.Length + 1 && answered.StartsWith(selected + "-", StringComparison.Ordinal) && IsSnapshotDate(answered[(selected.Length + 1)..]),
            _ => false
        };

    /// <summary><c>YYYY-MM-DD</c> or <c>YYYYMMDD</c> in ASCII digits, a date of the Gregorian calendar: 29 February only in a year
    /// divisible by 4 and not by 100, or by 400.</summary>
    internal static bool IsSnapshotDate(string suffix)
    {
        var digits = suffix.Length == 10 && suffix[4] == '-' && suffix[7] == '-' ? string.Concat(suffix.AsSpan(0, 4), suffix.AsSpan(5, 2), suffix.AsSpan(8, 2)) :
            suffix.Length == 8 ? suffix : null;
        if (digits is null || !digits.All(char.IsAsciiDigit)) return false;
        int Number(int start, int length) => digits.Substring(start, length).Aggregate(0, (value, digit) => value * 10 + (digit - '0'));
        int year = Number(0, 4), month = Number(4, 2), day = Number(6, 2);
        var leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
        int[] lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        return month is >= 1 and <= 12 && day >= 1 && day <= lengths[month - 1];
    }

    /// <summary>A reply from another model is invalid output; then an incomplete reply is truncated and a refusal is refused, with
    /// the shared "declined to rewrite" copy. There is no retry.</summary>
    internal static void CheckAnswer(ConnectorId connector, string model, RawCompletion answer)
    {
        if (!AnsweredBy(connector, model, answer.Model)) throw LlmErrors.Create(LlmErrorKind.InvalidOutput, "", model, LlmFeature.VoiceRewrite);
        if (answer.Stop is StopKind.Truncated) throw LlmErrors.Create(LlmErrorKind.Truncated, "", model, LlmFeature.VoiceRewrite);
        if (answer.Stop is StopKind.Refused refused) throw LlmErrors.Create(LlmErrorKind.Refused, "", model, LlmFeature.VoiceRewrite, detail: refused.Category);
    }
}
