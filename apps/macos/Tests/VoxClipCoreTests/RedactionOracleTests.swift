import CryptoKit
import Foundation
import Testing
@testable import VoxClipCore

/// One marked secret in the oracle corpus, with the shape that holds it.
struct OracleSecret: Sendable {
    let marker, position, field, separator, scheme, form: String
}

/// Architecture §11.2 must remove every marked secret that main's Mac or Windows redactor removed. Both oracles are
/// main's code (branch base 2705fc8, unchanged on main): main's Mac patterns verbatim, and main's Windows steps ported
/// line for line. The corpus is ASCII apart from line breaks, U+212A and U+017F, and .NET's IgnoreCase does not fold
/// U+017F. Each suite checks main's own engine for its platform and the other engine's port only approximately: this
/// suite runs main Mac exactly. Windows Core runs the same corpus, oracles and allowlist in .NET (RedactionOracleTests.cs).
@Suite("Redaction oracle corpus")
struct RedactionOracleTests {
    static let fields = ["authorization", "x-api-key", "xi-api-key", "x-goog-api-key", "api-key", "api_key", "apikey", "access-token",
                         "access_token", "refresh-token", "refresh_token", "client-secret", "client_secret", "password", "secret", "token"]
    static let schemes = ["", "Bearer ", "Basic ", "Key ", "Token ", "Bearer%20"]
    static let separators = [": ", "=", "\":\"", "%3A"]
    static let forms = ["token", "quoted", "single", "json", "field", "empty"]
    static let queryNames = ["key", "api_key", "token", "access_token", "code", "device_code", "user_code", "signature", "sig"]
    static let labelSchemes = schemes + ["Bearer Bearer ", "Basic Bearer "]
    static let lineBreaks = [("vt", "\u{0B}"), ("ff", "\u{0C}"), ("nel", "\u{85}"), ("ls", "\u{2028}"), ("ps", "\u{2029}")]
    /// What follows a field in the label section, with `{M}` for the secret: the review's label forms (BWS, a space
    /// before the colon, unterminated quotes, a label then a line break, JSON labels, nested schemes, repeated scheme
    /// words, label chains), labels and triggers inside or glued to a value, # fragments after query labels, values that
    /// start with a query label, Bearer after eight scheme words, JWTs glued after keys, the Kelvin sign and the long s in
    /// Bearer tokens, and quoted values across other line breaks.
    static let labelForms: [(name: String, template: String)] = [
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
        ("aiza-jwt", "\u{41}IzaQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.{M}"),
        ("sk-jwt", "sk-ant-api03-aaaaaaaaaaaaaaaaaaaaeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.{M}"),
        ("ghp-jwt", "gh\u{70}_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.{M}"), ("bearer-kelvin", "Bearer ab\u{212A}{M}"),
        ("bearer-long-s", "Bearer ab\u{17F}{M}"), ("bearer-kelvin-first", "Bearer \u{212A}ab{M}"),
    ] + lineBreaks.flatMap { name, lineBreak in
        [("quote-\(name)-label", "a=\"x\(lineBreak)password: \"{M}\""), ("quote-\(name)-before", "a=\"{M}\(lineBreak)x\""),
         ("quote-\(name)-after", "a=\"x\(lineBreak){M}\"")]
    }
    /// SHA-256 of every corpus row's output, joined by U+0000. Windows Core pins the same digest, so the two engines give
    /// identical output on every row.
    static let outputDigest = "ad7fe2651c3da46a6df3e010fcd81dac5fad29b0d1077ab3254c2b75e7dcce29"

    /// The secrets all three leave, by shape, with pinned counts. A secret leaks exactly when `allowlisted` names it.
    static let allowlist = ["percent-colon": 2_880, "quoted-after-scheme": 1_792, "json-escaped-quotes": 192, "line-break-after-quote": 32,
                            "scheme-before-line-break": 378, "space-in-query": 18]

