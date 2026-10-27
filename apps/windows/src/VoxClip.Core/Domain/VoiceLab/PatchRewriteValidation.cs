using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.VoiceLab;

/// <summary>The pure Fix with AI rules of voice-lab §8.1: sanitising, line matching, duplicates, deletions, Core's own length and the
/// checkThis badge. Vectors: <c>shared/fixtures/voice-lab/patch-rewrite-cases.json</c>.</summary>
internal static class PatchRewriteValidator
{
    /// <summary>One edit's text holds at most 2,000 UTF-8 bytes, and the kept edits' texts at most 20,000 together.</summary>
    internal const int MaxEditBytes = 2000;
    internal const int MaxTextBytes = 20000;
    private static readonly Regex SentenceEnd = new("[.!?。！？][\"'”’)]*\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    internal sealed record Result(IReadOnlyList<PatchRewriteEdit> Edits, int UnknownLines, int DuplicateLines, int MalformedItems);

    /// <summary><paramref name="items"/> already passed structural validation (ai.md §2.3); <paramref name="sources"/> are the entry
    /// texts and the instruction. A malformed edit is dropped and counted before line matching; it never fails the reply.</summary>
    internal static Result Validate(JsonArray items, IReadOnlyList<PatchRewriteLineRange> ranges, IEnumerable<string> sources)
    {
        var byLine = new Dictionary<string, PatchRewriteLineRange>(StringComparer.Ordinal);
        foreach (var range in ranges) byLine.TryAdd(range.Line, range);
        var known = new Sources(sources);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var edits = new List<PatchRewriteEdit>();
        int unknown = 0, duplicates = 0, malformed = 0;
        foreach (var item in items)
        {
            if (Text(item, "line") is not { } raw || Text(item, "text") is not { } text || Text(item, "reason") is not { } reason ||
                HasControl(text) || HasControl(reason) || Encoding.UTF8.GetByteCount(text) > MaxEditBytes) { malformed++; continue; }
            var line = EditingAlgorithms.JsTrim(raw);
            if (!byLine.TryGetValue(line, out var range)) { unknown++; continue; }
            if (!seen.Add(line)) { duplicates++; continue; }
            var length = VoiceLabTextLength.Length(text);
            var deletion = EditingAlgorithms.JsTrim(text).Length == 0;
            edits.Add(new(line, text, reason, length, deletion || length >= range.MinChars && length <= range.MaxChars, known.Flags(text), deletion));
        }
        return new(edits, unknown, duplicates, malformed);
    }

    private static string? Text(JsonNode? item, string key) =>
        item is JsonObject value && value[key] is JsonValue field && field.TryGetValue<string>(out var text) ? text : null;

    /// <summary>A control character (Cc) other than tab.</summary>
    private static bool HasControl(string text) => text.Any(character => char.IsControl(character) && character != '\t');

    /// <summary>The tokens and digit runs of the transcript and the instruction, which an edit's own may repeat without a badge.</summary>
    private sealed class Sources
    {
        private readonly HashSet<string> keys = new(StringComparer.Ordinal);
        private readonly HashSet<string> digitRuns = new(StringComparer.Ordinal);

        internal Sources(IEnumerable<string> texts)
        {
            foreach (var text in texts)
            {
                var normal = EditingAlgorithms.Nfc(text);
                digitRuns.UnionWith(DigitRuns(normal));
                keys.UnionWith(EditingAlgorithms.SplitWords(normal).Select(Key));
            }
        }

        /// <summary>True when the NFC text holds a digit run, a URL, or a capitalised token not at a sentence start, that no source has.</summary>
        internal bool Flags(string text)
        {
            var normal = EditingAlgorithms.Nfc(text);
            if (DigitRuns(normal).Any(run => !digitRuns.Contains(run))) return true;
            var tokens = EditingAlgorithms.SplitWords(normal);
            for (var index = 0; index < tokens.Count; index++)
            {
                var key = Key(tokens[index]);
                if (IsUrl(tokens[index]) && !keys.Contains(key)) return true;
                var atStart = index == 0 || SentenceEnd.IsMatch(tokens[index - 1]);
                if (!atStart && IsCapitalised(tokens[index]) && !keys.Contains(key)) return true;
            }
            return false;
        }
    }

    /// <summary>normalizeForMatch (editing §4.7) without its lowercase step: equal keys mean equal normalizeForMatch, and case counts.</summary>
    internal static string Key(string token)
    {
        var key = new StringBuilder(token.Length);
        foreach (var rune in token.EnumerateRunes()) if (IsLetter(rune) || IsNumber(rune)) key.Append(rune.ToString());
        return key.ToString();
    }

    internal static IEnumerable<string> DigitRuns(string text)
    {
        var run = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) == UnicodeCategory.DecimalDigitNumber) { run.Append(rune.ToString()); continue; }
            if (run.Length == 0) continue;
            yield return run.ToString();
            run.Clear();
        }
        if (run.Length > 0) yield return run.ToString();
    }

    /// <summary>A token holding "://", or starting with "www." in either ASCII case once leading non-letters and non-digits are skipped.</summary>
    internal static bool IsUrl(string token)
    {
        if (token.Contains("://", StringComparison.Ordinal)) return true;
        var start = token.EnumerateRunes().SkipWhile(rune => !IsLetter(rune) && !IsNumber(rune)).Take(4).Select(rune => rune.Value).ToArray();
        return start.Length == 4 && start.Take(3).All(value => value is 0x77 or 0x57) && start[3] == 0x2E;
    }

    internal static bool IsCapitalised(string token)
    {
        foreach (var rune in token.EnumerateRunes())
            if (IsLetter(rune)) return Rune.GetUnicodeCategory(rune) is UnicodeCategory.UppercaseLetter or UnicodeCategory.TitlecaseLetter;
        return false;
    }

    private static bool IsLetter(Rune rune) => Rune.GetUnicodeCategory(rune) is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter
        or UnicodeCategory.TitlecaseLetter or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter;

    private static bool IsNumber(Rune rune) => Rune.GetUnicodeCategory(rune) is UnicodeCategory.DecimalDigitNumber
        or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;
}
