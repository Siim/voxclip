#pragma warning disable CS1591
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;
using VoxClip.Core.Domain.VoiceLab;

namespace VoxClip.Core.Services.VoiceLab;

internal static class VoiceRewriteFeedback
{
    internal static string Render(IReadOnlyList<VoiceRewriteTimingFeedback> phrases, JsonObject prompt)
    {
        if (phrases.Count == 0) return "";
        if (phrases.Count > VoiceLabWordDiff.MaximumTokens || phrases.Any(phrase => phrase is null ||
            phrase.Original is null || phrase.Proposed is null || !double.IsFinite(phrase.EstimateSeconds) || phrase.EstimateSeconds <= 0 ||
            !double.IsFinite(phrase.SlotSeconds) || phrase.SlotSeconds < 0)) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        var block = prompt["request"]?["shorterFeedbackBlock"]?.GetValue<string>();
        var line = prompt["request"]?["shorterPhraseLine"]?.GetValue<string>();
        if (block is null || !block.Contains("{phrases}", StringComparison.Ordinal) || line is null ||
            !new[] { "{original}", "{proposed}", "{estimateSeconds}", "{slotSeconds}" }.All(key => line.Contains(key, StringComparison.Ordinal)))
            throw new VoxClipException(VoxClipErrorCode.SharedResourcesMissing, "VoxClip is missing some of its files. Reinstall VoxClip.");
        var lines = phrases.Select(phrase => System.Text.RegularExpressions.Regex.Replace(line,
            "\\{(original|proposed|estimateSeconds|slotSeconds)\\}", match => match.Groups[1].Value switch
            {
                "original" => phrase.Original,
                "proposed" => phrase.Proposed,
                "estimateSeconds" => EditingFormat.ToFixed1(phrase.EstimateSeconds),
                _ => EditingFormat.ToFixed1(phrase.SlotSeconds)
            }));
        var rendered = block.Replace("{phrases}", string.Join("\n\n", lines), StringComparison.Ordinal);
        if (Encoding.UTF8.GetByteCount(rendered) > 20_000) throw new VoiceLabException(VoiceLabErrorKind.InvalidInput);
        return "\n\n" + rendered;
    }
}
