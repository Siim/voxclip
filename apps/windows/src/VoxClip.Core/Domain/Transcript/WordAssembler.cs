using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Core.Domain.Transcript;

/// <summary>Pure raw-token assembly; transcription §6.</summary>
public static class WordAssembler
{
    /// <summary>Group tokens without changing their order.</summary>
    public static IReadOnlyList<RawWord> Group(IReadOnlyList<RawToken> tokens, GroupingRule rule, double timelineStart)
    {
        var drafts = new List<Draft>();
        foreach (var token in tokens)
        {
            if (drafts.Count == 0 || !token.JoinsPrevious || token.Group != drafts[^1].Group ||
                token.Kind == WordKind.Event || drafts[^1].Kind == WordKind.Event)
                drafts.Add(new Draft(token));
            else drafts[^1].Add(token);
        }
        var words = new List<RawWord>();
        for (var index = 0; index < drafts.Count; index++)
        {
            var draft = drafts[index];
            var start = draft.Tokens.Select(token => token.Start).FirstOrDefault(value => value.HasValue);
            var end = draft.Tokens.Select(token => token.End).LastOrDefault(value => value.HasValue);
            if (rule.End == GroupingEnd.NextWordStart)
            {
                for (var next = index + 1; next < drafts.Count && drafts[next].Group == draft.Group; next++)
                {
                    if (TextRules.IsPunctuation(drafts[next].Text)) continue;
                    var nextStart = drafts[next].Tokens.Select(token => token.Start).FirstOrDefault(value => value.HasValue);
                    if (!nextStart.HasValue) continue;
                    end = nextStart;
                    break;
                }
                if (start.HasValue && end.HasValue) end = Math.Max(end.Value, start.Value + 0.04);
            }
            var confidences = draft.Tokens.Where(token => token.Conf.HasValue).Select(token => token.Conf!.Value).ToArray();
            double? confidence = rule.Conf switch
            {
                GroupingConfidence.Single => draft.Tokens[0].Conf,
                GroupingConfidence.Mean => confidences.Length == 0 ? null : confidences.Average(),
                _ => confidences.Length == 0 ? null : confidences.Min()
            };
            words.Add(new(draft.Text, start + timelineStart, end + timelineStart,
                confidence is { } value && double.IsFinite(value) ? Math.Clamp(value, 0, 1) : null,
                draft.Tokens[0].Speaker, draft.Kind));
        }
        if (!rule.BracketEvents) return words;
        var events = new List<RawWord>();
        for (var index = 0; index < words.Count; index++)
        {
            var word = words[index];
            var text = word.Text;
            var closer = text.StartsWith('[') ? ']' : text.StartsWith('(') ? ')' : '\0';
            if (closer != '\0' && !text.Contains(closer))
            {
                var consumed = 0;
                while (index + 1 < words.Count && drafts[index + 1].Group == drafts[index].Group && consumed < 6)
                {
                    var following = words[++index];
                    text += " " + following.Text;
                    word = word with { Text = text, End = following.End };
                    consumed++;
                    if (text.Contains(closer)) break;
                }
            }
            var music = text.Length > 0 && text.All(character => character is '♪' or '♫' || char.IsWhiteSpace(character));
            var bracket = text.Length >= 2 && text[0] is '[' or '(' && text[^1] is ']' or ')';
            if (bracket || music)
            {
                var letters = string.Concat(text.EnumerateRunes().Where(Rune.IsLetter)).ToLowerInvariant();
                if (music || letters is "blankaudio" or "silence" or "nospeech" or "music" or "inaudible") continue;
                word = word with { Kind = WordKind.Event };
            }
            events.Add(word);
        }
        return events;
    }

    private sealed class Draft(RawToken token)
    {
        internal string Text { get; private set; } = token.Text;
        internal int Group { get; } = token.Group;
        internal WordKind Kind { get; } = token.Kind ?? WordKind.Word;
        internal List<RawToken> Tokens { get; } = [token];
        internal void Add(RawToken next) { Text += next.Text; Tokens.Add(next); }
    }
}

internal static class TextRules
{
    internal static string Trim(string text) => text.Trim('\u0009', '\u000a', '\u000b', '\u000c', '\u000d', '\u0020', '\u00a0',
        '\u1680', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200a',
        '\u2028', '\u2029', '\u202f', '\u205f', '\u3000', '\ufeff');

    internal static bool IsPunctuation(string text) => text.Length > 0 && text.EnumerateRunes().All(character =>
        Rune.GetUnicodeCategory(character) is UnicodeCategory.ConnectorPunctuation or UnicodeCategory.DashPunctuation or
        UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation or UnicodeCategory.InitialQuotePunctuation or
        UnicodeCategory.FinalQuotePunctuation or UnicodeCategory.OtherPunctuation);

}
