using System.Text.RegularExpressions;
namespace VoxClip.Core.Domain.Shared;

/// <summary>Pure text redaction boundary; architecture §11.2 and AI §3.2. Does not emit or retain logs.</summary>
public interface IRedactor
{
    /// <summary>Return safe text without persisting or logging the input.</summary>
    string Redact(string message);
}

/// <summary>Pure redaction over an injected secret snapshot and home path; architecture §11.2. Register secrets in the logging service.</summary>
public sealed class Redactor(IEnumerable<string>? secrets = null, string? homeDirectory = null) : IRedactor
{
    private const string Space = @"[\t\n\x0B\f\r\x85\p{Z}]";
    private const string Token = @"[^\t\n\x0B\f\r\x85\p{Z}""',&]";
    // The whitespace loops before a scheme word or a value are atomic: neither starts with whitespace, so giving a
    // character back never helps a match, and a long whitespace run that fails is not retried one character at a time.
    private const string Separator = @"[""']?(?>" + Space + @"*)[:=](?>" + Space + @"*)[""']?";
    private static readonly string Names = Ascii("x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token");
    private static readonly string Authorization = Ascii("authorization");
    private static readonly string Query = Ascii("key|api_key|token|access_token|code|device_code|user_code|signature|sig");
    // Basic's s also matches the long s, as main Mac's case-insensitive Basic did.
    private static readonly string Basic = Ascii("Ba") + @"[Ss\u017F]" + Ascii("ic");
    // A value never contains another credential label, so each label is redacted by its own match. Label is a
    // field name with its separator; Stop adds the later rules' labels: a query name with its "=", and a Bearer
    // word with the White_Space after it.
    private static readonly string Label = "(?:" + Authorization + "|" + Names + @")[""']?" + Space + "*[:=]";
    private static readonly string Stop = "(?:" + Label + "|[?&](?:" + Query + ")=|" + Ascii("Bearer") + Space + ")";
    // The value never starts with a field or query label, and a Bearer word before a token that is not a label is
    // never the value: the field match backs off, and the Bearer rule replaces the part of that token in its class
    // [A-Za-z0-9._~+/=\u212A\u017F-]. A token that starts with another character stays, as on main. The value is a
    // token up to a glued label; an auth-param (nonce="…", nonce='…' or a quote that does not close on its line) with
    // the token glued after it, up to a label; or a token. Only a closed quote holds White_Space, and no value crosses
    // CR or LF.
    // A Bearer or Basic word that ends its line is not a value: the Bearer rule redacts the next line's token after
    // Bearer, or after an authorization field's Basic.
    private static readonly string Value = "(?!" + Label + ")(?![?&](?:" + Query + ")=)(?!" + Ascii("Bearer") + @"[\t\p{Zs}]+(?!" + Label + "))(?:" + Token
        + "+?(?=" + Stop + ")|" + @"[^\t\n\x0B\f\r\x85\p{Z}""',&=:]+=(?:" + Quoted("\"") + "|"
        + Quoted("'") + @"|[""'])" + Run(Token, "*") + "|(?!(?:" + Ascii("Bearer") + "|" + Basic + @")[\t\p{Zs}]*[\n\x0B\f\r\x85\p{Zl}\p{Zp}])"
        + Token + "+)";
    // Only horizontal whitespace may follow a scheme word, so the value never continues on the next line. A label is
    // never a scheme word ("token" is both). When a label follows the scheme words, the last scheme word is the value.
    // At most eight scheme words: an open group loop overflows ICU's backtracking stack on a long run of them. A ninth
    // word is the value, unless it is a Bearer word before a token.
    private static readonly string Field = "(" + Separator + ")((?:(?!" + Label + ")(?:" + Ascii("Bearer") + "|" + Basic + "|" + Ascii("Key|Token")
        + @")(?>[\t\p{Zs}]+)){1,8})?" + Value;
    // A JWT match starts only after a character that is not base64url, so each run of base64url characters gets
    // at most one attempt and redaction stays linear. The atomic, bounded segments never backtrack: a header longer
    // than eyJ plus 8,192 characters, or a payload over 8,192 characters, is no match, and a longer signature is
    // replaced up to its first 8,192 characters, leaving the rest in the output.
    private const string Segment = @"(?>[A-Za-z0-9_-]{1,8192})";
    private const string Jwt = @"(?<![A-Za-z0-9_-])eyJ" + Segment + @"\." + Segment + @"\." + Segment;

