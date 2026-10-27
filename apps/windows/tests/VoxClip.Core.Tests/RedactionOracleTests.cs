using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using VoxClip.Core.Domain.Shared;
using Xunit;
namespace VoxClip.Core.Tests;

/// <summary>Architecture §11.2 must remove every marked secret that main's Mac or Windows redactor removed. Both oracles are
/// main's code (branch base 2705fc8, unchanged on main): main's Windows steps verbatim, and main's Mac patterns run in
/// .NET with a CultureInvariant (?i). The corpus is ASCII apart from line breaks, U+212A and U+017F, and .NET's
/// IgnoreCase does not fold U+017F. Each suite checks main's own engine for its platform and the other engine's port only
/// approximately: this suite runs main Windows exactly. Mac Core runs the same corpus, oracles and allowlist in ICU
/// (RedactionOracleTests.swift).</summary>
public sealed class RedactionOracleTests
{
    private sealed record OracleSecret(string Marker, string Position, string Field, string Separator, string Scheme, string Form);

    private static readonly string[] Fields = ["authorization", "x-api-key", "xi-api-key", "x-goog-api-key", "api-key", "api_key", "apikey",
        "access-token", "access_token", "refresh-token", "refresh_token", "client-secret", "client_secret", "password", "secret", "token"];
    private static readonly string[] Schemes = ["", "Bearer ", "Basic ", "Key ", "Token ", "Bearer%20"];
    private static readonly string[] Separators = [": ", "=", "\":\"", "%3A"];
    private static readonly string[] Forms = ["token", "quoted", "single", "json", "field", "empty"];
    private static readonly string[] QueryNames = ["key", "api_key", "token", "access_token", "code", "device_code", "user_code", "signature", "sig"];
    private static readonly string[] LabelSchemes = [.. Schemes, "Bearer Bearer ", "Basic Bearer "];
    private static readonly (string Name, string Break)[] LineBreaks = [("vt", "\v"), ("ff", "\f"), ("nel", "\u0085"), ("ls", "\u2028"), ("ps", "\u2029")];

