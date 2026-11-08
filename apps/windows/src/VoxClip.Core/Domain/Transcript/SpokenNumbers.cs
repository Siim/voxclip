using System.Text;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.Transcript;

/// <summary>Numbers matched however they are written (voice-lab §8.11, ADR-R49). A recognizer writes "three hundred
/// dollars" as "$300" and a script may write "2026" where the voice says "twenty twenty six"; the take QA compares
/// words, so a numeral token on one side matches a run of English number words on the other when both say the same
/// number. Other languages have no spelled-number tables here: a numeral facing up to four other words alone in a gap of
/// the alignment is matched-unverified, neither matched nor a mismatch, and counted. The macOS Core has the same rules
/// (SpokenNumbers.swift); shared/fixtures/spoken-numbers/number-cases.json holds the vectors both replay.</summary>
public static class SpokenNumbers
{
    /// <summary>A currency or percent a numeral carries ("$300", "50%") or a unit word after a number says.</summary>
    public enum Unit
    {
        /// <summary>"$", "dollar", "dollars".</summary>
        Dollar,
        /// <summary>"€", "euro", "euros".</summary>
        Euro,
        /// <summary>"£", "pound", "pounds".</summary>
        Pound,
        /// <summary>"%", "percent", "per cent".</summary>
        Percent,
    }

    /// <summary>A number written in digits: "300", "$300", "1,000", "1.5", "21st", "50%", "300€". <see cref="Value"/> is
    /// the integer part with no leading zeros and the decimal part as written; <see cref="Digits"/> the integer part's
    /// digits as written, without separators, which a digit-by-digit reading says.</summary>
    public sealed record Numeral(string Value, string Digits, bool Ordinal, Unit? Unit)
    {
        /// <summary>The readings this numeral matches: <c>c:</c> a cardinal value, <c>o:</c> an ordinal, <c>d:</c> digits
        /// read one by one.</summary>
        internal string[] Keys => Ordinal ? ["o:" + Value] : Value.Contains('.') ? ["c:" + Value] : ["c:" + Value, "d:" + Digits];
    }

    /// <summary>One word of a transcript or a script: its text normalized for matching
    /// (<see cref="EditingAlgorithms.NormalizeForMatch"/>) and the number it writes in digits, if any.</summary>
    public sealed record Token(string Text, Numeral? Numeral = null)
    {
        /// <summary>One raw word: "$300," is the text "300" and the numeral 300 in dollars.</summary>
        public static Token FromRaw(string raw)
        {
            var composed = raw.Normalize(NormalizationForm.FormC);
            return new(EditingAlgorithms.NormalizeForMatch(composed), Parse(composed));
        }
    }

    /// <summary>The whitespace-separated words of <paramref name="text"/> that keep a letter or a digit, in order.</summary>
    public static Token[] Tokens(string text) => text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
        .Select(Token.FromRaw).Where(token => token.Text.Length > 0).ToArray();

    /// <summary>The pairs of an alignment and what was left unverified, as token indices. A numeral matched to a run of
    /// words is paired with each word of the run, so an index may repeat on the numeral's side.</summary>
    public sealed record Alignment(IReadOnlyList<(int Expected, int Recognized)> Pairs, IReadOnlyList<int> UnverifiedExpected,
        IReadOnlyList<int> UnverifiedRecognized, int UnverifiedNumbers, int ExpectedCount, int RecognizedCount)
    {
        /// <summary>How many expected tokens are paired.</summary>
        public int MatchedExpected => Pairs.Select(pair => pair.Expected).Distinct().Count();
        /// <summary>How many recognized tokens are paired.</summary>
        public int MatchedRecognized => Pairs.Select(pair => pair.Recognized).Distinct().Count();
        /// <summary>The share of tokens matched, leaving unverified tokens out of both sides: 2 × pairs ÷ (expected +
        /// recognized) when no number is involved. 1 when every token is unverified.</summary>
        public double Ratio
        {
            get
            {
                var counted = ExpectedCount + RecognizedCount - UnverifiedExpected.Count - UnverifiedRecognized.Count;
                return counted <= 0 ? 1 : (double)(MatchedExpected + MatchedRecognized) / counted;
            }
        }
        /// <summary>Every token on both sides is matched or unverified: the short-phrase exact rule (voice-lab §8.11).</summary>
        public bool Complete => MatchedExpected + UnverifiedExpected.Count == ExpectedCount &&
            MatchedRecognized + UnverifiedRecognized.Count == RecognizedCount;
    }

