using System.Globalization;
using System.Text.Json;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.Share;

/// <summary>A destination with its own post-text measure and limit; publishing §2.1.</summary>
public enum ShareDestination
{
    /// <summary>Open X: twitter-text v3 weighted length, limit 280.</summary>
    X,
    /// <summary>Open LinkedIn: Unicode scalars, limit 3,000; the caption is never cut.</summary>
    LinkedIn,
    /// <summary>VoxConvo publish: UTF-16 code units, limit 2,048.</summary>
    VoxConvo,
}

/// <summary>The rules of shared/data/share-text.json and the pure algorithms that use them; publishing §2.1.
/// <c>SharePostText</c> (Services/Share) loads the file once and forwards to these.</summary>
internal sealed class ShareTextRules
{
    private static readonly string[] Schemes = ["http://", "https://"];
    private readonly (int Start, int End, int Weight)[] weights;
    private readonly (int Start, int End)[] emoji;
    private readonly HashSet<char> trailing;
    private readonly HashSet<string> tlds;

    private ShareTextRules(JsonElement root)
    {
        var x = root.GetProperty("x");
        XLimit = x.GetProperty("maxWeightedTweetLength").GetInt32();
        Scale = x.GetProperty("scale").GetInt32();
        DefaultWeight = x.GetProperty("defaultWeight").GetInt32();
        UrlLength = x.GetProperty("transformedURLLength").GetInt32();
        weights = x.GetProperty("ranges").EnumerateArray()
            .Select(item => (item.GetProperty("start").GetInt32(), item.GetProperty("end").GetInt32(), item.GetProperty("weight").GetInt32())).ToArray();
        LinkedInLimit = root.GetProperty("linkedIn").GetProperty("maxLength").GetInt32();
        VoxConvoLimit = root.GetProperty("voxConvo").GetProperty("maxLength").GetInt32();
        Ellipsis = root.GetProperty("ellipsis").GetString() ?? "";
        var url = root.GetProperty("url");
        var punctuation = url.GetProperty("trailingPunctuation").GetString() ?? "";
        trailing = [.. punctuation];
        tlds = new(url.GetProperty("tlds").EnumerateArray().Select(item => (item.GetString() ?? "").ToLowerInvariant()), StringComparer.Ordinal);
        emoji = root.GetProperty("emoji").GetProperty("ranges").EnumerateArray().Select(pair =>
            pair.GetArrayLength() == 2 ? (pair[0].GetInt32(), pair[1].GetInt32()) : throw new FormatException("An emoji range has two code points.")).ToArray();
        // Sorted, disjoint emoji ranges for the binary search. One ellipsis scalar, itself trailing punctuation, and every trailing
        // scalar stands alone (LastFittingXCut).
        if (root.GetProperty("shareTextVersion").GetInt32() != 1 || Scale <= 0 || weights.Any(item => item.Start > item.End)
            || emoji.Any(item => item.Start > item.End) || emoji.Zip(emoji.Skip(1)).Any(pair => pair.First.End >= pair.Second.Start)
            || Ellipsis.Length != 1 || !trailing.Contains(Ellipsis[0]) || !punctuation.All(StandsAlone))
            throw new FormatException("shared/data/share-text.json is not valid share-text version 1.");
    }

    internal int XLimit { get; }
    internal int Scale { get; }
    internal int DefaultWeight { get; }
    internal int UrlLength { get; }
    internal int LinkedInLimit { get; }
    internal int VoxConvoLimit { get; }
    internal string Ellipsis { get; }
    internal int EmojiRangeCount => emoji.Length;
    internal bool HasTld(string tld) => tlds.Contains(tld);
    internal bool IsTrailing(char character) => trailing.Contains(character);