    /// <summary>What follows a field in the label section, with {M} for the secret: the review's label forms (BWS, a space
    /// before the colon, unterminated quotes, a label then a line break, JSON labels, nested schemes, repeated scheme
    /// words, label chains), labels and triggers inside or glued to a value, # fragments after query labels, values that
    /// start with a query label, Bearer after eight scheme words, JWTs glued after keys, the Kelvin sign and the long s in
    /// Bearer tokens, and quoted values across other line breaks.</summary>
    private static readonly (string Name, string Template)[] LabelForms =
    [
        ("bare", "{M}"), ("bws-eq-quoted", "token = \"{M}\""), ("bws-eq-left-quoted", "token =\"{M}\""), ("bws-eq-right-quoted", "token= \"{M}\""),
        ("bws-eq", "password = {M}"), ("bws-eq-right", "api_key= {M}"), ("bws-eq-left", "secret ={M}"), ("space-colon", "password : {M}"),
        ("space-colon-glued", "x-api-key :{M}"), ("open-double", "token=\"{M}"), ("open-single", "client_secret='{M}"),
        ("open-bws", "token = \"{M}"), ("label-lf", "password:\n{M}"), ("label-crlf", "access_token:\r\n{M}"), ("label-eq-lf", "secret =\n{M}"),
        ("json-label", "password\": \"{M}\""), ("json-label-tight", "api_key\":\"{M}\""), ("nested-bearer", "password: Bearer {M}"),
        ("nested-basic", "token: Basic {M}"), ("nested-key", "secret: Key {M}"), ("nested-authorization", "authorization: Bearer {M}"),
        ("nested-bearer-eol", "password: Bearer\n{M}"), ("nested-repeat", "token: Bearer Bearer {M}"), ("chain", "token: password: {M}"),
        ("chain-scheme", "authorization: token: Bearer {M}"), ("chain-auth-param", "token: Token token=\"{M}\""),
        ("chain-three", "password: token: secret: {M}"), ("quote-space-label", "a=\"x password: \"{M}\""),
        ("quote-tab-label", "a=\"x\tpassword: \"{M}\""), ("quote-glued-label", "a=\"xpassword:\"{M}\""), ("quote-straddle", "a=\"x password\": {M}"),
        ("single-space-label", "a='x password: '{M}'"), ("open-glued-label", "a=\"xpassword: \"{M}"), ("open-label-first", "a=\"password: \"{M}"),
        ("closed-glued", "nonce=\"\"{M}"), ("glued-bearer", "xbearer  {M}"), ("glued-bearer-pct", "Bearer%20xBearer {M}"),
        ("bearer-bearer", "bearerbearer {M}"), ("basic-lf-bearer", "Basic\nBearer {M}"), ("basic-glued-bearer", "Basic xbearer  {M}"),
        ("bearer-lf-glued", "Bearer\nxBearer {M}"), ("quote-query", "a='x?code=''{M}"), ("scheme-query", "Bearer x?code=\"{M}"),
        ("frag-code", "abc?code=xyz#{M}"), ("frag-sig-url", "https://h/p?sig=abc#{M}"), ("frag-state", "https://idp/cb?code=abc#state={M}"),
        ("frag-empty", "k?sig=#{M}"), ("frag-quoted", "\"abc?code=x#{M}\""), ("frag-single", "'abc?code=x#{M}'"),
        ("frag-chain", "a?code=b#c?sig=d#{M}"), ("frag-amp-chain", "x&access_token=abc?device_code=def#{M}"), ("frag-comma", "?api_key=abc,def#{M}"),
        ("frag-token-quote", "?token=x\"y#{M}"), ("lead-query-quote", "?code=a\"{M}\""), ("lead-query-single", "?access_token=abc'{M}"),
        ("lead-query-comma", "?sig=a,{M}"), ("lead-query-bws", "password =\"?code=a\"{M}\""), ("lead-query-chain", "password: ?code=x'{M}'"),
        ("lead-query-glued", "xapi_key: ?code=abc\"{M}"), ("lead-query-escaped", "?code=\\\"{M}\\\""), ("lead-query-scheme", "Key ?code=x\"{M}\""),
        ("ninth-key-bearer", "Key Key Key Key Key Key Key Key Bearer {M}"),
        ("ninth-basic-bearer", "Basic Basic Basic Basic Basic Basic Basic Basic Bearer {M}"),
        ("nine-bearers", "Bearer Bearer Bearer Bearer Bearer Bearer Bearer Bearer Bearer {M}"),
        ("mixed-nine", "Token Basic Key Basic Basic Token Key Token Bearer {M}"),
        ("ninth-bearer-tab", "Token Token Token Token Token Token Token Token Bearer\t{M}"),
        ("twelve-words", "Key Key Key Key Key Key Key Key Key Key Key Bearer {M}"),
        ("aiza-jwt", "AIzaQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.{M}"),
        ("sk-jwt", "sk-ant-api03-aaaaaaaaaaaaaaaaaaaaeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.{M}"),
        ("ghp-jwt", "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.{M}"), ("bearer-kelvin", "Bearer ab\u212A{M}"),
        ("bearer-long-s", "Bearer ab\u017F{M}"), ("bearer-kelvin-first", "Bearer \u212Aab{M}"),
        .. LineBreaks.SelectMany(entry => new[]
        {
            ("quote-" + entry.Name + "-label", "a=\"x" + entry.Break + "password: \"{M}\""), ("quote-" + entry.Name + "-before", "a=\"{M}" + entry.Break + "x\""),
            ("quote-" + entry.Name + "-after", "a=\"x" + entry.Break + "{M}\""),
        }),
    ];

    /// <summary>SHA-256 of every corpus row's output, joined by U+0000. Mac Core pins the same digest, so the two engines give
    /// identical output on every row.</summary>
    private const string OutputDigest = "ad7fe2651c3da46a6df3e010fcd81dac5fad29b0d1077ab3254c2b75e7dcce29";

    /// <summary>The secrets all three leave, by shape, with pinned counts. A secret leaks exactly when Allowlisted names it.</summary>
    private static readonly Dictionary<string, int> Allowlist = new()
    {
        ["percent-colon"] = 2_880, ["quoted-after-scheme"] = 1_792, ["json-escaped-quotes"] = 192, ["line-break-after-quote"] = 32,
        ["scheme-before-line-break"] = 378, ["space-in-query"] = 18,
    };

