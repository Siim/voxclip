#pragma warning disable CS1591
using VoxClip.Core.Domain.Clips;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Editing;

public static class TakeMatch
{
    public sealed record Result(IReadOnlyList<Beat> Beats, IReadOnlyList<SoloRun> Solo);
    public sealed record Beat(string Id, IReadOnlyList<Take> Takes, IReadOnlyList<AlignedSpan> Spans);
    public sealed record Take(string Key, string StartWordId, string EndWordId, IReadOnlyList<string> Flags, DeliverySignals Signals);
    public sealed record AlignedSpan(string FromKey, string ToKey, string StartWordId, string EndWordId, IReadOnlyList<string> ChangedWordIds);
    public sealed record SoloRun(string Key, string StartWordId, string EndWordId, int SentenceCount, string? AfterBeatId, string? BeforeBeatId);
    public sealed record DeliverySignals(int Fillers, double LongestPause, int Restarts, double WordsPerMinute, double? MeanConfidence, bool CutOff);

    private readonly record struct Token(string Text, int Position);
    private sealed record Sentence(int Recording, TimedWord[] Words, Token[] Tokens, int? Previous, bool CutOff);

    internal const double MinimumSimilarity = 0.6;
    internal const double MinimumWordRatio = 0.5;
    internal const double MaximumWordRatio = 2;
    internal const string ClauseBreaks = ",，、-–—.。";
    internal const int MaxRestartWords = 8;
    internal const double RestartMajority = 0.5;
    internal const double FalseStartSeconds = 10;
    internal const double RestartRunSeconds = 3;
    internal const int MinRestartRunWords = 2;
    internal const int IsolatedTailGapWords = 2;
    internal static IReadOnlyDictionary<string, IReadOnlyList<string>> RestartPhrases { get; } =
        new System.Collections.ObjectModel.ReadOnlyDictionary<string, IReadOnlyList<string>>(new Dictionary<string, IReadOnlyList<string>>
        {
            ["en"] = Array.AsReadOnly(new[] { "sorry where was i", "let me start again", "one more time" }),
            ["et"] = Array.AsReadOnly(new[] { "vabandust kus ma olin", "alustan uuesti", "üks kord veel" }),
            ["de"] = Array.AsReadOnly(new[] { "sorry wo war ich", "ich fange noch mal an", "noch einmal" }),
        });
    private static readonly string[][] RestartTokens = RestartPhrases.Values.SelectMany(phrases => phrases)
        .Select(phrase => phrase.Split(' ')).ToArray();

