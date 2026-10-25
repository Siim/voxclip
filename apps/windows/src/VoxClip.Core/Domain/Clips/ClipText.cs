using System.Globalization;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Editing;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Clips;

internal sealed record NumberedLine(TranscriptLine Line, int FirstPosition, int LastPosition, string? PauseAfter);

internal static class ClipText
{
    private static readonly Regex SentenceEnd = new("[.!?。！？][\"'”’)]*\\z", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    internal const string TrimCharacters = "\u0009\u000a\u000b\u000c\u000d \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff";
    internal static string Trim(string value) => value.Trim(TrimCharacters.ToCharArray());
    internal static string Limit(string value, int length)
    {
        if (value.Length <= length) return value;
        if (length > 0 && char.IsHighSurrogate(value[length - 1]) && char.IsLowSurrogate(value[length])) length--;
        return value[..length];
    }

    internal static string Time(double seconds) => Math.Floor((seconds == 0 ? 0 : seconds) / 60).ToString(CultureInfo.InvariantCulture) + ":" +
        Math.Floor(seconds == 0 ? 0 : seconds % 60).ToString("00", CultureInfo.InvariantCulture);


    internal static IReadOnlyList<ClipWord> Entries(IReadOnlyList<TimedWord> words, IReadOnlyDictionary<string, string> corrections, int maxWordTextLength = 100) =>
        words.Select((word, index) => new ClipWord(index, Limit(word.Kind switch
        {
            WordKind.UnlabeledSpeech => "…",
            WordKind.Word => corrections.GetValueOrDefault(word.Id) ?? word.Text,
            _ => word.Text
        }, maxWordTextLength), word.Start, word.End)).ToArray();

    internal static IReadOnlyList<NumberedLine> Lines(IReadOnlyList<ClipWord> entries)
    {
        var lines = new List<NumberedLine>();
        var first = 0;
        for (var position = 0; position < entries.Count; position++)
        {
            var current = entries[position];
            var next = position + 1 < entries.Count ? entries[position + 1] : null;
            var gap = next is null ? 0 : next.Start - current.End;
            if (next is not null && !SentenceEnd.IsMatch(current.Text) && gap < 1.2 && position - first < 40) continue;
            var beginning = entries[first];
            var text = $"[{beginning.Index}-{current.Index}] {Time(beginning.Start)} " + string.Join(" ", entries.Skip(first).Take(position - first + 1).Select(entry => entry.Text));
            lines.Add(new(new(beginning.Index, current.Index, beginning.Start, current.End, text), first, position,
                next is not null && gap >= 1.5 ? $"(pause {EditingFormat.ToFixed1(gap)}s)" : null));
            first = position + 1;
        }
        return lines;
    }

    internal static string Render(IEnumerable<NumberedLine> lines) => string.Join("\n", lines.SelectMany(line =>
        line.PauseAfter is null ? new[] { line.Line.Text } : new[] { line.Line.Text, line.PauseAfter }));

    internal static (int Start, int End) Snap(int start, int end, IReadOnlyList<TranscriptLine> lines, int radius = 3)
    {
        var snappedStart = lines.Select(line => line.FirstIndex).Where(index => Math.Abs(index - (long)start) <= radius)
            .OrderBy(index => Math.Abs(index - (long)start)).ThenBy(index => index).Cast<int?>().FirstOrDefault() ?? start;
        var snappedEnd = lines.Select(line => line.LastIndex).Where(index => Math.Abs(index - (long)end) <= radius)
            .OrderBy(index => Math.Abs(index - (long)end)).ThenByDescending(index => index).Cast<int?>().FirstOrDefault() ?? end;
        return snappedStart <= snappedEnd ? (snappedStart, snappedEnd) : (start, end);
    }

    internal static double Overlap(ClipCandidate first, ClipCandidate second) =>
        (double)Math.Max(0, Math.Min(first.End, second.End) - Math.Max(first.Start, second.Start) + 1) /
        (Math.Max(first.End, second.End) - Math.Min(first.Start, second.Start) + 1);
}
