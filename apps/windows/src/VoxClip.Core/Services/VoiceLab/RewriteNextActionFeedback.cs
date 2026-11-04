#pragma warning disable CS1591
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

/// <summary>The feedback a next step sends back through the Rewrite request's feedback (voice-lab.md §8.2.1). Every string
/// comes from <c>shared/prompts/rewrite-next-actions.json</c>; placeholders are filled in one pass, so user and AI words are
/// never read as placeholders.</summary>
public static class RewriteNextActionFeedback
{
    public const string PromptPath = "prompts/rewrite-next-actions.json";

    /// <summary>Budget figures for the <see cref="RewriteBlockedReason.Budget"/> reason.</summary>
    public sealed record Budget(int VoiceWords, int ScopeWords);

    /// <summary>"REQUESTED FIX … Blocked phrases: …": the instruction applied to <paramref name="phrases"/> only.</summary>
    public static string Scoped(string instruction, IReadOnlyList<RewriteBlockedPhrase> phrases, Budget? budget, LlmCatalog catalog)
    {
        var templates = Templates(catalog);
        var request = Checked(instruction);
        if (phrases.Count == 0 || phrases.Count > RewriteNextAction.MaximumOrdinals || phrases.Select(phrase => phrase.Ordinal).Distinct().Count() != phrases.Count ||
            phrases.Any(phrase => phrase.Ordinal <= 0)) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var lines = phrases.Select(phrase =>
        {
            var key = phrase.Reason.ToString().ToLowerInvariant();
            if (templates["reasons"]?[key] is not JsonValue reasonValue || !reasonValue.TryGetValue<string>(out var reasonTemplate)) throw Missing();
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            if (phrase.Reason == RewriteBlockedReason.Fit)
            {
                if (phrase.EstimateSeconds is not { } estimate || phrase.SlotSeconds is not { } slot || !double.IsFinite(estimate) || !double.IsFinite(slot))
                    throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
                values["estimateSeconds"] = EditingFormat.ToFixed1(estimate);
                values["slotSeconds"] = EditingFormat.ToFixed1(slot);
            }
            else if (phrase.Reason == RewriteBlockedReason.Budget)
            {
                if (budget is null) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
                values["voiceWords"] = budget.VoiceWords.ToString(CultureInfo.InvariantCulture);
                values["scopeWords"] = budget.ScopeWords.ToString(CultureInfo.InvariantCulture);
            }
            return Fill(Template(templates, "scopedPhraseLine"), new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["ordinal"] = phrase.Ordinal.ToString(CultureInfo.InvariantCulture), ["reason"] = Fill(reasonTemplate, values),
                ["original"] = phrase.Original, ["proposed"] = phrase.Proposed,
            });
        }).ToArray();
        var block = Fill(Template(templates, "scopedFeedbackBlock"), new Dictionary<string, string>(StringComparer.Ordinal)
            { ["instruction"] = request, ["phrases"] = string.Join("\n\n", lines) });
        if (Encoding.UTF8.GetByteCount(block) > 20_000) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return block;
    }

    /// <summary>"REQUESTED FIX …" with no phrases: a failed or stale Rewrite asked again with the user's words.</summary>
    public static string Open(string instruction, LlmCatalog catalog) =>
        Fill(Template(Templates(catalog), "openFeedbackBlock"), new Dictionary<string, string>(StringComparer.Ordinal) { ["instruction"] = Checked(instruction) });

    /// <summary>The "Merge with phrase {first}" instruction for two phrases too close to voice separately.</summary>
    public static string Merge(int first, int second, LlmCatalog catalog)
    {
        if (first <= 0 || second <= first) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return Fill(Template(Templates(catalog), "mergeInstruction"), new Dictionary<string, string>(StringComparer.Ordinal)
            { ["first"] = first.ToString(CultureInfo.InvariantCulture), ["second"] = second.ToString(CultureInfo.InvariantCulture) });
    }

    /// <summary>The built-in "Change fewer words" instruction for a budget of <paramref name="limit"/> re-voiced words.</summary>
    public static string FewerWords(int limit, LlmCatalog catalog)
    {
        if (limit < 0) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return Fill(Template(Templates(catalog), "fewerWordsInstruction"), new Dictionary<string, string>(StringComparer.Ordinal)
            { ["limit"] = limit.ToString(CultureInfo.InvariantCulture) });
    }

    static JsonObject Templates(LlmCatalog catalog) =>
        VoiceLabLlmChecks.ReadPrompt(catalog, PromptPath).Document["request"] as JsonObject ?? throw Missing();
    static string Template(JsonObject templates, string key) =>
        templates[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : throw Missing();
    static string Checked(string instruction)
    {
        var text = EditingAlgorithms.JsTrim(instruction);
        if (text.Length == 0 || Encoding.UTF8.GetByteCount(text) > RewriteNextAction.MaximumInstructionBytes || RewriteNextAction.HasControl(text, true))
            throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return text;
    }
    static string Fill(string template, IReadOnlyDictionary<string, string> values) =>
        Regex.Replace(template, "\\{([A-Za-z]+)\\}", match => values.TryGetValue(match.Groups[1].Value, out var value) ? value : match.Value, RegexOptions.CultureInvariant);
    static VoxClipException Missing() => new(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
}
