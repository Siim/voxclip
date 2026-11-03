#pragma warning disable CS1591
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;
using VoxClip.Core.Services.LLM;

namespace VoxClip.Core.Services.VoiceLab;

internal static class VoiceRewriteFeedback
{
    internal static JsonObject Prompt(LlmCatalog catalog, JsonObject prompt, IReadOnlyList<VoiceRewriteTimingFeedback> phrases)
    {
        if (!phrases.Any(phrase => phrase.MeasuredSeconds is not null)) return prompt;
        var measured = VoiceLabLlmChecks.ReadPrompt(catalog, "prompts/voice-rewrite-shorter-measured.json");
        var combined = prompt.DeepClone().AsObject();
        combined["shorterMeasuredFeedbackBlock"] = measured.Document["shorterMeasuredFeedbackBlock"]?.DeepClone();
        combined["shorterMeasuredPhraseLine"] = measured.Document["shorterMeasuredPhraseLine"]?.DeepClone();
        return combined;
    }
    internal static string? MeasuredPromptHash(LlmCatalog catalog, IReadOnlyList<VoiceRewriteTimingFeedback> phrases) =>
        phrases.Any(phrase => phrase.MeasuredSeconds is not null) ? VoiceLabLlmChecks.ReadPrompt(catalog, "prompts/voice-rewrite-shorter-measured.json").Sha256 : null;

    internal static string Render(IReadOnlyList<VoiceRewriteTimingFeedback> phrases, JsonObject prompt)
    {
        if (phrases.Count == 0) return "";
        if (phrases.Count > VoiceLabWordDiff.MaximumTokens || phrases.Any(phrase => phrase is null ||
            phrase.Original is null || phrase.Proposed is null || !double.IsFinite(phrase.EstimateSeconds) || phrase.EstimateSeconds <= 0 ||
            !double.IsFinite(phrase.SlotSeconds) || phrase.SlotSeconds < 0 ||
            phrase.MeasuredSeconds is { } measured && (!double.IsFinite(measured) || measured <= 0))) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var block = prompt["request"]?["shorterFeedbackBlock"]?.GetValue<string>();
        var line = prompt["request"]?["shorterPhraseLine"]?.GetValue<string>();
        var hasMeasured = phrases.Any(phrase => phrase.MeasuredSeconds is not null);
        var measuredLine = hasMeasured ? prompt["shorterMeasuredPhraseLine"]?.GetValue<string>() : null;
        if (hasMeasured) block = prompt["shorterMeasuredFeedbackBlock"]?.GetValue<string>();
        if (block is null || !block.Contains("{phrases}", StringComparison.Ordinal) || line is null ||
            !new[] { "{original}", "{proposed}", "{estimateSeconds}", "{slotSeconds}" }.All(key => line.Contains(key, StringComparison.Ordinal)) ||
            hasMeasured && (measuredLine is null || !new[] { "{original}", "{proposed}", "{measuredSeconds}", "{slotSeconds}" }.All(key => measuredLine.Contains(key, StringComparison.Ordinal))))
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        var lines = phrases.Select(phrase => System.Text.RegularExpressions.Regex.Replace(phrase.MeasuredSeconds is null ? line : measuredLine!,
            "\\{(original|proposed|estimateSeconds|measuredSeconds|slotSeconds)\\}", match => match.Groups[1].Value switch
            {
                "original" => phrase.Original,
                "proposed" => phrase.Proposed,
                "estimateSeconds" => EditingFormat.ToFixed1(phrase.EstimateSeconds),
                "measuredSeconds" => EditingFormat.ToFixed1(phrase.MeasuredSeconds!.Value),
                _ => EditingFormat.ToFixed1(phrase.SlotSeconds)
            }));
        var rendered = block.Replace("{phrases}", string.Join("\n\n", lines), StringComparison.Ordinal);
        if (Encoding.UTF8.GetByteCount(rendered) > 20_000) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return "\n\n" + rendered;
    }
}
