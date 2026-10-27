using System.Globalization;
using System.Text;
using VoxClip.Core.Domain.Editing;

namespace VoxClip.Core.Domain.Captions;

internal static class CaptionTextRules
{
    internal static bool White(int scalar) => scalar is >= 9 and <= 13 or 32 or 133 or 160 or 5760 or >= 8192 and <= 8202 or 8232 or 8233 or 8239 or 8287 or 12288;
    internal static bool Punctuation(Rune rune) => Rune.GetUnicodeCategory(rune) is UnicodeCategory.ConnectorPunctuation or UnicodeCategory.DashPunctuation
        or UnicodeCategory.OpenPunctuation or UnicodeCategory.ClosePunctuation or UnicodeCategory.InitialQuotePunctuation or UnicodeCategory.FinalQuotePunctuation or UnicodeCategory.OtherPunctuation;
    internal static bool Alnum(Rune rune) => Rune.IsLetterOrDigit(rune) || Rune.GetUnicodeCategory(rune) is UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber;
    internal static bool Digit(Rune rune) => Rune.GetUnicodeCategory(rune) == UnicodeCategory.DecimalDigitNumber;
    internal static string Language(string? tag) => new((tag ?? "").Split('-')[0].Select(character => character is >= 'A' and <= 'Z' ? (char)(character + 32) : character).ToArray());
    internal static string Raw(string text)
    {
        var builder = new StringBuilder();
        var pending = false;
        foreach (var rune in EditingAlgorithms.Nfc(text).EnumerateRunes())
        {
            if (White(rune.Value)) { pending = builder.Length > 0; continue; }
            if (pending) builder.Append(' ');
            pending = false;
            builder.Append(rune.ToString());
        }
        return builder.ToString();
    }

    internal static string Case(string text, CaptionTextTransformValue transform, string language, CaptionData data)
    {
        if (transform == CaptionTextTransformValue.None) return text;
        var table = transform == CaptionTextTransformValue.Uppercase ? data.Upper : data.Lower;
        var name = transform == CaptionTextTransformValue.Uppercase ? "uppercase" : "lowercase";
        var rules = new Dictionary<int, string>();
        foreach (var rule in data.Rules.EnumerateArray())
        {
            if (rule.GetProperty("transform").GetString() != name) continue;
            var languages = rule.GetProperty("languages");
            if (languages.ValueKind != System.Text.Json.JsonValueKind.String && !languages.EnumerateArray().Any(item => item.GetString() == language)) continue;
            rules[rule.GetProperty("from")[0].GetInt32()] = string.Concat(rule.GetProperty("to").EnumerateArray().Select(item => new Rune(item.GetInt32()).ToString()));
        }
        var builder = new StringBuilder();
        foreach (var rune in text.EnumerateRunes()) builder.Append(rules.TryGetValue(rune.Value, out var special) ? special : new Rune(table.GetValueOrDefault(rune.Value, rune.Value)).ToString());
        return builder.ToString();
    }

    internal static bool Abbreviation(string text)
    {
        var scalars = text.EnumerateRunes().ToArray();
        return scalars.Length >= 4 && scalars.Length % 2 == 0 && scalars.Where((rune, index) => index % 2 == 0 ? !Rune.IsLetter(rune) : rune.Value != '.').Count() == 0;
    }

    internal static string Normalize(string text, CaptionText options, string language, CaptionData data)
    {
        text = Raw(text);
        if (options.Punctuation == CaptionTextPunctuationValue.StripKeepNumeric && !Abbreviation(text))
        {
            var runes = text.EnumerateRunes().ToArray();
            var builder = new StringBuilder();
            for (var index = 0; index < runes.Length; index++)
            {
                var rune = runes[index];
                var value = rune.Value;
                var joined = index > 0 && index + 1 < runes.Length && Alnum(runes[index - 1]) && Alnum(runes[index + 1]);
                var numeric = index > 0 && index + 1 < runes.Length && Digit(runes[index - 1]) && Digit(runes[index + 1]);
                if (!Punctuation(rune) || "%#@&".Contains(rune.ToString(), StringComparison.Ordinal)
                    || (value is 39 or 8217 or 45 or 8208 or 8209 or 8211 or 8212 or 46 or 47 or 183 && joined)
                    || (value is 44 or 58 && numeric)
                    || (value is 45 or 8211 && index == 0 && index + 1 < runes.Length && Digit(runes[index + 1]))) builder.Append(rune.ToString());
            }
            text = builder.ToString();
        }
        return Raw(Case(text, options.Transform, language, data));
    }

    internal static bool Ends(string raw, bool sentence)
    {
        raw = Raw(raw);
        if (sentence && Abbreviation(raw)) return false;
        var index = raw.Length - 1;
        while (index >= 0 && "\"'”’)]»".Contains(raw[index])) index--;
        return index >= 0 && (sentence ? ".!?…。！？" : ",;:—–").Contains(raw[index]);
    }

    internal static string Key(string text, string language, CaptionData data)
        => string.Concat(Case(EditingAlgorithms.Nfc(text), CaptionTextTransformValue.Lowercase, language, data).EnumerateRunes()
            .Where(rune => !Punctuation(rune) && !White(rune.Value)).Select(rune => rune.ToString()));
}