    /// <summary>Architecture §11.2 rules 2 to 6, in their normative order: the output depends on it. Mac Core runs the same
    /// pattern text, and shared/fixtures/redaction/cases.json lists it, so both platforms redact identically. Whitespace
    /// is spelled out as the Unicode White_Space class, so both engines use the identical set of characters.
    /// Field names, scheme words and query names match ASCII letters in either case and fold no other letter, except
    /// that Basic's s also matches the long s, as main Mac's ICU did.</summary>
    internal static readonly (Regex Pattern, string Template)[] Rules =
    [
        (Rule("(" + Authorization + ")" + Field), "$1$2$3[REDACTED]"),
        (Rule("(" + Names + ")" + Field), "$1$2$3[REDACTED]"),
        // The Bearer rule follows Bearer anywhere, and an authorization field's Bearer or Basic, across any
        // White_Space, a line break included. A label right after the scheme word, or within the token, is left to
        // its own match. A Bearer token may also hold the Kelvin sign (U+212A), which both main redactors'
        // case-insensitive classes matched, and the long s (U+017F), which main Mac's ICU class matched (main Windows'
        // .NET class did not).
        (Rule("(" + Authorization + Separator + "(?:" + Ascii("Bearer") + "|" + Basic + ")" + Space + "+)(?!" + Stop + ")" + Run(Token, "+") + "|("
            + Ascii("Bearer") + Space + "+)(?!" + Stop + ")" + Run(@"[A-Za-z0-9._~+/=\u212A\u017F-]", "+")), "$1$2[REDACTED]"),
        // A query value runs to the next & or White_Space, through #, so a fragment after it is replaced too.
        (Rule(@"([?&](?:" + Query + @")=)[^&\t\n\x0B\f\r\x85\p{Z}]*"), "$1[REDACTED]"),
        // Each open-ended key shape is a bounded lookahead and a + loop over one class. It matches what {20,} would,
        // but on an open counted loop ICU stops with an internal error once the loop's backtracking stack overflows:
        // from about 125,000 to 500,000 characters, depending on the rest of the pattern (153,863 for main's rule 5).
        (Rule(@"sk-ant-(?=[A-Za-z0-9_-]{16})[A-Za-z0-9_-]+|sk-(?:proj-)?(?=[A-Za-z0-9_-]{20})[A-Za-z0-9_-]+|xai-(?=[A-Za-z0-9]{20})[A-Za-z0-9]+|AIza[0-9A-Za-z_-]{35}|sk_(?=[0-9a-f]{32})[0-9a-f]+|gh[pousr]_(?=[A-Za-z0-9]{36})[A-Za-z0-9]+|"
            + Jwt), "[REDACTED]"),
        // The JWT shape runs again on its own. In one pass its lookbehind sees the original character before eyJ. So a
        // JWT glued after an AIza key, whose class stops after 35 characters, is replaced only by this rule. An
        // open-ended key shape takes the header of a JWT glued to it (sk_ takes its 'e'), and the rest of that JWT
        // stays. In a chain of three glued units, the third, a JWT right after a signature that filled its 8,192
        // characters, stays until the output is redacted again.
        (Rule(Jwt), "[REDACTED]"),
    ];

    private readonly string[] knownSecrets = (secrets ?? []).Where(secret => secret.Length >= 8).Distinct(StringComparer.Ordinal)
        .OrderByDescending(secret => secret.Length).ToArray();

    /// <summary>Redacts in the normative order; callers must never log the original on failure.</summary>
    public string Redact(string message)
    {
        ArgumentNullException.ThrowIfNull(message);
        try
        {
            foreach (var secret in knownSecrets) message = message.Replace(secret, "[REDACTED]", StringComparison.Ordinal);
            foreach (var (pattern, template) in Rules) message = pattern.Replace(message, template);
            return string.IsNullOrEmpty(homeDirectory) ? message : message.Replace(homeDirectory, "~", StringComparison.Ordinal);
        }
        catch (RegexMatchTimeoutException) { return "[REDACTED]"; }
    }

    private static Regex Rule(string pattern) => new(pattern, RegexOptions.None, TimeSpan.FromSeconds(1));

    /// <summary>Characters of a set up to the first label, or to the end of their run when no label follows.</summary>
    private static string Run(string set, string count) => "(?:" + set + count + "?(?=" + Stop + ")|" + set + count + ")";

    /// <summary>A quoted auth-param value ends at its closing quote, contains no label and never crosses CR or LF.</summary>
    private static string Quoted(string quote) => quote + "(?![^" + quote + @"\r\n]*?" + Stop + ")[^" + quote + @"\r\n]*" + quote;

    /// <summary>Writes each ASCII letter as a class such as [Aa]. The rules use this instead of (?i), which .NET and ICU
    /// fold differently (ß, ſ, the Kelvin sign), so both platforms match the same text. Where main Mac's ICU folding
    /// matched a scheme word or a Bearer token, a rule spells the extra letter out: Basic's s and the Bearer token class.</summary>
    private static string Ascii(string text) =>
        string.Concat(text.Select(c => char.IsAsciiLetter(c) ? $"[{char.ToUpperInvariant(c)}{char.ToLowerInvariant(c)}]" : c.ToString()));
}