    /// <summary>The longest number-word run read against one numeral.</summary>
    public const int LongestRun = 10;
    /// <summary>The most words a numeral may face in another language's gap.</summary>
    public const int LongestUnverifiedRun = 4;

    // Numerals.

    static readonly HashSet<char> LeadingMarks = ['"', '\'', '(', '[', '{', (char)0x201C, (char)0x2018];
    static readonly HashSet<char> TrailingMarks = ['.', ',', '!', '?', ';', ':', '"', '\'', ')', ']', '}', (char)0x201D, (char)0x2019, (char)0x2026];

    static Unit? Currency(char value) => value switch
    {
        '$' => Unit.Dollar,
        (char)0x20AC => Unit.Euro,
        (char)0xA3 => Unit.Pound,
        _ => null,
    };

    static bool IsDigit(char value) => value is >= '0' and <= '9';

    /// <summary>The number a raw word writes in digits, or null for anything else. Quotes, brackets and sentence
    /// punctuation around it are ignored; a currency sign may come before or after the digits, a percent sign or an
    /// ordinal suffix after them. Thousands separators are commas in groups of three; the decimal mark is a point.</summary>
    public static Numeral? Parse(string raw)
    {
        int start = 0, end = raw.Length;
        while (start < end && LeadingMarks.Contains(raw[start])) start++;
        while (end > start && TrailingMarks.Contains(raw[end - 1])) end--;
        var text = raw[start..end];
        Unit? unit = null;
        var index = 0;
        if (text.Length > 0 && Currency(text[0]) is { } sign) { unit = sign; index = 1; }
        var integer = new StringBuilder();
        var groups = new List<int> { 0 };
        while (index < text.Length && (IsDigit(text[index]) || (text[index] == ',' && index + 1 < text.Length && IsDigit(text[index + 1]))))
        {
            if (text[index] == ',') groups.Add(0);
            else { integer.Append(text[index]); groups[^1]++; }
            index++;
        }
        if (integer.Length == 0) return null;
        if (groups.Count > 1 && (groups[0] is < 1 or > 3 || groups.Skip(1).Any(count => count != 3))) return null;
        var fraction = new StringBuilder();
        if (index + 1 < text.Length && text[index] == '.' && IsDigit(text[index + 1]))
        {
            index++;
            while (index < text.Length && IsDigit(text[index])) fraction.Append(text[index++]);
        }
        var suffix = text[index..];
        var ordinal = false;
        if (suffix.Length == 1 && unit is null && suffix[0] == '%') unit = Unit.Percent;
        else if (suffix.Length == 1 && unit is null && Currency(suffix[0]) is { } after) unit = after;
        else if (suffix.Length == 2 && unit is null && fraction.Length == 0)
        {
            // ASCII letters only, so both Cores read the suffix alike.
            var letters = string.Concat(suffix.Select(letter => letter is >= 'A' and <= 'Z' ? (char)(letter + 32) : letter));
            if (letters is not ("st" or "nd" or "rd" or "th")) return null;
            ordinal = true;
        }
        else if (suffix.Length > 0) return null;
        var digits = integer.ToString();
        var trimmed = digits.TrimStart('0');
        var whole = trimmed.Length == 0 ? "0" : trimmed;
        var value = fraction.Length == 0 ? whole : whole + "." + fraction;
        return new Numeral(value, digits, ordinal, unit);
    }

    // Number words.