    private static string? Allowlisted(OracleSecret secret) => secret.Position switch
    {
        // %3A is not a separator, so the text after it is not a field value; only the Bearer rule still applies.
        "header" or "split" when secret.Separator == "%3A" =>
            secret.Form == "json" || (secret.Form == "token" && secret.Scheme != "Bearer ") ? "percent-colon" : null,
        // A quoted string is not a value after a scheme word, or after the quote that ends the ":" separator.
        "header" or "split" when secret.Form == "json" && (secret.Scheme != "" || secret.Separator == "\":\"") => "quoted-after-scheme",
        // After the closing quote of the ":" separator, a line break ends the field.
        "split" when secret.Form == "token" && secret.Scheme == "" => secret.Separator == "\":\"" ? "line-break-after-quote" : null,
        // Only Bearer, and an authorization field's Bearer or Basic, continue on the next line.
        "split" when secret.Form == "token" =>
            secret.Scheme == "Bearer " || (secret.Scheme == "Basic " && secret.Field == "authorization") ? null : "scheme-before-line-break",
        // %3A is not a separator, so a secret that only the field's value would hold stays, unless Bearer precedes it.
        // A key's class takes the header of a JWT glued to it, so the rest is no JWT.
        "label" when secret.Separator == "%3A" && (secret.Form is "bare" or "closed-glued" or "sk-jwt" or "ghp-jwt"
                || secret.Form.StartsWith("quote-", StringComparison.Ordinal) && (secret.Form.EndsWith("-before", StringComparison.Ordinal) || secret.Form.EndsWith("-after", StringComparison.Ordinal))) =>
            secret.Form is "bare" or "sk-jwt" or "ghp-jwt" && secret.Scheme.EndsWith("Bearer ", StringComparison.Ordinal) ? null : "percent-colon",
        // JSON-escaped quotes (\") inside a JSON string are not quotes to the field rules.
        "jsonBody" when secret.Form is "json" or "quoted" => "json-escaped-quotes",
        // A literal space ends a query value; a real URL writes it as %20 or +, which stays in the value.
        "query" when secret.Scheme is "Basic " or "Key " or "Token " && secret.Field is not ("api_key" or "token" or "access_token") => "space-in-query",
        _ => null,
    };

    private static string Value(string form, string marker) => form switch
    {
        "token" => marker,
        "quoted" => $"token=\"{marker}\"",
        "single" => $"token='{marker}'",
        "json" => $"\"{marker}\"",
        "field" => $"password: {marker}",
        _ => "",
    };