    static func allowlisted(_ secret: OracleSecret) -> String? {
        switch secret.position {
        case "header", "split":
            if secret.separator == "%3A" {
                // %3A is not a separator, so the text after it is not a field value; only the Bearer rule still applies.
                return secret.form == "json" || (secret.form == "token" && secret.scheme != "Bearer ") ? "percent-colon" : nil
            }
            if secret.form == "json" && (secret.scheme != "" || secret.separator == "\":\"") {
                // A quoted string is not a value after a scheme word, or after the quote that ends the ":" separator.
                return "quoted-after-scheme"
            }
            guard secret.position == "split", secret.form == "token" else { return nil }
            if secret.scheme == "" {
                // After the closing quote of the ":" separator, a line break ends the field.
                return secret.separator == "\":\"" ? "line-break-after-quote" : nil
            }
            // Only Bearer, and an authorization field's Bearer or Basic, continue on the next line.
            return secret.scheme == "Bearer " || (secret.scheme == "Basic " && secret.field == "authorization") ? nil : "scheme-before-line-break"
        case "label" where secret.separator == "%3A" && (["bare", "closed-glued", "sk-jwt", "ghp-jwt"].contains(secret.form)
                            || secret.form.hasPrefix("quote-") && (secret.form.hasSuffix("-before") || secret.form.hasSuffix("-after"))):
            // %3A is not a separator, so a secret that only the field's value would hold stays, unless Bearer precedes it.
            // A key's class takes the header of a JWT glued to it, so the rest is no JWT.
            return ["bare", "sk-jwt", "ghp-jwt"].contains(secret.form) && secret.scheme.hasSuffix("Bearer ") ? nil : "percent-colon"
        case "jsonBody" where secret.form == "json" || secret.form == "quoted":
            // JSON-escaped quotes (\") inside a JSON string are not quotes to the field rules.
            return "json-escaped-quotes"
        case "query" where ["Basic ", "Key ", "Token "].contains(secret.scheme) && !["api_key", "token", "access_token"].contains(secret.field):
            // A literal space ends a query value; a real URL writes it as %20 or +, which stays in the value.
            return "space-in-query"
        default:
            return nil
        }
    }

    static func value(_ form: String, _ marker: String) -> String {
        switch form {
        case "token": marker
        case "quoted": "token=\"\(marker)\""
        case "single": "token='\(marker)'"
        case "json": "\"\(marker)\""
        case "field": "password: \(marker)"
        default: ""
        }
    }

    /// Every field name × separator × scheme × value form × neighbour in a header dump, then query strings, JSON bodies
    /// and the label section. A neighbour is another credential field on the line before or after; a split row puts the
    /// value on the next line, after the scheme word.
    static func corpus() -> [(row: String, secrets: [OracleSecret])] {
        var rows: [(row: String, secrets: [OracleSecret])] = []
        var count = 0
        func secret(_ position: String, _ field: String, _ separator: String, _ scheme: String, _ form: String) -> OracleSecret {
            count += 1
            return OracleSecret(marker: String(format: "SECRET-%05d", count), position: position, field: field, separator: separator,
                                scheme: scheme, form: form)
        }
        for field in fields {
            for separator in separators {
                for scheme in schemes {
                    let word = scheme.trimmingCharacters(in: CharacterSet(charactersIn: " "))
                    for form in forms {
                        for neighbour in ["alone", "after\r\n", "after\n", "before\r\n", "before\n", "split\r\n", "split\n"] {
                            let split = neighbour.hasPrefix("split")
                            if form == "empty" && (neighbour == "alone" || split) { continue }
                            var held: [OracleSecret] = []
                            var line = field + separator
                            if form == "empty" {
                                line += word
                            } else {
                                let own = secret(split ? "split" : "header", field, separator, scheme, form)
                                held.append(own)
                                line += (split ? word + String(neighbour.dropFirst(5)) : scheme) + value(form, own.marker)
                            }
                            guard neighbour != "alone" && !split else { rows.append((line, held)); continue }
                            let other = secret("neighbour", "x-api-key", ": ", "", "token")
                            held.append(other)
                            let next = "x-api-key: " + other.marker, lineBreak = neighbour.hasSuffix("\r\n") ? "\r\n" : "\n"
                            rows.append((neighbour.hasPrefix("after") ? line + lineBreak + next : next + lineBreak + line, held))
                        }
                    }
                }
            }
        }
        for name in queryNames {
            for scheme in schemes {
                let own = secret("query", name, "=", scheme, "token")
                rows.append(("GET /p?" + name + "=" + scheme + own.marker + "&x=1", [own]))
            }
        }
        for field in fields {
            for scheme in schemes {
                for form in forms.dropLast() {
                    let own = secret("jsonBody", field, "\":\"", scheme, form)
                    let text = (scheme + value(form, own.marker)).replacingOccurrences(of: "\"", with: "\\\"")
                    rows.append(("{\"" + field + "\":\"" + text + "\"}", [own]))
                }
            }
        }
        for field in fields {
            for separator in separators {
                for scheme in labelSchemes {
                    for (name, template) in labelForms {
                        let own = secret("label", field, separator, scheme, name)
                        rows.append((field + separator + scheme + template.replacingOccurrences(of: "{M}", with: own.marker), [own]))
                    }
                }
            }
        }
        return rows
    }

