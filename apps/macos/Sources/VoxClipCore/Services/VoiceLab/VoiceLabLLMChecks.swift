import Foundation

/// What the Voice Lab LLM sends share (ai.md §12.8): the prompt binding, the estimate, the preflight and the check of the
/// answering model.
enum VoiceLabLLMChecks {
    /// Reads a shared prompt file once: its JSON, and the SHA-256 of its bytes after CRLF→LF, which the quote binds
    /// (voice-lab §8.1), so any edit to the file refuses an earlier quote while a checkout's line endings do not.
    static func readPrompt(_ shared: SharedResources, _ relative: String) throws -> (document: JSONValue, sha256: String) {
        guard let data = try? Data(contentsOf: shared.root.appendingPathComponent(relative)),
              let document = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw VoxClipError.sharedResourcesMissing }
        let bytes = Array(data)
        var normal = Data(capacity: bytes.count)
        for (index, byte) in bytes.enumerated() where byte != 0x0D || index + 1 == bytes.count || bytes[index + 1] != 0x0A {
            normal.append(byte)
        }
        return (document, VoiceLabFingerprint.bytes(normal))
    }

    /// The quote's estimate (voice-lab §8.1 and §8.9.1): `est()` of the whole rendered request (ai.md §11.5), in tokens,
    /// with no known price.
    static func estimate(_ shared: SharedResources, connector: ConnectorID, operation: String, request: String) throws -> CostEstimate {
        let policy = AITokenPolicy(try LLMCatalog(shared: shared).document[ai: "policy"])
        return CostEstimate(provider: connector.rawValue, operation: operation, units: Double(policy.estimate(request)), unit: "token", basis: "unknown")
    }

    /// ai.md §12.8: a model id is 1 to 256 UTF-8 bytes with no control character (Cc).
    static func isValidModel(_ model: String) -> Bool {
        (1...256).contains(model.utf8.count) && !model.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// ai.md §12.8: the output cap is the prompt's, the connector's, or 512 tokens and at least one and a half times the source,
    /// whichever is least. It is nil when that cannot hold the source.
    static func maxOutputTokens(sourceTokens: Int, promptCap: Int, connectorCap: Int?) -> Int? {
        let cap = min(promptCap, connectorCap ?? promptCap, max(512, Int(ceil(Double(sourceTokens) * 1.5))))
        return cap >= sourceTokens ? cap : nil
    }

    /// ai.md §12.8: what a send needs, `est()` of its whole text and compact schema, plus its output cap and 64 tokens.
    static func requiredTokens(_ policy: AITokenPolicy, text: String, schema: String, maxOutputTokens: Int) -> Int {
        policy.estimate(text + schema) + maxOutputTokens + 64
    }

    /// ai.md §12.8: a send fits a context of at least 512 tokens when it needs at most ⌊context × safety factor⌋, the product
    /// taken in binary64.
    static func contextFits(context: Int, required: Int, safetyFactor: Double) -> Bool {
        context >= 512 && required <= Int((Double(context) * safetyFactor).rounded(.down))
    }

    /// ai.md §12.8: the answering model must be the quoted one. Claude Code's curated models are aliases, so there `sonnet`,
    /// `opus` or `haiku` accepts an id starting `claude-<alias>-` and `default` any `claude-` id. An HTTP connector also takes
    /// a dated snapshot of the selected id, `<selected>-YYYY-MM-DD` or `<selected>-YYYYMMDD`. Every other answer needs the
    /// exact id. Ids compare as UTF-8 bytes, never by canonical equivalence.
    static func answeredBy(_ connector: ConnectorID, selected: String, answered: String) -> Bool {
        let choice = Array(selected.utf8), answer = Array(answered.utf8)
        if answer == choice { return true }
        switch connector {
        case .claudeCode:
            if choice == Array("default".utf8) { return answer.starts(with: "claude-".utf8) }
            return ["sonnet", "opus", "haiku"].contains { Array($0.utf8) == choice } && answer.starts(with: "claude-\(selected)-".utf8)
        case .anthropic, .openai, .xai, .gemini, .ollama, .lmstudio:
            guard answer.count > choice.count + 1, answer.starts(with: choice), answer[choice.count] == UInt8(ascii: "-") else { return false }
            return isSnapshotDate(Array(answer[(choice.count + 1)...]))
        case .appleFoundation, .codex: return false
        }
    }

    /// `YYYY-MM-DD` or `YYYYMMDD` in ASCII digits, a date of the Gregorian calendar: 29 February only in a year divisible by
    /// 4 and not by 100, or by 400.
    static func isSnapshotDate(_ suffix: [UInt8]) -> Bool {
        let hyphen = UInt8(ascii: "-")
        let digits: [UInt8]
        if suffix.count == 10, suffix[4] == hyphen, suffix[7] == hyphen {
            digits = Array(suffix[0..<4]) + Array(suffix[5..<7]) + Array(suffix[8..<10])
        } else if suffix.count == 8 {
            digits = suffix
        } else {
            return false
        }
        guard digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return false }
        func number(_ range: Range<Int>) -> Int {
            var total = 0
            for digit in digits[range] {
                let value: Int = Int(digit - UInt8(ascii: "0"))
                total = total * 10 + value
            }
            return total
        }
        let year = number(0..<4), month = number(4..<6), day = number(6..<8)
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...12).contains(month) && (1...lengths[month - 1]).contains(day)
    }
}
