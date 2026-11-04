#pragma warning disable CS1591
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>One AI-suggested next step for a blocked Rewrite phrase (voice-lab.md §8.2.1): the optional <c>nextActions</c>
/// of a voice-rewrite or patch-rewrite reply. <see cref="Label"/> is button text only and is never sent;
/// <see cref="Instruction"/> is what the app sends back as feedback if the user clicks it. <see cref="Ordinals"/> are the
/// phrase numbers the request's feedback named; empty means the phrases blocked when it is clicked.</summary>
public sealed record RewriteNextAction(string Label, string Instruction, IReadOnlyList<int> Ordinals)
{
    public const int MaximumCount = 4;
    public const int MaximumLabelWords = 6;
    internal const int MaximumLabelBytes = 80;
    internal const int MaximumInstructionBytes = 1_000;
    internal const int MaximumOrdinals = 60;

    public bool Equals(RewriteNextAction? other) => other is not null && Label == other.Label && Instruction == other.Instruction &&
        Ordinals.SequenceEqual(other.Ordinals);
    public override int GetHashCode() => HashCode.Combine(Label, Instruction, Ordinals.Count);

    /// <summary>The valid entries of a reply's <c>nextActions</c>, at most <see cref="MaximumCount"/>, in reply order. An
    /// entry is dropped when its label is empty, longer than six words or 80 bytes, or holds a control character or a link;
    /// when its instruction is empty, over 1,000 bytes, or holds a link or a control character other than a line break;
    /// when an ordinal is not a whole number from 1 to 999; or when its label repeats an earlier one (ignoring case). A
    /// missing or non-array value is no actions.</summary>
    public static IReadOnlyList<RewriteNextAction> Parse(JsonNode? value)
    {
        var result = new List<RewriteNextAction>();
        if (value is not JsonArray items) return result;
        var labels = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            if (result.Count >= MaximumCount || ParseOne(item) is not { } action) continue;
            if (!labels.Add(action.Label.ToLowerInvariant())) continue;
            result.Add(action);
        }
        return result.AsReadOnly();
    }

    static RewriteNextAction? ParseOne(JsonNode? item)
    {
        if (item is not JsonObject entry || Text(entry["label"]) is not { } rawLabel || Text(entry["instruction"]) is not { } rawInstruction) return null;
        var label = EditingAlgorithms.JsTrim(rawLabel);
        var instruction = EditingAlgorithms.JsTrim(rawInstruction);
        if (label.Length == 0 || Encoding.UTF8.GetByteCount(label) > MaximumLabelBytes || EditingAlgorithms.SplitWords(label).Count > MaximumLabelWords ||
            HasControl(label, false) || HasLink(label) || instruction.Length == 0 || Encoding.UTF8.GetByteCount(instruction) > MaximumInstructionBytes ||
            HasControl(instruction, true) || HasLink(instruction)) return null;
        var ordinals = new List<int>();
        switch (entry["ordinals"])
        {
            case null: break;
            case JsonArray values:
                if (values.Count > MaximumOrdinals) return null;
                foreach (var value in values)
                {
                    if (value is not JsonValue number || number.GetValueKind() != JsonValueKind.Number || !number.TryGetValue<double>(out var ordinal) ||
                        ordinal != Math.Floor(ordinal) || ordinal is < 1 or > 999) return null;
                    if (!ordinals.Contains((int)ordinal)) ordinals.Add((int)ordinal);
                }
                break;
            default: return null;
        }
        ordinals.Sort();
        return new(label, instruction, ordinals.AsReadOnly());
    }

    static string? Text(JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : null;
    internal static bool HasControl(string text, bool allowingLineBreaks) =>
        text.Any(character => char.GetUnicodeCategory(character) == UnicodeCategory.Control && !(allowingLineBreaks && character == '\n'));
    static bool HasLink(string text) => Regex.IsMatch(text, "https?://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

/// <summary>Why a blocked phrase a scoped re-ask names is blocked: its <c>reasons</c> template in
/// <c>shared/prompts/rewrite-next-actions.json</c>.</summary>
public enum RewriteBlockedReason { Fit, Budget, Take, Context, Collision, Asked }

/// <summary>A phrase a scoped re-ask names in its feedback. <see cref="EstimateSeconds"/> and <see cref="SlotSeconds"/> fill
/// the <see cref="RewriteBlockedReason.Fit"/> reason.</summary>
public sealed record RewriteBlockedPhrase(int Ordinal, RewriteBlockedReason Reason, string Original, string Proposed,
    double? EstimateSeconds = null, double? SlotSeconds = null);

/// <summary>How a scoped re-ask's reply lands on the proposal it was asked for (voice-lab.md §8.2.1): only the asked phrases
/// can change; every other change is frozen. Spans are the hunks' <c>SourceStartIndex..SourceEndIndex</c> over the same
/// source.</summary>
public static class RewriteScopedReply
{
    public enum OutcomeKind
    {
        /// <summary>The reply's hunk at <see cref="Outcome.Index"/> replaces the phrase.</summary>
        Replace,
        /// <summary>The reply leaves the phrase's words as recorded: the original words are kept.</summary>
        KeepOriginal,
        /// <summary>One reply hunk spans this phrase and an earlier asked one (a merge): it goes into the phrase at
        /// <see cref="Outcome.Index"/>, and this phrase leaves the proposal.</summary>
        Absorbed,
        /// <summary>The reply's change here also reaches a frozen change, comes in several pieces, or reaches an asked phrase
        /// that cannot take it; the phrase stays as it was.</summary>
        Conflict,
    }
    public readonly record struct Outcome(OutcomeKind Kind, int Index = -1);

    /// <summary>The outcome for each asked hunk index (<paramref name="asked"/>, indexes into <paramref name="current"/>). A
    /// reply hunk lands only when it reaches no frozen change and every asked phrase it reaches has it as its only reply
    /// hunk; then the first of them takes it and the others are absorbed. Otherwise every asked phrase it reaches stays as
    /// it was.</summary>
    public static IReadOnlyDictionary<int, Outcome> Assign(IReadOnlyList<VoiceLabDiffHunk> current, IReadOnlySet<int> asked, IReadOnlyList<VoiceLabDiffHunk> reply)
    {
        var indices = asked.Order().Where(index => index >= 0 && index < current.Count).ToArray();
        var candidates = indices.ToDictionary(index => index, index => Enumerable.Range(0, reply.Count).Where(found => Touches(current[index], reply[found])).ToArray());
        var result = new Dictionary<int, Outcome>();
        foreach (var index in indices)
        {
            if (result.ContainsKey(index)) continue;
            if (candidates[index].Length == 0) { result[index] = new(OutcomeKind.KeepOriginal); continue; }
            var found = candidates[index][0];
            var group = Enumerable.Range(0, current.Count).Where(member => Touches(current[member], reply[found])).ToArray();
            var lands = candidates[index].Length == 1 && group.All(member => asked.Contains(member) &&
                candidates.TryGetValue(member, out var reached) && reached.SequenceEqual([found]));
            foreach (var member in group.Where(asked.Contains))
                result[member] = !lands ? new(OutcomeKind.Conflict) : member == group[0] ? new(OutcomeKind.Replace, found) : new(OutcomeKind.Absorbed, group[0]);
            result.TryAdd(index, new(OutcomeKind.Conflict));
        }
        return result;
    }

    /// <summary>Two spans overlap, or an insertion sits inside or at the edge of the other.</summary>
    internal static bool Touches(VoiceLabDiffHunk left, VoiceLabDiffHunk right)
    {
        var (a0, a1) = (left.SourceStartIndex, Math.Max(left.SourceStartIndex, left.SourceEndIndex));
        var (b0, b1) = (right.SourceStartIndex, Math.Max(right.SourceStartIndex, right.SourceEndIndex));
        if (a0 == a1 || b0 == b1) return a0 <= b1 && b0 <= a1;
        return a0 < b1 && b0 < a1;
    }
}