    @Test func rulesLeaveNoSecretThatMainRemoved() {
        let corpus = Self.corpus()
        #expect(corpus.count == 60_566)
        #expect(corpus.reduce(0) { $0 + $1.secrets.count } == 68_246)
        let redactor = Redactor()
        var regressions: [String] = [], unlisted: [String] = [], unstable: [String] = [], outputs: [String] = []
        var leaked: [String: Int] = [:], members: [String: Int] = [:]
        for (row, secrets) in corpus {
            let rules = redactor.redact(row), mac = MainMacOracle.redact(row), windows = MainWindowsOracle.redact(row)
            outputs.append(rules)
            if redactor.redact(rules) != rules { unstable.append(row) }
            for secret in secrets {
                let leaks = rules.contains(secret.marker), reason = Self.allowlisted(secret)
                if leaks && !(mac.contains(secret.marker) && windows.contains(secret.marker)) { regressions.append(row) }
                if let reason { members[reason, default: 0] += 1 }
                if leaks, let reason { leaked[reason, default: 0] += 1 } else if leaks { unlisted.append(row) }
            }
        }
        #expect(regressions.isEmpty, "a main oracle removed these secrets: \(regressions.prefix(5))")
        #expect(unlisted.isEmpty, "leaks outside the allowlist: \(unlisted.prefix(5))")
        #expect(members == Self.allowlist)
        #expect(leaked == Self.allowlist)
        #expect(unstable.isEmpty, "redacting the output again changes it: \(unstable.prefix(5))")
        let digest = SHA256.hash(data: Data(outputs.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.outputDigest)
    }
}

/// main's Mac Redactor rules, verbatim.
enum MainMacOracle {
    static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)(authorization["']?\s*[:=]\s*["']?)(Bearer|Basic)\s+([^\s"',&]+)"#, "$1$2 [REDACTED]"),
        (#"(?i)((?:authorization|x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token)(?:["']?\s*[:=]\s*["']?))(?!(?:Bearer|Basic)\b)([^\s"',&]+)"#, "$1[REDACTED]"),
        (#"(?i)Bearer\s+(?!\[REDACTED\])[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
        (#"(?i)([?&](?:key|api_key|token|access_token|code|device_code|user_code|signature|sig)=)[^&#\s]*"#, "$1[REDACTED]"),
        (#"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|sk_[0-9a-f]{32,}|gh[pousr]_[A-Za-z0-9]{36,}"#, "[REDACTED]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        rules.reduce(text) { $1.0.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: $1.1) }
    }
}

/// main's Windows Redactor steps, ported line for line: Fields, Bearer, the Basic pass, Query and Shapes.
enum MainWindowsOracle {
    static let fields = try! NSRegularExpression(pattern: #"(authorization|x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token)([\"']?\s*[:=]\s*[\"']?)([^\s\"',&]+)"#, options: .caseInsensitive)
    static let steps: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"Bearer\s+[A-Za-z0-9._~+/=-]+"#, options: .caseInsensitive), "Bearer [REDACTED]"),
        (try! NSRegularExpression(pattern: #"(Authorization[\"']?\s*[:=]\s*[\"']?Basic\s+)[^\s\"',&]+"#, options: .caseInsensitive), "$1[REDACTED]"),
        (try! NSRegularExpression(pattern: #"([?&](?:key|api_key|token|access_token|code|device_code|user_code|signature|sig)=)[^&#\s]*"#, options: .caseInsensitive), "$1[REDACTED]"),
        (try! NSRegularExpression(pattern: #"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|sk_[0-9a-f]{32,}|gh[pousr]_[A-Za-z0-9]{36,}"#), "[REDACTED]"),
    ]

    static func redact(_ text: String) -> String {
        // Fields keeps an Authorization value that is the bare word Bearer or Basic and replaces every other value.
        let source = text as NSString
        var result = "", end = 0
        for match in fields.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)), value = source.substring(with: match.range(at: 3))
            let keep = name.lowercased() == "authorization" && ["bearer", "basic"].contains(value.lowercased())
            result += source.substring(with: NSRange(location: end, length: match.range.location - end))
            result += name + source.substring(with: match.range(at: 2)) + (keep ? value : "[REDACTED]")
            end = NSMaxRange(match.range)
        }
        result += source.substring(from: end)
        return steps.reduce(result) { $1.0.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: $1.1) }
    }
}