    public static Result Build(ProjectClock clock)
    {
        if (clock.Regions.Count == 1) return Build([(clock.Regions[0].Key, clock.Words)]);
        var byRegion = clock.Words.ToLookup(word => clock.RegionOf(word.Id)?.Key);
        return Build(clock.Regions.Select(region => (region.Key, (IReadOnlyList<TimedWord>)byRegion[region.Key].Select(word =>
            region.OffsetSamples == 0 ? word : word with
            {
                Start = (Math.Floor(word.Start * clock.SampleRate + 0.5) - region.OffsetSamples) / clock.SampleRate,
                End = (Math.Floor(word.End * clock.SampleRate + 0.5) - region.OffsetSamples) / clock.SampleRate,
            }).ToArray())).ToArray());
    }

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
                    if (item.Kind != WordKind.Word || IsFiller(item)) continue;
                    var text = EditingAlgorithms.NormalizeForMatch(EditingAlgorithms.Nfc(item.Text));
                    if (text.Length > 0) tokens.Add(new(text, offset));
                }
                sentences.Add(new(recording, words, [.. tokens], sentences.Count > firstSentence ? sentences.Count - 1 : null,
                    firstWord == 0 || next == input.Count));
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
                        if (!groups.Join(left, right)) continue;
                        next = right + 1;
                        break;
                    }
                }
            }
        }
        var takes = sentences.Select((sentence, index) => MakeTake(recordings[sentence.Recording].Key, sentence,
            index + 1 < sentences.Count && sentences[index + 1].Recording == sentence.Recording ? sentences[index + 1] : null)).ToArray();
        var matchedIds = new string?[sentences.Count];
        var beats = groups.InOrder().Select((members, index) =>
        {
            var id = FormattableString.Invariant($"beat{index + 1}");
            if (members.Length > 1)
                foreach (var member in members) matchedIds[member] = id;
            var spans = from source in members from target in members where source != target
                        select Align(takes[source].Key, sentences[source], takes[target].Key, sentences[target]);
            return new Beat(id, members.Select(member => takes[member]).ToArray(), spans.ToArray());
        }).ToArray();
        return new(beats, SoloRuns(ranges, takes, matchedIds));
    }

    private static bool IsFiller(TimedWord word) => word.Kind == WordKind.UnlabeledSpeech ||
        (word.Kind == WordKind.Word && EditingAlgorithms.IsFillerText(word.Text));

    private static Take MakeTake(string key, Sentence sentence, Sentence? next)
    {
        var words = sentence.Words;
        var spoken = words.Where(word => word.Kind != WordKind.Event).ToArray();
        var fillers = spoken.Count(IsFiller);
        var lexical = sentence.Tokens.Select(token => token.Text).ToArray();
        var flags = new List<string>();
        if (spoken.Length > 0 && spoken.Length <= MaxRestartWords &&
            (fillers + lexical.Length - lexical.Distinct(StringComparer.Ordinal).Count() > spoken.Length * RestartMajority ||
             RestartTokens.Any(phrase => Enumerable.Range(0, Math.Max(0, lexical.Length - phrase.Length + 1))
                 .Any(start => lexical.AsSpan(start, phrase.Length).SequenceEqual(phrase))))) flags.Add("restart");
        if (next is not null && lexical.Length > 0 && next.Words[0].Start - words[^1].End <= FalseStartSeconds &&
            (double)Lcs(sentence.Tokens, next.Tokens.Take(lexical.Length).ToArray())[0] / lexical.Length >= MinimumSimilarity)
            flags.Add("falseStart");
        if (sentence.CutOff) flags.Add("cutOff");

        var pause = 0.0;
        for (var index = 1; index < spoken.Length; index++) pause = Math.Max(pause, spoken[index].Start - spoken[index - 1].End);
        var restarts = 0;
        var runLength = 1;
        for (var index = 1; index < sentence.Tokens.Length; index++)
        {
            var previous = sentence.Tokens[index - 1];
            var current = sentence.Tokens[index];
            runLength = current.Text == previous.Text && words[current.Position].End - words[previous.Position].Start <= RestartRunSeconds
                ? runLength + 1 : 1;
            if (runLength == MinRestartRunWords) restarts++;
        }
        var duration = words[^1].End - words[0].Start;
        var transcribed = spoken.Where(word => word.Kind == WordKind.Word).ToArray();
        var rate = duration > 0 ? 60 * transcribed.Length / duration : 0;
        return new(key, words[0].Id, words[^1].Id, flags.ToArray(),
            new(fillers, pause, restarts, rate, transcribed.Average(word => word.Conf), sentence.CutOff));
    }

    private static SoloRun[] SoloRuns(List<(int First, int End)> ranges, Take[] takes, string?[] matchedIds)
    {
        var result = new List<SoloRun>();
        foreach (var (first, end) in ranges)
        {
            var upcoming = new Queue<string>(matchedIds[first..end].OfType<string>());
            string? after = null;
            int? runStart = null;
            for (var index = first; index <= end; index++)
            {
                if (index < end && matchedIds[index] is null && !takes[index].Flags.Contains("restart") && !takes[index].Flags.Contains("falseStart"))
                {
                    runStart ??= index;
                    continue;
                }
                if (runStart is int start)
                {
                    result.Add(new(takes[start].Key, takes[start].StartWordId, takes[index - 1].EndWordId, index - start,
                        after, upcoming.TryPeek(out var before) ? before : null));
                    runStart = null;
                }
                if (index < end && matchedIds[index] is not null) after = upcoming.Dequeue();
            }
        }
        return result.ToArray();
    }

    private static AlignedSpan Align(string fromKey, Sentence source, string toKey, Sentence target)
    {
        var pairs = Alignment(source.Tokens, target.Tokens);
        var first = target.Tokens[pairs[0].Target].Position;
        var last = target.Tokens[pairs[^1].Target].Position;
        var start = 0;
        for (var index = first - 1; index >= 0; index--)
        {
            if (!ClipText.EndsWithPunctuation(target.Words[index].Text, ClauseBreaks)) continue;
            start = index + 1;
            break;
        }
        var end = ClauseEnd(target, last);
        if (IsIsolatedTail(source, target, pairs)) pairs.RemoveAt(pairs.Count - 1);
        var aligned = pairs.Select(pair => target.Tokens[pair.Target].Position).ToHashSet();
        var changed = Enumerable.Range(start, end - start + 1).Where(index => !aligned.Contains(index))
            .Select(index => target.Words[index].Id).ToArray();
        return new(fromKey, toKey, target.Words[start].Id, target.Words[end].Id, changed);
    }

    private static int ClauseEnd(Sentence sentence, int anchor)
    {
        while (anchor < sentence.Words.Length - 1 && !ClipText.EndsWithPunctuation(sentence.Words[anchor].Text, ClauseBreaks)) anchor++;
        return anchor;
    }

    private static bool IsIsolatedTail(Sentence source, Sentence target, List<(int Source, int Target)> pairs)
    {
        if (pairs.Count < 2) return false;
        var (left, right) = pairs[^1];
        var previous = pairs[^2];
        if (left - previous.Source - 1 < IsolatedTailGapWords || right - previous.Target - 1 < IsolatedTailGapWords) return false;
        return (left == source.Tokens.Length - 1 && ContinuesClause(target, right)) ||
               (right == target.Tokens.Length - 1 && ContinuesClause(source, left));
    }

    private static bool ContinuesClause(Sentence sentence, int token) => token + 1 < sentence.Tokens.Length &&
        sentence.Tokens[token + 1].Position <= ClauseEnd(sentence, sentence.Tokens[token].Position);

    private static List<(int Source, int Target)> Alignment(Token[] source, Token[] target)
    {
        var lengths = Lcs(source, target);
        var width = target.Length + 1;
        var pairs = new List<(int Source, int Target)>();
        int left = 0, right = 0;
        while (left < source.Length && right < target.Length)
        {
            if (source[left].Text == target[right].Text) pairs.Add((left++, right++));
            else if (lengths[(left + 1) * width + right] > lengths[left * width + right + 1]) left++;
            else right++;
        }
        return pairs;
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
            if (members[second].Any(member => recordings.Contains(sentences[member].Recording)) ||
                members[first].Any(source => members[second].Any(target => !Matches(sentences[source], sentences[target]))) ||
                Precedes(first, second) || Precedes(second, first))
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