    internal static ShareTextRules Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return new(document.RootElement);
    }

    internal int Limit(ShareDestination destination) => destination switch
    {
        ShareDestination.X => XLimit,
        ShareDestination.LinkedIn => LinkedInLimit,
        _ => VoxConvoLimit,
    };

    internal int Measure(string text, ShareDestination destination) => destination switch
    {
        ShareDestination.X => XWeight(text),
        ShareDestination.LinkedIn => LinkedInLength(text),
        _ => VoxConvoLength(text),
    };

    internal static int LinkedInLength(string text)
    {
        var count = 0;
        foreach (var _ in text.EnumerateRunes()) count++;
        return count;
    }

    internal static int VoxConvoLength(string text) => text.Length;

    /// <summary>twitter-text v3 weighted length of the NFC text: each URL 23, each emoji cluster 2, other scalars by range.</summary>
    internal int XWeight(string text) => (int)(XTotal(text) / Scale);

    /// <summary>The X weight before the division by <see cref="Scale"/>.</summary>
    private long XTotal(string text)
    {
        var nfc = EditingAlgorithms.Nfc(text);
        long total = 0;
        var position = 0;
        foreach (var (start, end) in UrlRanges(nfc).Append((nfc.Length, nfc.Length)))
        {
            for (var piece = nfc.AsSpan(position, start - position); !piece.IsEmpty;)
            {
                var length = StringInfo.GetNextTextElementLength(piece);
                var isEmoji = false;
                var sum = 0;
                foreach (var rune in piece[..length].EnumerateRunes())
                {
                    isEmoji |= IsEmoji(rune.Value);
                    sum += Weight(rune.Value);
                }
                total += isEmoji ? DefaultWeight : sum;
                piece = piece[length..];
            }
            if (end > start) total += (long)UrlLength * Scale;
            position = end;
        }
        return total;
    }

    /// <summary>URL spans as UTF-16 ranges of NFC text: a non-White_Space run from <c>http://</c> or <c>https://</c>, or from a bare
    /// host with a listed TLD, to the end of the run without its trailing punctuation.</summary>
    internal List<(int Start, int End)> UrlRanges(string s)
    {
        var urls = new List<(int Start, int End)>();
        var start = 0;
        while (start < s.Length)
        {
            if (CaptionTextRules.White(s[start])) { start++; continue; }
            var next = start;
            while (next < s.Length && !CaptionTextRules.White(s[next])) next++;
            var end = next;
            while (end > start && trailing.Contains(s[end - 1])) end--;
            for (var index = start; index < end; index++)
            {
                // Neither a scheme nor a bare host may follow an ASCII letter or digit.
                if (index > start && AsciiAlphanumeric(s[index - 1])) continue;
                if (Scheme(s, index, end) is not null
                    || AsciiAlphanumeric(s[index]) && (index == start || s[index - 1] is not ('@' or '.' or '-' or '/')) && IsHost(s, index, end))
                {
                    urls.Add((index, end));
                    break;
                }
            }
            start = next;
        }
        return urls;
    }

    /// <summary>The text Open X or VoxConvo publish sends; publishing §2.1 and voice-lab §11.3.</summary>
    internal string ComposerText(string caption, ShareDestination destination, string? disclosureLine)
    {
        if (destination == ShareDestination.LinkedIn || Measure(caption, destination) <= Limit(destination)) return caption;
        var body = EditingAlgorithms.Nfc(caption);
        string? line = null;
        if (disclosureLine is not null && ShareDisclosure.LastSpan(disclosureLine, body) is { } span)
        {
            var left = ShareDisclosure.TrimEnd(body[..span.Start]);
            var right = ShareDisclosure.TrimStart(body[span.End..]);
            body = left.Length == 0 || right.Length == 0 ? left + right : left + "\n\n" + right;
            line = disclosureLine;
        }
        return Fit(ShareDisclosure.TrimEnd(body), line, destination);
    }

    /// <summary>Composer rules 3–6: the body, without trailing White_Space, and the line after a blank line; the body is cut
    /// until the text fits <paramref name="destination"/>. A longer kept prefix never measures less, except an X first-word cut,
    /// so bisection finds the longest candidate that fits, each measured whole. <see cref="ShareDisclosure.FieldText"/> cuts
    /// with it too.</summary>
    internal string Fit(string body, string? line, ShareDestination destination)
    {
        var limit = Limit(destination);
        var tail = line is null ? "" : "\n\n" + line;
        bool Fits(string text) => Measure(text, destination) <= limit;
        var whole = body.Length == 0 ? line ?? "" : body + tail;
        if (Fits(whole)) return whole;
        var boundary = new bool[body.Length + 1];
        for (var offset = 0; offset < body.Length; offset += StringInfo.GetNextTextElementLength(body.AsSpan(offset))) boundary[offset] = true;
        boundary[body.Length] = true;
        string Cut(int end) => ShareDisclosure.TrimEnd(body[..end]) + Ellipsis + tail;
        // The longest prefix before a White_Space run after the first word; paragraph breaks inside it are kept. A run that
        // starts inside a cluster (after a Prepend scalar such as U+0600) is no cut.
        var first = 0;
        while (first < body.Length && CaptionTextRules.White(body[first])) first++;
        var runs = new List<int>();
        for (var index = first + 1; index < body.Length; index++)
            if (CaptionTextRules.White(body[index]) && !CaptionTextRules.White(body[index - 1]) && boundary[index]) runs.Add(index);
        if (Last(runs, end => Fits(Cut(end))) is int run) return Cut(run);
        // Not even the first word fits: the last grapheme-cluster boundary inside it that fits. In an X word a URL can come and
        // go as the cut grows, so LastFittingXCut weighs every X cut in one pass.
        var wordEnd = first;
        while (wordEnd < body.Length && !CaptionTextRules.White(body[wordEnd])) wordEnd++;
        var ends = new List<int>();
        for (var index = 0; index < wordEnd; index++) if (boundary[index]) ends.Add(index);
        var fallback = destination == ShareDestination.X ? LastFittingXCut(body, first, wordEnd, ends, tail) : Last(ends, end => Fits(Cut(end)));
        return fallback is int cut ? Cut(cut) : line ?? Ellipsis;
    }

    /// <summary>Composer rule 5 for X in one pass: the cut a scan from the longest cut down picks; publishing §2.1 has the proof.
    /// A cut <c>end</c> after the first scalar of the word keeps <c>body[..end]</c>, then the ellipsis and the tail. Its clusters and
    /// URLs are the body's, except that the run it ends holds the URL <see cref="UrlStarts"/> gives for that run without its trailing
    /// punctuation. URL starts are ASCII and cuts are cluster boundaries, and the ellipsis and trailing punctuation stand alone, so
    /// no piece splits an emoji cluster: a cut weighs prefix sums of per-scalar weights, with an emoji cluster's weight on its first
    /// scalar, plus the ellipsis and the tail weighed whole.</summary>
    private int? LastFittingXCut(string body, int first, int wordEnd, List<int> ends, string tail)
    {
        var prefix = new long[wordEnd + 1];
        for (var start = 0; start < wordEnd;)
        {
            var length = StringInfo.GetNextTextElementLength(body.AsSpan(start, wordEnd - start));
            var isEmoji = false;
            foreach (var rune in body.AsSpan(start, length).EnumerateRunes()) isEmoji |= IsEmoji(rune.Value);
            var index = start;
            foreach (var rune in body.AsSpan(start, length).EnumerateRunes())
            {
                // A surrogate pair weighs on its high surrogate.
                prefix[index + 1] = prefix[index] + (isEmoji ? (index == start ? DefaultWeight : 0) : Weight(rune.Value));
                if (rune.Utf16SequenceLength == 2) prefix[index + 2] = prefix[index + 1];
                index += rune.Utf16SequenceLength;
            }
            start += length;
        }
        var starts = UrlStarts(body, first, wordEnd);
        // stripped[end]: the end of body[first..end] without its trailing punctuation.
        var stripped = new int[wordEnd + 1];
        for (var index = 0; index <= wordEnd; index++) stripped[index] = index > first && trailing.Contains(body[index - 1]) ? stripped[index - 1] : index;
        var tailTotal = XTotal(Ellipsis + tail);
        for (var index = ends.Count - 1; index >= 0; index--)
        {
            var end = ends[index];
            // Every cut up to the first scalar of the word keeps nothing but the ellipsis and the tail.
            if (end <= first) return tailTotal / Scale <= XLimit ? end : null;
            var urlEnd = stripped[end];
            var start = urlEnd > first ? starts[urlEnd] : -1;
            var total = tailTotal + (start >= 0 ? prefix[start] + (long)UrlLength * Scale + prefix[end] - prefix[urlEnd] : prefix[end]);
            if (total / Scale <= XLimit) return end;
        }
        return null;
    }

    /// <summary>For every end <c>e</c> in <c>first + 1..end</c>, the start of the URL <see cref="UrlRanges"/> finds in the run
    /// <c>s[first..e]</c> taken as already stripped, or -1: one pass instead of one scan per end. A start holds for some ends inside
    /// its host or port and, from one end on, for every later end; the host runs of different starts never overlap. The first start
    /// that holds wins, as in <see cref="UrlRanges"/>.</summary>
    private int[] UrlStarts(string s, int first, int end)
    {
        var starts = new int[end + 1];
        Array.Fill(starts, -1);
        var settled = end + 1; // every end from here on has its start
        var longestTld = tlds.Select(tld => tld.Length).DefaultIfEmpty().Max();
        void Mark(int e, int start)
        {
            if (e < settled && starts[e] < 0) starts[e] = start;
        }
        for (var start = first; start < end; start++)
        {
            if (start > first && AsciiAlphanumeric(s[start - 1])) continue;
            if (start + 1 >= settled) break;
            var always = Scheme(s, start, end) is int scheme ? start + scheme : end + 1; // the start holds for every end from here on
            if (AsciiAlphanumeric(s[start]) && (start == first || s[start - 1] is not ('@' or '.' or '-' or '/')))
            {
                int dots = 0, label = start, index = start;
                var labelsValid = true;
                // s[start..e] is a host: valid labels, at least two, the last a listed TLD.
                bool Host(int e) => dots > 0 && labelsValid && e > label && e - label <= longestTld && AsciiAlphanumeric(s[label])
                    && AsciiAlphanumeric(s[e - 1]) && tlds.Contains(AsciiLower(s[label..e]));
                while (index < end && (AsciiAlphanumeric(s[index]) || s[index] is '-' or '.'))
                {
                    if (s[index] == '.')
                    {
                        labelsValid = labelsValid && index > label && AsciiAlphanumeric(s[label]) && AsciiAlphanumeric(s[index - 1]);
                        dots++;
                        label = index + 1;
                    }
                    index++;
                    if (Host(index)) Mark(index, start);
                }
                if (index < end && s[index] == '/' && Host(index)) always = Math.Min(always, index + 1);
                else if (index < end && s[index] == ':' && Host(index))
                {
                    var digits = index + 1;
                    while (digits < end && s[digits] is >= '0' and <= '9') digits++;
                    for (var e = index + 2; e <= digits; e++) Mark(e, start);
                    if (digits > index + 1 && digits < end && s[digits] == '/') always = Math.Min(always, digits + 1);
                }
            }
            for (var e = always; e < settled; e++) Mark(e, start);
            settled = Math.Min(settled, always);
        }
        return starts;
    }

    /// <summary>The last of the ascending <paramref name="candidates"/> that fits, by bisection: they fit up to some candidate
    /// and none after it.</summary>
    private static int? Last(List<int> candidates, Func<int, bool> fits)
    {
        int low = 0, high = candidates.Count;
        while (low < high)
        {
            var middle = (low + high) / 2;
            if (fits(candidates[middle])) low = middle + 1; else high = middle;
        }
        return low > 0 ? candidates[low - 1] : null;
    }

    /// <summary><c>title</c>, blank line, first sentence of the edited, corrected words; publishing §2.1.</summary>
    internal string DefaultCaption(string? title, IEnumerable<string> words)
    {
        var sentence = new List<string>();
        var ended = false;
        foreach (var word in words.Take(40))
        {
            sentence.Add(word);
            if (word.Length > 0 && word[^1] is '.' or '?' or '!' or '…')
            {
                ended = true;
                break;
            }
        }
        var first = string.Join(' ', sentence) + (ended || sentence.Count == 0 ? "" : Ellipsis);
        return string.Join("\n\n", new[] { title ?? "", first }.Where(part => part.Length > 0));
    }

    private int Weight(int scalar)
    {
        foreach (var (start, end, weight) in weights)
            if (scalar >= start && scalar <= end) return weight;
        return DefaultWeight;
    }

    private bool IsEmoji(int scalar)
    {
        if (scalar is 0xFE0F or 0x20E3 or >= 0x1F1E6 and <= 0x1F1FF) return true;
        int low = 0, high = emoji.Length;
        while (low < high)
        {
            var middle = (low + high) / 2;
            if (emoji[middle].End < scalar) low = middle + 1; else high = middle;
        }
        return low < emoji.Length && emoji[low].Start <= scalar;
    }

    private bool IsHost(string s, int start, int end)
    {
        // Only ASCII letters, digits, '-' and '.' can be host, so the scan stops at the first other character.
        var index = start;
        while (index < end && (AsciiAlphanumeric(s[index]) || s[index] is '-' or '.')) index++;
        if (index < end && s[index] is not (':' or '/')) return false;
        var labels = s[start..index].Split('.');
        if (labels.Length < 2 || !labels.All(IsLabel) || !tlds.Contains(AsciiLower(labels[^1]))) return false;
        if (index < end && s[index] == ':')
        {
            var digits = ++index;
            while (index < end && s[index] is >= '0' and <= '9') index++;
            if (index == digits) return false;
        }
        return index == end || s[index] == '/';
    }

    private static bool IsLabel(string label) => label.Length > 0 && AsciiAlphanumeric(label[0]) && AsciiAlphanumeric(label[^1])
        && label.All(character => AsciiAlphanumeric(character) || character == '-');

    /// <summary>The length of the scheme <c>s[start..end]</c> starts with, or null.</summary>
    private static int? Scheme(string s, int start, int end)
    {
        foreach (var scheme in Schemes)
        {
            if (end - start < scheme.Length) continue;
            var match = true;
            for (var offset = 0; match && offset < scheme.Length; offset++) match = AsciiLower(s[start + offset]) == scheme[offset];
            if (match) return scheme.Length;
        }
        return null;
    }

    /// <summary>What <see cref="LastFittingXCut"/> needs of the ellipsis and trailing punctuation. ASCII or General Punctuation, so NFC
    /// never composes it with the scalar before it, and BMP, as the URL scan reads UTF-16; not White_Space or emoji; and its own
    /// grapheme cluster after a letter, an emoji ZWJ sequence and a virama, so it never joins an emoji cluster.</summary>
    private bool StandsAlone(char character) => (character < 0x80 || character is >= (char)0x2000 and <= (char)0x206F)
        && !CaptionTextRules.White(character) && !IsEmoji(character)
        && new StringInfo("a" + character + "a").LengthInTextElements == 3
        && new StringInfo(char.ConvertFromUtf32(0x1F642) + (char)0x200D + character).LengthInTextElements == 2
        && new StringInfo(new string([(char)0x0915, (char)0x094D, character])).LengthInTextElements == 2;

    private static bool AsciiAlphanumeric(char character) => character is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9';

    private static char AsciiLower(char character) => character is >= 'A' and <= 'Z' ? (char)(character + 32) : character;

    private static string AsciiLower(string text) => new(text.Select(AsciiLower).ToArray());
}
