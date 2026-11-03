import Foundation

/// One AI-suggested next step for a blocked Rewrite phrase (voice-lab.md §8.2.1): the optional `nextActions` of a
/// voice-rewrite or patch-rewrite reply. `label` is button text only and is never sent; `instruction` is what the app sends
/// back as feedback if the user clicks it. `ordinals` are the phrase numbers the request's feedback named; empty means the
/// phrases blocked when it is clicked. The app drops ordinals its proposal does not hold.
public struct RewriteNextAction: Sendable, Equatable, Codable {
    public let label: String
    public let instruction: String
    public let ordinals: [Int]
    public init(label: String, instruction: String, ordinals: [Int] = []) {
        self.label = label; self.instruction = instruction; self.ordinals = ordinals
    }

    public static let maximumCount = 4
    public static let maximumLabelWords = 6
    static let maximumLabelBytes = 80
    static let maximumInstructionBytes = 1_000
    static let maximumOrdinals = 60

    /// The valid entries of a reply's `nextActions`, at most `maximumCount`, in reply order. An entry is dropped when its
    /// label is empty, longer than six words or 80 bytes, or holds a control character or a link; when its instruction is
    /// empty, over 1,000 bytes, or holds a link or a control character other than a line break; when an ordinal is not a
    /// whole number from 1 to 999; or when its label repeats an earlier one. A missing or non-array value is no actions.
    public static func parse(_ value: JSONValue) -> [RewriteNextAction] {
        var result: [RewriteNextAction] = []
        var labels: Set<String> = []
        for item in value.aiArray {
            guard result.count < maximumCount, let action = parseOne(item) else { continue }
            let key = action.label.lowercased()
            guard labels.insert(key).inserted else { continue }
            result.append(action)
        }
        return result
    }

    private static func parseOne(_ item: JSONValue) -> RewriteNextAction? {
        guard let rawLabel = item[ai: "label"].aiString, let rawInstruction = item[ai: "instruction"].aiString else { return nil }
        let label = AIText.trim(rawLabel), instruction = AIText.trim(rawInstruction)
        guard !label.isEmpty, label.utf8.count <= maximumLabelBytes,
              EditingPrimitives.splitWords(label).count <= maximumLabelWords,
              !hasControl(label, allowingLineBreaks: false), !hasLink(label),
              !instruction.isEmpty, instruction.utf8.count <= maximumInstructionBytes,
              !hasControl(instruction, allowingLineBreaks: true), !hasLink(instruction) else { return nil }
        var ordinals: [Int] = []
        switch item[ai: "ordinals"] {
        case .null: break
        case .array(let values):
            guard values.count <= maximumOrdinals else { return nil }
            for value in values {
                guard let ordinal = value.aiInt, value.aiDouble == Double(ordinal), (1...999).contains(ordinal) else { return nil }
                if !ordinals.contains(ordinal) { ordinals.append(ordinal) }
            }
        default: return nil
        }
        return RewriteNextAction(label: label, instruction: instruction, ordinals: ordinals.sorted())
    }

