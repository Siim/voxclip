import Foundation

/// Deterministic, session-local sanitization; architecture §11.2. Never serialize registered secrets.
public struct Redactor: Sendable, Equatable {
    private var secrets: Set<String>
    public let homeDirectory: String

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
        result = replace(result, pattern: #"(?i)(authorization["']?\s*[:=]\s*["']?)(Bearer|Basic)\s+([^\s"',&]+)"#, template: "$1$2 [REDACTED]")
        result = replace(result, pattern: #"(?i)((?:authorization|x-api-key|xi-api-key|x-goog-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|password|secret|token)(?:["']?\s*[:=]\s*["']?))(?!(?:Bearer|Basic)\b)([^\s"',&]+)"#, template: "$1[REDACTED]")
        result = replace(result, pattern: #"(?i)Bearer\s+(?!\[REDACTED\])[A-Za-z0-9._~+/=-]+"#, template: "Bearer [REDACTED]")
        result = replace(result, pattern: #"(?i)([?&](?:key|api_key|token|access_token|code|device_code|user_code|signature|sig)=)[^&#\s]*"#, template: "$1[REDACTED]")
        result = replace(result, pattern: #"sk-ant-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xai-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|sk_[0-9a-f]{32,}|gh[pousr]_[A-Za-z0-9]{36,}"#, template: "[REDACTED]")
        if !homeDirectory.isEmpty { result = result.replacingOccurrences(of: homeDirectory, with: "~") }
        return result
    }

    private func replace(_ value: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return "[REDACTED]" }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }
}