    enum Kind { Unit, Teen, Tens, Compound, Scale, Oh, Article, And, Point }
    readonly record struct Word(long Value, Kind Kind, bool Ordinal);

    static readonly Dictionary<string, Word> Lexicon = BuildLexicon();

    static Dictionary<string, Word> BuildLexicon()
    {
        var words = new Dictionary<string, Word>(StringComparer.Ordinal)
        {
            ["oh"] = new(0, Kind.Oh, false), ["a"] = new(1, Kind.Article, false), ["and"] = new(0, Kind.And, false),
            ["point"] = new(0, Kind.Point, false),
        };
        string[] units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
        string[] unitOrdinals = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"];
        string[] teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"];
        string[] teenOrdinals = ["tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
            "eighteenth", "nineteenth"];
        string[] tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];
        string[] tensOrdinals = ["twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth", "eightieth", "ninetieth"];
        for (var value = 0; value < units.Length; value++) words[units[value]] = new(value, Kind.Unit, false);
        for (var value = 1; value < unitOrdinals.Length; value++) words[unitOrdinals[value]] = new(value, Kind.Unit, true);
        for (var offset = 0; offset < teens.Length; offset++)
        {
            words[teens[offset]] = new(10 + offset, Kind.Teen, false);
            words[teenOrdinals[offset]] = new(10 + offset, Kind.Teen, true);
        }
        for (var offset = 0; offset < tens.Length; offset++)
        {
            var value = 20 + 10 * offset;
            words[tens[offset]] = new(value, Kind.Tens, false);
            words[tensOrdinals[offset]] = new(value, Kind.Tens, true);
            // "twenty-six" is one token once its hyphen is stripped.
            for (var unit = 1; unit <= 9; unit++)
            {
                words[tens[offset] + units[unit]] = new(value + unit, Kind.Compound, false);
                words[tens[offset] + unitOrdinals[unit]] = new(value + unit, Kind.Compound, true);
            }
        }
        foreach (var (value, word) in new (long, string)[] { (100, "hundred"), (1_000, "thousand"), (1_000_000, "million"), (1_000_000_000, "billion") })
        {
            words[word] = new(value, Kind.Scale, false);
            words[word + "th"] = new(value, Kind.Scale, true);
        }
        return words;
    }

    static Unit? UnitWord(string text) => text switch
    {
        "dollar" or "dollars" => Unit.Dollar,
        "euro" or "euros" => Unit.Euro,
        "pound" or "pounds" => Unit.Pound,
        "percent" => Unit.Percent,
        _ => null,
    };

    /// <summary>An English word that says a number by itself: never one of another language's words in an unverified
    /// gap.</summary>
    static bool IsNumberWord(string text) =>
        Lexicon.TryGetValue(text, out var word) && word.Kind is Kind.Unit or Kind.Teen or Kind.Tens or Kind.Compound or Kind.Scale;

    /// <summary>The digit a word says by itself in a digit run, a year or after "point".</summary>
    static long? Digit(string text) =>
        Lexicon.TryGetValue(text, out var word) && !word.Ordinal && word.Kind is Kind.Unit or Kind.Oh ? word.Value : null;

    /// <summary>A cardinal or ordinal reading of every word: "three hundred" c:300, "two thousand and twenty six" c:2026,
    /// "a hundred" c:100, "one point five" c:1.5, "twenty first" o:21.</summary>
    static string? CardinalKey(IReadOnlyList<string> words)
    {
        long total = 0, group = 0, part = 0;
        Kind? partKind = null;
        bool hundred = false, ordinal = false, waiting = false;
        var lastScale = long.MaxValue;
        for (var index = 0; index < words.Count; index++)
        {
            if (ordinal || !Lexicon.TryGetValue(words[index], out var word)) return null;
            switch (word.Kind)
            {
                case Kind.Article:
                    if (index != 0 || index + 1 >= words.Count || !Lexicon.TryGetValue(words[index + 1], out var next) || next.Kind != Kind.Scale) return null;
                    part = 1; partKind = Kind.Unit; waiting = true;
                    break;
                case Kind.And:
                    if (partKind is not null || !(hundred || lastScale != long.MaxValue) || waiting || index + 1 >= words.Count) return null;
                    waiting = true;
                    break;
                case Kind.Point:
                    if (waiting || index + 1 >= words.Count) return null;
                    var fraction = new StringBuilder();
                    for (var following = index + 1; following < words.Count; following++)
                    {
                        if (Digit(words[following]) is not { } value) return null;
                        fraction.Append(value);
                    }
                    return "c:" + (total + group + part) + "." + fraction;
                case Kind.Unit or Kind.Teen or Kind.Tens or Kind.Compound:
                    // "zero" is a whole number by itself or before "point".
                    if (word.Kind == Kind.Unit && word.Value == 0 && (index != 0 || !(words.Count == 1 || words[1] == "point"))) return null;
                    if (partKind is null) { part = word.Value; partKind = word.Kind; }
                    else if (partKind == Kind.Tens && word.Kind == Kind.Unit && word.Value > 0) { part += word.Value; partKind = Kind.Compound; }
                    else return null;
                    waiting = false; ordinal = word.Ordinal;
                    break;
                case Kind.Scale:
                    if (word.Value == 100)
                    {
                        if (hundred || partKind is null || part < 1) return null;
                        group = part * 100; hundred = true;
                    }
                    else
                    {
                        var value = group + part;
                        if (value < 1 || word.Value >= lastScale) return null;
                        total += value * word.Value; group = 0; hundred = false; lastScale = word.Value;
                    }
                    part = 0; partKind = null; waiting = false; ordinal = word.Ordinal;
                    break;
                default:
                    return null;
            }
        }
        if (waiting || !(partKind is not null || hundred || lastScale != long.MaxValue)) return null;
        return (ordinal ? "o:" : "c:") + (total + group + part);
    }

    /// <summary>10…99 in one word ("nineteen", "twenty", "twentysix") or two ("twenty six").</summary>
    static long? TwoDigits(IReadOnlyList<string> words)
    {
        var found = new List<Word>();
        foreach (var text in words)
        {
            if (!Lexicon.TryGetValue(text, out var word) || word.Ordinal) return null;
            found.Add(word);
        }
        if (found.Count == 1 && found[0].Kind is Kind.Teen or Kind.Tens or Kind.Compound) return found[0].Value;
        if (found.Count == 2 && found[0].Kind == Kind.Tens && found[1].Kind == Kind.Unit && found[1].Value > 0) return found[0].Value + found[1].Value;
        return null;
    }

    /// <summary>A year read in pairs: "twenty twenty six" c:2026, "nineteen ninety seven" c:1997, "nineteen oh five"
    /// c:1905, "nineteen hundred" c:1900.</summary>
    static string? YearKey(IReadOnlyList<string> words)
    {
        if (words.Count is < 2 or > 4) return null;
        for (var split = 1; split <= 2 && split < words.Count; split++)
        {
            if (TwoDigits(words.Take(split).ToArray()) is not { } high) continue;
            var rest = words.Skip(split).ToArray();
            long? low;
            if (rest.Length == 1 && rest[0] == "hundred") low = 0;
            else if (rest.Length == 2 && rest[0] == "oh" && Digit(rest[1]) is { } value && value > 0) low = value;
            else low = TwoDigits(rest);
            if (low is { } found) return "c:" + (high * 100 + found);
        }
        return null;
    }

    /// <summary>Digits read one by one: "one two three" d:123, "two oh two six" d:2026.</summary>
    static string? DigitsKey(IReadOnlyList<string> words)
    {
        if (words.Count < 2) return null;
        var digits = new StringBuilder();
        foreach (var word in words)
        {
            if (Digit(word) is not { } value) return null;
            digits.Append(value);
        }
        return "d:" + digits;
    }

    /// <summary>Every reading of the whole run, in a fixed order, without repeats.</summary>
    static List<string> ReadingKeys(IReadOnlyList<string> words)
    {
        var keys = new List<string>();
        foreach (var key in new[] { CardinalKey(words), YearKey(words), DigitsKey(words) })
            if (key is not null && !keys.Contains(key)) keys.Add(key);
        return keys;
    }

    // Alignment.

    /// <summary>Words starting at one token that a single numeral on the other side may match: a number-word run with
    /// its readings, or a numeral followed by a unit word; either may end with a unit word ("dollars", "per cent").</summary>
    sealed record Group(int Length, IReadOnlyList<string> Keys, Numeral? Numeral, Unit? Unit)
    {
        public bool Matches(Numeral other)
        {
            if (Unit is { } unit && other.Unit != unit) return false;
            if (Numeral is { } numeral)
                return numeral.Value == other.Value && numeral.Ordinal == other.Ordinal && (numeral.Unit is null || numeral.Unit == Unit);
            return Keys.Any(other.Keys.Contains);
        }
    }

    static List<Group>[] Groups(IReadOnlyList<Token> tokens)
    {
        var result = new List<Group>[tokens.Count];
        for (var start = 0; start < tokens.Count; start++)
        {
            var found = new List<Group>();
            for (var length = 1; length <= LongestRun && start + length <= tokens.Count; length++)
            {
                Group core;
                if (tokens[start].Numeral is { } numeral)
                {
                    if (length != 1) break;
                    core = new Group(1, [], numeral, null);
                }
                else
                {
                    var last = tokens[start + length - 1];
                    if (last.Numeral is not null || !Lexicon.ContainsKey(last.Text)) break;
                    var keys = ReadingKeys(tokens.Skip(start).Take(length).Select(token => token.Text).ToArray());
                    if (keys.Count == 0) continue;
                    core = new Group(length, keys, null, null);
                    found.Add(core);
                }
                var next = start + length;
                if (next < tokens.Count && tokens[next].Numeral is null && UnitWord(tokens[next].Text) is { } unit)
                    found.Add(core with { Length = length + 1, Unit = unit });
                if (next + 1 < tokens.Count && tokens[next].Text == "per" && tokens[next + 1].Text == "cent")
                    found.Add(core with { Length = length + 2, Unit = Unit.Percent });
            }
            result[start] = found;
        }
        return result;
    }

    /// <summary>Whether two tokens are the same word: the same number for two numerals (a unit on one side only is
    /// fine), the same normalized text for two other words, never a numeral and another word.</summary>
    static bool Same(Token left, Token right)
    {
        if (left.Numeral is { } one && right.Numeral is { } other)
            return one.Value == other.Value && one.Ordinal == other.Ordinal && (one.Unit is null || other.Unit is null || one.Unit == other.Unit);
        return left.Numeral is null && right.Numeral is null && string.Equals(left.Text, right.Text, StringComparison.Ordinal);
    }

    /// <summary>The alignment that matches the most tokens on both sides, in order. A plain word pair counts two; a
    /// numeral matched to a run of n words counts 1 + n. Without numbers it is the longest common subsequence of equal
    /// tokens. The gaps left over are then read for unverified numbers.</summary>
    public static Alignment Align(IReadOnlyList<Token> expected, IReadOnlyList<Token> recognized)
    {
        int rows = expected.Count, columns = recognized.Count;
        if (rows == 0 || columns == 0) return new([], [], [], 0, rows, columns);
        // Number-word runs only matter against a numeral on the other side.
        var expectedGroups = recognized.Any(token => token.Numeral is not null) ? Groups(expected) : Enumerable.Range(0, rows).Select(_ => new List<Group>()).ToArray();
        var recognizedGroups = expected.Any(token => token.Numeral is not null) ? Groups(recognized) : Enumerable.Range(0, columns).Select(_ => new List<Group>()).ToArray();
        var width = columns + 1;
        // score[(row * width) + column]: the most tokens matched in expected[row..] and recognized[column..].
        var score = new int[(rows + 1) * width];
        for (var row = rows - 1; row >= 0; row--)
            for (var column = columns - 1; column >= 0; column--)
            {
                var here = row * width + column;
                var best = Math.Max(score[here + width], score[here + 1]);
                if (Same(expected[row], recognized[column])) best = Math.Max(best, score[here + width + 1] + 2);
                if (expected[row].Numeral is { } left)
                    foreach (var group in recognizedGroups[column])
                        if (group.Matches(left)) best = Math.Max(best, score[here + width + group.Length] + 1 + group.Length);
                if (recognized[column].Numeral is { } right)
                    foreach (var group in expectedGroups[row])
                        if (group.Matches(right)) best = Math.Max(best, score[here + group.Length * width + 1] + group.Length + 1);
                score[here] = best;
            }
        var pairs = new List<(int Expected, int Recognized)>();
        int at = 0, of = 0;
        while (at < rows && of < columns)
        {
            var here = at * width + of;
            var target = score[here];
            if (Same(expected[at], recognized[of]) && target == score[here + width + 1] + 2)
            {
                pairs.Add((at, of)); at++; of++;
                continue;
            }
            if (expected[at].Numeral is { } left &&
                recognizedGroups[of].FirstOrDefault(group => group.Matches(left) && target == score[here + width + group.Length] + 1 + group.Length) is { } heard)
            {
                for (var offset = 0; offset < heard.Length; offset++) pairs.Add((at, of + offset));
                at++; of += heard.Length;
                continue;
            }
            if (recognized[of].Numeral is { } right &&
                expectedGroups[at].FirstOrDefault(group => group.Matches(right) && target == score[here + group.Length * width + 1] + group.Length + 1) is { } said)
            {
                for (var offset = 0; offset < said.Length; offset++) pairs.Add((at + offset, of));
                at += said.Length; of++;
                continue;
            }
            if (score[here + 1] >= score[here + width]) of++; else at++;
        }
        return Unverified(pairs, expected, recognized);
    }

    /// <summary>Reads each gap between matches: one numeral alone on one side facing one to four words on the other, none
    /// of them a numeral or an English number word, is a number said in another language. Its tokens are unverified.</summary>
    static Alignment Unverified(List<(int Expected, int Recognized)> pairs, IReadOnlyList<Token> expected, IReadOnlyList<Token> recognized)
    {
        var unverifiedExpected = new List<int>();
        var unverifiedRecognized = new List<int>();
        var numbers = 0;
        var anchors = new List<(int Expected, int Recognized)> { (-1, -1) };
        anchors.AddRange(pairs);
        anchors.Add((expected.Count, recognized.Count));
        static bool Foreign(Token token) => token.Numeral is null && !IsNumberWord(token.Text);
        for (var index = 0; index + 1 < anchors.Count; index++)
        {
            var (left, right) = (anchors[index], anchors[index + 1]);
            var expectedGap = Enumerable.Range(left.Expected + 1, Math.Max(0, right.Expected - left.Expected - 1)).ToArray();
            var recognizedGap = Enumerable.Range(left.Recognized + 1, Math.Max(0, right.Recognized - left.Recognized - 1)).ToArray();
            if ((expectedGap.Length == 1 && expected[expectedGap[0]].Numeral is not null && recognizedGap.Length is >= 1 and <= LongestUnverifiedRun &&
                 recognizedGap.All(token => Foreign(recognized[token]))) ||
                (recognizedGap.Length == 1 && recognized[recognizedGap[0]].Numeral is not null && expectedGap.Length is >= 1 and <= LongestUnverifiedRun &&
                 expectedGap.All(token => Foreign(expected[token]))))
            {
                unverifiedExpected.AddRange(expectedGap); unverifiedRecognized.AddRange(recognizedGap); numbers++;
            }
        }
        return new(pairs, unverifiedExpected, unverifiedRecognized, numbers, expected.Count, recognized.Count);
    }
}