    /// <summary>Every field name × separator × scheme × value form × neighbour in a header dump, then query strings, JSON bodies
    /// and the label section. A neighbour is another credential field on the line before or after; a split row puts the
    /// value on the next line, after the scheme word.</summary>
    private static List<(string Row, List<OracleSecret> Secrets)> Corpus()
    {
        var rows = new List<(string Row, List<OracleSecret> Secrets)>();
        var count = 0;
        OracleSecret Secret(string position, string field, string separator, string scheme, string form) =>
            new($"SECRET-{++count:D5}", position, field, separator, scheme, form);
        foreach (var field in Fields)
        foreach (var separator in Separators)
        foreach (var scheme in Schemes)
        foreach (var form in Forms)
        foreach (var neighbour in new[] { "alone", "after\r\n", "after\n", "before\r\n", "before\n", "split\r\n", "split\n" })
        {
            var split = neighbour.StartsWith("split", StringComparison.Ordinal);
            if (form == "empty" && (neighbour == "alone" || split)) continue;
            var held = new List<OracleSecret>();
            var line = field + separator;
            if (form == "empty") line += scheme.TrimEnd(' ');
            else
            {
                var own = Secret(split ? "split" : "header", field, separator, scheme, form);
                held.Add(own);
                line += (split ? scheme.TrimEnd(' ') + neighbour[5..] : scheme) + Value(form, own.Marker);
            }
            if (neighbour == "alone" || split) { rows.Add((line, held)); continue; }
            var other = Secret("neighbour", "x-api-key", ": ", "", "token");
            held.Add(other);
            var next = "x-api-key: " + other.Marker;
            var lineBreak = neighbour.EndsWith("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
            rows.Add((neighbour.StartsWith("after", StringComparison.Ordinal) ? line + lineBreak + next : next + lineBreak + line, held));
        }
        foreach (var name in QueryNames)
        foreach (var scheme in Schemes)
        {
            var own = Secret("query", name, "=", scheme, "token");
            rows.Add(("GET /p?" + name + "=" + scheme + own.Marker + "&x=1", [own]));
        }
        foreach (var field in Fields)
        foreach (var scheme in Schemes)
        foreach (var form in Forms[..^1])
        {
            var own = Secret("jsonBody", field, "\":\"", scheme, form);
            var text = (scheme + Value(form, own.Marker)).Replace("\"", "\\\"", StringComparison.Ordinal);
            rows.Add(("{\"" + field + "\":\"" + text + "\"}", [own]));
        }
        foreach (var field in Fields)
        foreach (var separator in Separators)
        foreach (var scheme in LabelSchemes)
        foreach (var (name, template) in LabelForms)
        {
            var own = Secret("label", field, separator, scheme, name);
            rows.Add((field + separator + scheme + template.Replace("{M}", own.Marker, StringComparison.Ordinal), [own]));
        }
        return rows;
    }

    [Fact]
    public void RulesLeaveNoSecretThatMainRemoved()
    {
        var corpus = Corpus();
        Assert.Equal(60_566, corpus.Count);
        Assert.Equal(68_246, corpus.Sum(row => row.Secrets.Count));
        var redactor = new Redactor();
        var regressions = new List<string>();
        var unlisted = new List<string>();
        var unstable = new List<string>();
        var outputs = new List<string>();
        var leaked = new Dictionary<string, int>();
        var members = new Dictionary<string, int>();
        foreach (var (row, secrets) in corpus)
        {
            string rules = redactor.Redact(row), mac = MainMacOracle.Redact(row), windows = MainWindowsOracle.Redact(row);
            outputs.Add(rules);
            if (redactor.Redact(rules) != rules) unstable.Add(row);
            foreach (var secret in secrets)
            {
                var leaks = rules.Contains(secret.Marker, StringComparison.Ordinal);
                var reason = Allowlisted(secret);
                if (leaks && !(mac.Contains(secret.Marker, StringComparison.Ordinal) && windows.Contains(secret.Marker, StringComparison.Ordinal)))
                    regressions.Add(row);
                if (reason is not null) members[reason] = members.GetValueOrDefault(reason) + 1;
                if (leaks && reason is not null) leaked[reason] = leaked.GetValueOrDefault(reason) + 1;
                else if (leaks) unlisted.Add(row);
            }
        }
        Assert.Empty(regressions);
        Assert.Empty(unlisted);
        Assert.Equal(Allowlist.OrderBy(entry => entry.Key, StringComparer.Ordinal), members.OrderBy(entry => entry.Key, StringComparer.Ordinal));
        Assert.Equal(Allowlist.OrderBy(entry => entry.Key, StringComparer.Ordinal), leaked.OrderBy(entry => entry.Key, StringComparer.Ordinal));
        Assert.Empty(unstable);
        Assert.Equal(OutputDigest, Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\0', outputs)))).ToLowerInvariant());
    }
}

/// <summary>main's Windows Redactor, verbatim apart from the registered secrets and home path, which the corpus does not use.</summary>
file static class MainWindowsOracle
{
    private static readonly Regex Fields = new("(authorization|x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token)([\\\"']?\\s*[:=]\\s*[\\\"']?)([^\\s\\\"',&]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Bearer = new(@"Bearer\s+[A-Za-z0-9._~+/=-]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Query = new(@"([?&](?:key|api_key|token|access_token|code|device_code|user_code|signature|sig)=)[^&#\s]*", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly Regex Shapes = new(@"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|sk_[0-9a-f]{32,}|gh[pousr]_[A-Za-z0-9]{36,}", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    public static string Redact(string message)
    {
        message = Fields.Replace(message, match => match.Groups[1].Value + match.Groups[2].Value +
            (match.Groups[1].Value.Equals("authorization", StringComparison.OrdinalIgnoreCase) &&
             (match.Groups[3].Value.Equals("Bearer", StringComparison.OrdinalIgnoreCase) || match.Groups[3].Value.Equals("Basic", StringComparison.OrdinalIgnoreCase))
                ? match.Groups[3].Value : "[REDACTED]"));
        message = Bearer.Replace(message, "Bearer [REDACTED]");
        message = Regex.Replace(message, @"(Authorization[\""']?\s*[:=]\s*[\""']?Basic\s+)[^\s\""',&]+", "$1[REDACTED]", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
        message = Query.Replace(message, "$1[REDACTED]");
        return Shapes.Replace(message, "[REDACTED]");
    }
}

/// <summary>main's Mac Redactor rules, verbatim, run in .NET.</summary>
file static class MainMacOracle
{
    private static readonly (Regex Pattern, string Template)[] Rules =
    [
        (Rule(@"(?i)(authorization[""']?\s*[:=]\s*[""']?)(Bearer|Basic)\s+([^\s""',&]+)"), "$1$2 [REDACTED]"),
        (Rule(@"(?i)((?:authorization|x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token)(?:[""']?\s*[:=]\s*[""']?))(?!(?:Bearer|Basic)\b)([^\s""',&]+)"), "$1[REDACTED]"),
        (Rule(@"(?i)Bearer\s+(?!\[REDACTED\])[A-Za-z0-9._~+/=-]+"), "Bearer [REDACTED]"),
        (Rule(@"(?i)([?&](?:key|api_key|token|access_token|code|device_code|user_code|signature|sig)=)[^&#\s]*"), "$1[REDACTED]"),
        (Rule(@"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|sk_[0-9a-f]{32,}|gh[pousr]_[A-Za-z0-9]{36,}"), "[REDACTED]"),
    ];

    public static string Redact(string message) => Rules.Aggregate(message, (text, rule) => rule.Pattern.Replace(text, rule.Template));

    private static Regex Rule(string pattern) => new(pattern, RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
}
