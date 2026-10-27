import Foundation

/// Deterministic, session-local sanitization; architecture §11.2. Never serialize registered secrets.
public struct Redactor: Sendable, Equatable {
    private var secrets: Set<String>
    public let homeDirectory: String

    /// Architecture §11.2 rules 2 to 6, in their normative order: the output depends on it. Windows Core runs the same
    /// pattern text, and shared/fixtures/redaction/cases.json lists it, so both platforms redact identically. Whitespace
    /// is spelled out as the Unicode White_Space class, so both engines use the identical set of characters.
    /// Field names, scheme words and query names match ASCII letters in either case and fold no other letter, except
    /// that Basic's s also matches the long s, as main Mac's ICU did.
    static let rules: [(pattern: String, template: String)] = {
        let space = #"[\t\n\x0B\f\r\x85\p{Z}]"#, token = #"[^\t\n\x0B\f\r\x85\p{Z}"',&]"#
        let names = ascii("x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token")
        // The whitespace loops before a scheme word or a value are atomic: neither starts with whitespace, so giving a
        // character back never helps a match, and a long whitespace run that fails is not retried one character at a time.
        let authorization = ascii("authorization"), separator = #"["']?(?>"# + space + #"*)[:=](?>"# + space + #"*)["']?"#
        let query = ascii("key|api_key|token|access_token|code|device_code|user_code|signature|sig")
        // Basic's s also matches the long s, as main Mac's case-insensitive Basic did.
        let basic = ascii("Ba") + #"[Ss\u017F]"# + ascii("ic")
        // A value never contains another credential label, so each label is redacted by its own match. `label` is a
        // field name with its separator; `stop` adds the later rules' labels: a query name with its `=`, and a Bearer
        // word with the White_Space after it.
        let label = "(?:" + authorization + "|" + names + #")["']?"# + space + "*[:=]"
        let stop = "(?:" + label + "|[?&](?:" + query + ")=|" + ascii("Bearer") + space + ")"
        // Characters of a set up to the first label, or to the end of their run when no label follows.
        func run(_ set: String, _ count: String) -> String { "(?:" + set + count + "?(?=" + stop + ")|" + set + count + ")" }
        // A quoted auth-param value ends at its closing quote, contains no label and never crosses CR or LF.
        func quoted(_ quote: String) -> String { quote + "(?![^" + quote + #"\r\n]*?"# + stop + ")[^" + quote + #"\r\n]*"# + quote }
        // The value never starts with a field or query label, and a Bearer word before a token that is not a label is
        // never the value: the field match backs off, and the Bearer rule replaces the part of that token in its class
        // `[A-Za-z0-9._~+/=\u212A\u017F-]`. A token that starts with another character stays, as on main. The value is a
        // token up to a glued label; an auth-param (nonce="…", nonce='…' or a quote that does not close on its line) with
        // the token glued after it, up to a label; or a token. Only a closed quote holds White_Space, and no value crosses
        // CR or LF.
        // A Bearer or Basic word that ends its line is not a value: the Bearer rule redacts the next line's token after
        // Bearer, or after an authorization field's Basic.
        let value = "(?!" + label + ")(?![?&](?:" + query + ")=)(?!" + ascii("Bearer") + #"[\t\p{Zs}]+(?!"# + label + "))(?:" + token
            + "+?(?=" + stop + ")|" + #"[^\t\n\x0B\f\r\x85\p{Z}"',&=:]+=(?:"# + quoted("\"") + "|"
            + quoted("'") + #"|["'])"# + run(token, "*") + "|(?!(?:" + ascii("Bearer") + "|" + basic + #")[\t\p{Zs}]*[\n\x0B\f\r\x85\p{Zl}\p{Zp}])"#
            + token + "+)"
        // Only horizontal whitespace may follow a scheme word, so the value never continues on the next line. A label is
        // never a scheme word (`token` is both). When a label follows the scheme words, the last scheme word is the value.
        // At most eight scheme words: an open group loop overflows ICU's backtracking stack on a long run of them. A ninth
        // word is the value, unless it is a Bearer word before a token.
        let field = "(" + separator + ")((?:(?!" + label + ")(?:" + ascii("Bearer") + "|" + basic + "|" + ascii("Key|Token")
            + #")(?>[\t\p{Zs}]+)){1,8})?"# + value
        // A JWT match starts only after a character that is not base64url, so each run of base64url characters gets
        // at most one attempt and redaction stays linear. The atomic, bounded segments never backtrack: a header longer
        // than `eyJ` plus 8,192 characters, or a payload over 8,192 characters, is no match, and a longer signature is
        // replaced up to its first 8,192 characters, leaving the rest in the output.
        let segment = #"(?>[A-Za-z0-9_-]{1,8192})"#
        let jwt = #"(?<![A-Za-z0-9_-])eyJ"# + segment + #"\."# + segment + #"\."# + segment
        return [
            ("(" + authorization + ")" + field, "$1$2$3[REDACTED]"),
            ("(" + names + ")" + field, "$1$2$3[REDACTED]"),
            // The Bearer rule follows Bearer anywhere, and an authorization field's Bearer or Basic, across any
            // White_Space, a line break included. A label right after the scheme word, or within the token, is left to
            // its own match. A Bearer token may also hold the Kelvin sign (U+212A), which both main redactors'
            // case-insensitive classes matched, and the long s (U+017F), which main Mac's ICU class matched (main Windows'
            // .NET class did not).
            ("(" + authorization + separator + "(?:" + ascii("Bearer") + "|" + basic + ")" + space + "+)(?!" + stop + ")" + run(token, "+") + "|("
                + ascii("Bearer") + space + "+)(?!" + stop + ")" + run(#"[A-Za-z0-9._~+/=\u212A\u017F-]"#, "+"), "$1$2[REDACTED]"),
            // A query value runs to the next `&` or White_Space, through `#`, so a fragment after it is replaced too.
            (#"([?&](?:"# + query + #")=)[^&\t\n\x0B\f\r\x85\p{Z}]*"#, "$1[REDACTED]"),
            // Each open-ended key shape is a bounded lookahead and a `+` loop over one class. It matches what `{20,}`
            // would, but on an open counted loop ICU stops with an internal error once the loop's backtracking stack
            // overflows: from about 125,000 to 500,000 characters, depending on the rest of the pattern (153,863 for
            // main's rule 5).
            (#"sk-ant-(?=[A-Za-z0-9_-]{16})[A-Za-z0-9_-]+|sk-(?:proj-)?(?=[A-Za-z0-9_-]{20})[A-Za-z0-9_-]+|xai-(?=[A-Za-z0-9]{20})[A-Za-z0-9]+|AIza[0-9A-Za-z_-]{35}|sk_(?=[0-9a-f]{32})[0-9a-f]+|gh[pousr]_(?=[A-Za-z0-9]{36})[A-Za-z0-9]+|"#
                + jwt, "[REDACTED]"),
            // The JWT shape runs again on its own. In one pass its lookbehind sees the original character before `eyJ`.
            // So a JWT glued after an AIza key, whose class stops after 35 characters, is replaced only by this rule. An
            // open-ended key shape takes the header of a JWT glued to it (sk_ takes its 'e'), and the rest of that JWT
            // stays. In a chain of three glued units, the third, a JWT right after a signature that filled its 8,192
            // characters, stays until the output is redacted again.
            (jwt, "[REDACTED]"),
        ]
    }()

    /// The rules compiled once. Nil if a pattern does not compile; every message then redacts to "[REDACTED]".
    private static let expressions = try? rules.map { (try NSRegularExpression(pattern: $0.pattern), $0.template) }

    /// Writes each ASCII letter as a class such as `[Aa]`. The rules use this instead of `(?i)`, which ICU and .NET fold
    /// differently (ß, ſ, the Kelvin sign), so both platforms match the same text. Where main Mac's ICU folding
    /// matched a scheme word or a Bearer token, a rule spells the extra letter out: Basic's s and the Bearer token class.
    static func ascii(_ text: String) -> String {
        text.map { $0.isASCII && $0.isLetter ? "[\($0.uppercased())\($0.lowercased())]" : String($0) }.joined()
    }

    public init(knownSecrets: [String] = [], homeDirectory: String = "") {
        self.secrets = Set(knownSecrets.filter { $0.count >= 8 })
        self.homeDirectory = homeDirectory
    }

    public mutating func register(secret: String) {
        if secret.count >= 8 { secrets.insert(secret) }
    }

    public func redact(_ message: String) -> String {
        var result = message
        for secret in secrets.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        guard let expressions = Self.expressions, let redacted = Self.apply(expressions, to: result) else { return "[REDACTED]" }
        result = redacted
        if !homeDirectory.isEmpty { result = result.replacingOccurrences(of: homeDirectory, with: "~") }
        return result
    }

    /// Applies each rule in order. Nil when ICU reports an internal error, such as a backtracking stack overflow: ICU
    /// then stops matching, and stringByReplacingMatches would return the rest of the text unredacted. The caller fails
    /// closed, as Windows Core does on a regex timeout.
    static func apply(_ expressions: [(NSRegularExpression, String)], to message: String) -> String? {
        var result = message
        for (expression, template) in expressions {
            let source = result as NSString
            var pieces: [String] = [], cursor = 0, completed = false, failed = false
            expression.enumerateMatches(in: result, options: .reportCompletion, range: NSRange(location: 0, length: source.length)) { match, flags, _ in
                if flags.contains(.internalError) { failed = true }
                if flags.contains(.completed) { completed = true }
                guard let match else { return }
                pieces.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                pieces.append(expression.replacementString(for: match, in: result, offset: 0, template: template))
                cursor = NSMaxRange(match.range)
            }
            guard completed, !failed else { return nil }
            pieces.append(source.substring(from: cursor))
            result = pieces.joined()
        }
        return result
    }
}
