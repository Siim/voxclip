#pragma warning disable CS1591
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

public static class TakeMatch
{
    public sealed record Result(IReadOnlyList<Beat> Beats);
    public sealed record Beat(string Id, IReadOnlyList<Take> Takes);
    public sealed record Take(string Key, string StartWordId, string EndWordId);

    private readonly record struct Token(string Text, int Position);
    private sealed record Sentence(int Recording, TimedWord[] Words, Token[] Tokens, int? Previous);

    internal const double MinimumSimilarity = 0.6;
    internal const double MinimumWordRatio = 0.5;
    internal const double MaximumWordRatio = 2;

    public static Result Build(IReadOnlyList<(string Key, IReadOnlyList<TimedWord> Words)> recordings)
    {
        var sentences = new List<Sentence>();
        var ranges = new List<(int First, int End)>();
        for (var recording = 0; recording < recordings.Count; recording++)
        {
            var input = recordings[recording].Words;
            var firstSentence = sentences.Count;
            var firstWord = 0;
            for (var position = 0; position < input.Count; position++)
            {
                var word = input[position];
                var next = position + 1;
                var gap = next < input.Count ? input[next].Start - word.End : 0;
                if (next < input.Count && !ClipText.EndsLine(word.Text, gap, next - firstWord)) continue;
                var words = new TimedWord[next - firstWord];
                var tokens = new List<Token>();
                for (var offset = 0; offset < words.Length; offset++)
                {
                    var item = input[firstWord + offset];
                    words[offset] = item;
                    if (item.Kind != WordKind.Word || EditingAlgorithms.IsFillerText(item.Text)) continue;
                    var text = EditingAlgorithms.NormalizeForMatch(EditingAlgorithms.Nfc(item.Text));
                    if (text.Length > 0) tokens.Add(new(text, offset));
                }
                sentences.Add(new(recording, words, [.. tokens], sentences.Count > firstSentence ? sentences.Count - 1 : null));
                firstWord = next;
            }
            ranges.Add((firstSentence, sentences.Count));
        }

        var groups = new Groups(sentences);
        for (var first = 0; first < ranges.Count; first++)
        {
            for (var second = first + 1; second < ranges.Count; second++)
            {
                var next = ranges[second].First;
                for (var left = ranges[first].First; left < ranges[first].End; left++)
                {
                    for (var right = next; right < ranges[second].End; right++)
                    {
                        if (!Matches(sentences[left], sentences[right]) || !groups.Join(left, right)) continue;
                        next = right + 1;
                        break;
                    }
                }
            }
        }
        var beats = groups.InOrder().Select((members, index) => new Beat(FormattableString.Invariant($"beat{index + 1}"), members.Select(member =>
        {
            var sentence = sentences[member];
            return new Take(recordings[sentence.Recording].Key, sentence.Words[0].Id, sentence.Words[^1].Id);
        }).ToArray())).ToArray();
        return new(beats);
    }

    private static bool Matches(Sentence left, Sentence right)
    {
        var shorter = Math.Min(left.Tokens.Length, right.Tokens.Length);
        if (shorter == 0) return false;
        var ratio = (double)left.Tokens.Length / right.Tokens.Length;
        if (ratio is < MinimumWordRatio or > MaximumWordRatio) return false;
        if (left.Tokens.Select(token => token.Text).SequenceEqual(right.Tokens.Select(token => token.Text))) return true;
        var common = left.Tokens.Select(token => token.Text).ToHashSet(StringComparer.Ordinal);
        common.IntersectWith(right.Tokens.Select(token => token.Text));
        if (left.Tokens.Count(token => common.Contains(token.Text)) < MinimumSimilarity * shorter ||
            right.Tokens.Count(token => common.Contains(token.Text)) < MinimumSimilarity * shorter) return false;
        return (double)Lcs(left.Tokens, right.Tokens)[0] / shorter >= MinimumSimilarity;
    }

    private static int[] Lcs(Token[] left, Token[] right)
    {
        var width = right.Length + 1;
        var lengths = new int[(left.Length + 1) * width];
        for (var row = left.Length - 1; row >= 0; row--)
        {
            for (var column = right.Length - 1; column >= 0; column--)
            {
                var index = row * width + column;
                lengths[index] = left[row].Text == right[column].Text
                    ? 1 + lengths[index + width + 1] : Math.Max(lengths[index + width], lengths[index + 1]);
            }
        }
        return lengths;
    }

    private sealed class Groups(List<Sentence> sentences)
    {
        private readonly int[] owner = Enumerable.Range(0, sentences.Count).ToArray();
        private readonly int[][] members = Enumerable.Range(0, sentences.Count).Select(index => new[] { index }).ToArray();

        private IEnumerable<int> Predecessors(int group)
        {
            foreach (var member in members[group])
                if (sentences[member].Previous is int previous) yield return owner[previous];
        }

        private bool Precedes(int target, int group)
        {
            var pending = new Stack<int>(Predecessors(group));
            var seen = new HashSet<int>();
            while (pending.TryPop(out var previous))
            {
                if (previous == target) return true;
                if (seen.Add(previous))
                    foreach (var predecessor in Predecessors(previous)) pending.Push(predecessor);
            }
            return false;
        }

        internal bool Join(int left, int right)
        {
            var first = Math.Min(owner[left], owner[right]);
            var second = Math.Max(owner[left], owner[right]);
            if (first == second) return true;
            var recordings = members[first].Select(member => sentences[member].Recording).ToHashSet();
            if (members[second].Any(member => recordings.Contains(sentences[member].Recording)) || Precedes(first, second) || Precedes(second, first))
                return false;
            foreach (var sentence in members[second]) owner[sentence] = first;
            members[first] = [.. members[first].Concat(members[second]).Order()];
            members[second] = [];
            return true;
        }

        internal IEnumerable<int[]> InOrder()
        {
            var emitted = new HashSet<int>();
            for (var group = 0; group < members.Length; group++)
            {
                if (members[group].Length == 0) continue;
                var pending = new Stack<(int Group, bool Ready)>();
                pending.Push((group, false));
                while (pending.TryPop(out var entry))
                {
                    if (emitted.Contains(entry.Group)) continue;
                    if (entry.Ready)
                    {
                        emitted.Add(entry.Group);
                        yield return members[entry.Group];
                    }
                    else
                    {
                        pending.Push((entry.Group, true));
                        foreach (var predecessor in Predecessors(entry.Group).Reverse()) pending.Push((predecessor, false));
                    }
                }
            }
        }
    }
}
