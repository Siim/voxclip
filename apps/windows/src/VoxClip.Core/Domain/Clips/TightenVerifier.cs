using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

internal sealed record TightenProposal(string LineLabel, string Kind, IReadOnlyList<string> CutWordIds, bool Preselected);
internal sealed record TightenRejection(int EditIndex, string Reason);
internal sealed record TightenVerification(IReadOnlyList<TightenProposal> Proposals, int RejectedCount, IReadOnlyList<TightenRejection> Rejected);

internal static class TightenVerifier
{
    internal static IReadOnlyList<ClipWord> Entries(IReadOnlyList<TimedWord> words, IReadOnlyDictionary<string, string> corrections,
        IReadOnlySet<string> cuts, int start, int end) => ClipText.Entries(words, corrections)
        .Where(entry => entry.Index >= start && entry.Index <= end && !cuts.Contains(words[entry.Index].Id) &&
            words[entry.Index].Kind != WordKind.UnlabeledSpeech).ToArray();

    internal static TightenVerification Verify(JsonArray edits, IReadOnlyList<ClipWord> entries, IReadOnlyList<TimedWord> words, JsonObject prompt)
    {
        var lines = ClipText.Lines(entries).ToDictionary(line => line.Line.Text.Split(' ')[0], StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var proposals = new List<TightenProposal>();
        var rejected = new List<TightenRejection>();
        var strip = prompt["normalization"]!["stripEdgeCharacters"]!.GetValue<string>();
        var kinds = prompt["kinds"]!.AsArray().Select(kind => kind!["id"]!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
        for (var editIndex = 0; editIndex < edits.Count; editIndex++)
        {
            var edit = edits[editIndex];
            var label = edit?["line"]?.GetValue<string>();
            var keep = edit?["keep"]?.GetValue<string>();
            var kind = edit?["kind"]?.GetValue<string>();
            if (label is null || keep is null || kind is null) { rejected.Add(new(editIndex, "invalidEdit")); continue; }
            if (!lines.TryGetValue(ClipText.Trim(label), out var line)) { rejected.Add(new(editIndex, "unknownLine")); continue; }
            if (!seen.Add(ClipText.Trim(label))) { rejected.Add(new(editIndex, "duplicate")); continue; }
            if (!kinds.Contains(kind)) { rejected.Add(new(editIndex, "badKind")); continue; }
            var lineEntries = entries.Skip(line.FirstPosition).Take(line.LastPosition - line.FirstPosition + 1).ToArray();
            var tokens = lineEntries.Select(entry => Tokens(entry.Text, strip)).ToArray();
            var flattened = tokens.SelectMany((parts, entryIndex) => parts.Select(token => (Token: token, Entry: entryIndex))).ToArray();
            var matched = new int[lineEntries.Length];
            var cursor = flattened.Length - 1;
            var invalid = false;
            foreach (var token in Tokens(keep, strip).Reverse())
            {
                while (cursor >= 0 && flattened[cursor].Token != token) cursor--;
                if (cursor < 0) { invalid = true; break; }
                matched[flattened[cursor--].Entry]++;
            }
            if (invalid) { rejected.Add(new(editIndex, "notSubsequence")); continue; }
            if (tokens.Where((parts, index) => matched[index] != 0 && matched[index] != parts.Length).Any()) { rejected.Add(new(editIndex, "splitWord")); continue; }
            var cut = tokens.Select((parts, index) => parts.Length > 0 && matched[index] == 0).ToArray();
            for (var index = 0; index < tokens.Length; index++)
            {
                if (tokens[index].Length != 0) continue;
                var neighbor = index - 1;
                while (neighbor >= 0 && tokens[neighbor].Length == 0) neighbor--;
                if (neighbor < 0) { neighbor = index + 1; while (neighbor < tokens.Length && tokens[neighbor].Length == 0) neighbor++; }
                cut[index] = neighbor < tokens.Length && neighbor >= 0 ? cut[neighbor] : Tokens(keep, strip).Length == 0;
            }
            var ids = lineEntries.Where((_, index) => cut[index]).Select(entry => words[entry.Index].Id).ToArray();
            if (ids.Length == 0) continue;
            var empty = Tokens(keep, strip).Length == 0;
            var review = !empty ? ids.Length > prompt["limits"]!["reviewCutFraction"]!.GetValue<double>() * lineEntries.Length :
                lineEntries.Length > prompt["limits"]!["wholeLinePreselectMaxWords"]!.GetValue<int>();
            proposals.Add(new(ClipText.Trim(label), kind, ids, !review));
        }
        return new(proposals, rejected.Count, rejected);
    }

    private static string[] Tokens(string text, string strip) => text.Split(ClipText.TrimCharacters.ToCharArray(), StringSplitOptions.RemoveEmptyEntries)
        .Select(part => Lower(EditingAlgorithms.Nfc(part)).Trim(strip.ToCharArray())).Where(part => part.Length > 0).ToArray();

    private static string Lower(string text)
    {
        var runes = text.EnumerateRunes().ToArray();
        var result = new StringBuilder();
        for (var index = 0; index < runes.Length; index++)
        {
            var rune = runes[index];
            if (rune.Value == 0x130) result.Append("i\u0307");
            else if (rune.Value == 0x3a3 && HasCased(runes, index, -1) && !HasCased(runes, index, 1)) result.Append('ς');
            else result.Append(Rune.ToLowerInvariant(rune).ToString());
        }
        return result.ToString();
    }

    private static bool HasCased(Rune[] runes, int index, int direction)
    {
        for (index += direction; index >= 0 && index < runes.Length; index += direction)
        {
            var category = Rune.GetUnicodeCategory(runes[index]);
            if (category is UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter) return true;
            if (category is not (UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.Format or UnicodeCategory.ModifierLetter or UnicodeCategory.ModifierSymbol) && runes[index].Value is not (0x27 or 0x2019)) return false;
        }
        return false;
    }
}