    private static func hasControl(_ text: String, allowingLineBreaks: Bool) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control && !(allowingLineBreaks && $0 == "\n") }
    }
    private static func hasLink(_ text: String) -> Bool {
        text.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// A phrase a scoped re-ask names in its feedback (`shared/prompts/rewrite-next-actions.json`).
public struct RewriteBlockedPhrase: Sendable, Equatable, Codable {
    /// Why the phrase is blocked: its `reasons` template.
    public enum Reason: String, Sendable, Codable { case fit, budget, take, context, asked }
    public let ordinal: Int
    public let reason: Reason
    public let original: String
    public let proposed: String
    public let estimateSeconds: Double?
    public let slotSeconds: Double?
    public init(ordinal: Int, reason: Reason, original: String, proposed: String, estimateSeconds: Double? = nil, slotSeconds: Double? = nil) {
        self.ordinal = ordinal; self.reason = reason; self.original = original; self.proposed = proposed
        self.estimateSeconds = estimateSeconds; self.slotSeconds = slotSeconds
    }
}

/// The feedback a next step sends back through the Rewrite request's `feedback` (voice-lab.md §8.2.1). Every string comes
/// from `shared/prompts/rewrite-next-actions.json`; placeholders are filled in one pass, so user and AI words are never read
/// as placeholders.
public enum RewriteNextActionFeedback {
    public static let promptPath = "prompts/rewrite-next-actions.json"

    /// Budget figures for the `budget` reason.
    public struct Budget: Sendable, Equatable {
        public let voiceWords: Int
        public let scopeWords: Int
        public init(voiceWords: Int, scopeWords: Int) { self.voiceWords = voiceWords; self.scopeWords = scopeWords }
    }

    /// "REQUESTED FIX … Blocked phrases: …": the instruction applied to `phrases` only.
    public static func scoped(instruction: String, phrases: [RewriteBlockedPhrase], budget: Budget? = nil,
                              shared: SharedResources) throws -> String {
        let templates = try self.templates(shared)
        let request = try checked(instruction)
        guard !phrases.isEmpty, phrases.count <= RewriteNextAction.maximumOrdinals,
              Set(phrases.map(\.ordinal)).count == phrases.count, phrases.allSatisfy({ $0.ordinal > 0 }) else { throw VoiceLabError.invalidInput }
        let lines = try phrases.map { phrase -> String in
            guard let reasonTemplate = templates[ai: "reasons"][ai: phrase.reason.rawValue].aiString else { throw VoxClipError.sharedResourcesMissing }
            var values: [String: String] = [:]
            if phrase.reason == .fit {
                guard let estimate = phrase.estimateSeconds, let slot = phrase.slotSeconds, estimate.isFinite, slot.isFinite else { throw VoiceLabError.invalidInput }
                values = ["estimateSeconds": toFixed1(estimate), "slotSeconds": toFixed1(slot)]
            } else if phrase.reason == .budget {
                guard let budget else { throw VoiceLabError.invalidInput }
                values = ["voiceWords": String(budget.voiceWords), "scopeWords": String(budget.scopeWords)]
            }
            let reason = fill(reasonTemplate, values)
            return try fill(template(templates, "scopedPhraseLine"), ["ordinal": String(phrase.ordinal), "reason": reason,
                                                                     "original": phrase.original, "proposed": phrase.proposed])
        }
        let block = fill(try template(templates, "scopedFeedbackBlock"), ["instruction": request, "phrases": lines.joined(separator: "\n\n")])
        guard block.utf8.count <= 20_000 else { throw VoiceLabError.invalidInput }
        return block
    }

    /// "REQUESTED FIX …" with no phrases: a failed or stale Rewrite asked again with the user's words.
    public static func open(instruction: String, shared: SharedResources) throws -> String {
        fill(try template(try templates(shared), "openFeedbackBlock"), ["instruction": try checked(instruction)])
    }

    /// The built-in "Change fewer words" instruction for a budget of `limit` re-voiced words.
    public static func fewerWords(limit: Int, shared: SharedResources) throws -> String {
        guard limit >= 0 else { throw VoiceLabError.invalidInput }
        return fill(try template(try templates(shared), "fewerWordsInstruction"), ["limit": String(limit)])
    }

    private static func templates(_ shared: SharedResources) throws -> JSONValue {
        let document = try VoiceLabLLMChecks.readPrompt(shared, promptPath).document
        guard document[ai: "schemaVersion"].aiInt == 1 else { throw VoxClipError.sharedResourcesMissing }
        return document[ai: "request"]
    }
    private static func template(_ templates: JSONValue, _ key: String) throws -> String {
        guard let value = templates[ai: key].aiString else { throw VoxClipError.sharedResourcesMissing }
        return value
    }
    private static func checked(_ instruction: String) throws -> String {
        let text = AIText.trim(instruction)
        guard !text.isEmpty, text.utf8.count <= RewriteNextAction.maximumInstructionBytes,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" }) else { throw VoiceLabError.invalidInput }
        return text
    }
    private static func fill(_ template: String, _ values: [String: String]) -> String {
        template.replacing(#/\{([A-Za-z]+)\}/#) { match in values[String(match.1)] ?? String(match.0) }
    }
}

/// How a scoped re-ask's reply lands on the proposal it was asked for (voice-lab.md §8.2.1): only the asked phrases can
/// change; every other change is frozen. Spans are the hunks' `sourceStartIndex..<sourceEndIndex` over the same source.
public enum RewriteScopedReply {
    public enum Outcome: Sendable, Equatable {
        /// The reply's hunk at this index replaces the phrase.
        case replace(Int)
        /// The reply leaves the phrase's words as recorded: the original words are kept.
        case keepOriginal
        /// The reply's change here also reaches a frozen change, another asked phrase, or comes in several pieces; the phrase
        /// stays as it was.
        case conflict
    }

    /// The outcome for each asked hunk index (`asked`, indexes into `current`).
    public static func assign(current: [VoiceLabDiffHunk], asked: Set<Int>, reply: [VoiceLabDiffHunk]) -> [Int: Outcome] {
        var result: [Int: Outcome] = [:]
        for index in asked.sorted() where current.indices.contains(index) {
            let candidates = reply.indices.filter { touches(current[index], reply[$0]) }
            guard let only = candidates.first else { result[index] = .keepOriginal; continue }
            guard candidates.count == 1 else { result[index] = .conflict; continue }
            let reaches = current.indices.contains { $0 != index && touches(current[$0], reply[only]) }
            result[index] = reaches ? .conflict : .replace(only)
        }
        return result
    }

    /// Two spans overlap, or an insertion sits inside or at the edge of the other.
    static func touches(_ lhs: VoiceLabDiffHunk, _ rhs: VoiceLabDiffHunk) -> Bool {
        let a = (lhs.sourceStartIndex, max(lhs.sourceStartIndex, lhs.sourceEndIndex))
        let b = (rhs.sourceStartIndex, max(rhs.sourceStartIndex, rhs.sourceEndIndex))
        if a.0 == a.1 || b.0 == b.1 { return a.0 <= b.1 && b.0 <= a.1 }
        return a.0 < b.1 && b.0 < a.1
    }
}
