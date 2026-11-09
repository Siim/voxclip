import Foundation
import CryptoKit

/// One message to Claude about one change of a Rewrite proposal (design.md §6.3 "Talk back to Claude", ADR-R50): the
/// scope's transcript as the passage request sends it, the change's recorded words, every version of its new words so
/// far and every message the user wrote about it, in order. The newest message is the instruction.
public struct RewriteFollowupRequest: Sendable, Equatable, Codable {
    /// A reply gives one new version; `versions` ("3 more versions") gives alternatives.
    public enum Kind: String, Sendable, Codable { case reply, versions }
    public var kind: Kind
    /// The scope as the source block names it: "passage", "clip" or "fullTake".
    public var scope: String
    public var language: String
    /// The scope's words, joined by spaces, as Rewrite's passage request sends them.
    public var source: String
    /// The change's ordinal, "Change 2" in the transcript and the change list.
    public var ordinal: Int
    /// The speaker's words the change replaces, as recorded (corrected spelling); empty for an insertion.
    public var recorded: String
    /// Every version of the change's new words so far, oldest first; the last is in the text now.
    public var versions: [String]
    /// Every message the user sent about the change, oldest first; the last is the instruction.
    public var messages: [String]

    public init(kind: Kind = .reply, scope: String, language: String, source: String, ordinal: Int, recorded: String,
                versions: [String], messages: [String]) {
        self.kind = kind; self.scope = scope; self.language = language; self.source = source; self.ordinal = ordinal
        self.recorded = recorded; self.versions = versions; self.messages = messages
    }
}

/// Claude's checked answer to a `RewriteFollowupRequest`: one new version (`texts` holds one) or up to the prompt's
/// alternatives, its note and its own next steps.
public struct RewriteFollowupReply: Sendable, Equatable {
    /// The new versions' spoken words, in order: one for a reply, up to three for "3 more versions".
    public var texts: [String]
    /// One sentence on what changed, at most `maxNoteWords` words.
    public var note: String
    /// Claude's next steps for this text, at most two of at most six words each: the thread's ✦ bubbles.
    public var nextSteps: [String]
    public init(texts: [String], note: String, nextSteps: [String]) { self.texts = texts; self.note = note; self.nextSteps = nextSteps }
}

/// shared/prompts/rewrite-followup.json (ai.md §12.10). Pure: the same inputs give the same strings, which
/// shared/fixtures/rewrite-thread/request-cases.json pins.
public struct RewriteFollowupPrompt: Sendable {
    public static let path = "prompts/rewrite-followup.json"
    public let document: JSONValue
    public let sha256: String

    public init(data: Data) throws {
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        let request = document[ai: "request"]
        guard document[ai: "schemaVersion"].aiInt == 1, document[ai: "promptVersion"].aiInt == 1, document[ai: "system"].aiString != nil,
              ["sourceBlock", "changeBlock", "noRecorded", "versionsBlock", "versionLine", "messagesBlock", "messageLine", "returnLine",
               "versionsReturnLine"].allSatisfy({ request[ai: $0].aiString != nil }),
              CanonicalResponseParser.validateSchemaSubset(document[ai: "schema"]),
              CanonicalResponseParser.validateSchemaSubset(document[ai: "versionsSchema"]) else { throw VoxClipError.sharedResourcesMissing }
        self.document = document
        self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(shared: SharedResources) throws -> RewriteFollowupPrompt {
        try RewriteFollowupPrompt(data: Data(contentsOf: shared.root.appendingPathComponent(path)))
    }

    public var promptVersion: Int { document[ai: "promptVersion"].aiInt ?? 1 }
    public var system: String { document[ai: "system"].aiString ?? "" }
    private func limit(_ key: String, _ fallback: Int) -> Int { document[ai: "limits"][ai: key].aiInt ?? fallback }
    public var maxMessages: Int { limit("maxMessages", 24) }
    public var maxMessageChars: Int { limit("maxMessageChars", 1000) }
    public var maxVersions: Int { limit("maxVersions", 40) }
    public var maxTextChars: Int { limit("maxTextChars", 4000) }
    public var maxNoteWords: Int { limit("maxNoteWords", 20) }
    public var maxNextSteps: Int { limit("maxNextSteps", 2) }
    public var maxNextStepWords: Int { limit("maxNextStepWords", 6) }
    public var alternatives: Int { limit("alternatives", 3) }
    public var maxOutputTokens: Int { document[ai: "maxOutputTokens"].aiInt ?? 4000 }
    /// The bubbles the thread always shows after Claude's own: "Shorter", "Closer to my words", "3 more versions".
    public var steadyBubbles: [String] { document[ai: "steadyBubbles"].aiArray.compactMap(\.aiString) }
    /// "✓ That's it, keep it", the first bubble: exactly Keep.
    public var keepBubble: String { document[ai: "keepBubble"].aiString ?? "" }
    public func schemaName(_ kind: RewriteFollowupRequest.Kind) -> String {
        document[ai: kind == .reply ? "schemaName" : "versionsSchemaName"].aiString ?? ""
    }
    public func schema(_ kind: RewriteFollowupRequest.Kind) -> JSONValue { document[ai: kind == .reply ? "schema" : "versionsSchema"] }

    private func template(_ key: String) -> String { document[ai: "request"][ai: key].aiString ?? "" }

    /// The request is refused before anything is sent when it has no version or message, or more than the limits allow.
    public func validate(_ input: RewriteFollowupRequest) throws {
        guard input.ordinal >= 1, !input.versions.isEmpty, input.versions.count <= maxVersions,
              !input.messages.isEmpty, input.messages.count <= maxMessages,
              input.messages.allSatisfy({ !AIText.trim($0).isEmpty && $0.count <= maxMessageChars }),
              input.versions.allSatisfy({ $0.count <= maxTextChars }), input.recorded.count <= maxTextChars,
              !AIText.trim(input.source).isEmpty, input.source.utf8.count <= 20_000,
              input.language.range(of: #"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else {
            throw VoiceLabError.invalidInput
        }
    }

    /// The scope's transcript, sent as the cached block: the same for every message about the same proposal.
    public func cachedBlock(_ input: RewriteFollowupRequest) -> String {
        // The words go in last, so they are never read as a placeholder.
        template("sourceBlock").replacingOccurrences(of: "{scope}", with: input.scope)
            .replacingOccurrences(of: "{language}", with: input.language).replacingOccurrences(of: "{source}", with: input.source)
    }

    /// The change, its versions, the messages and the return line, each block filled on its own so text from one is
    /// never read as another's placeholder.
    public func instruction(_ input: RewriteFollowupRequest) -> String {
        func lines(_ items: [String], _ key: String) -> String {
            items.enumerated().map { offset, text in
                template(key).replacingOccurrences(of: "{index}", with: String(offset + 1)).replacingOccurrences(of: "{text}", with: AIText.trim(text))
            }.joined(separator: "\n")
        }
        let recorded = AIText.trim(input.recorded).isEmpty ? template("noRecorded") : AIText.trim(input.recorded)
        let change = template("changeBlock").replacingOccurrences(of: "{ordinal}", with: String(input.ordinal))
            .replacingOccurrences(of: "{recorded}", with: recorded)
        let versions = template("versionsBlock").replacingOccurrences(of: "{versions}", with: lines(input.versions, "versionLine"))
        let messages = template("messagesBlock").replacingOccurrences(of: "{messages}", with: lines(input.messages, "messageLine"))
        let ask = input.kind == .reply ? template("returnLine")
            : template("versionsReturnLine").replacingOccurrences(of: "{count}", with: String(alternatives))
        return [change, versions, messages, ask].joined(separator: "\n\n")
    }

    /// The request `RewriteFollowupService` sends, at Rewrite's effort (ai.md §2.1).
    public func request(_ input: RewriteFollowupRequest, timeout: Duration) throws -> LLMRequest {
        try validate(input)
        return LLMRequest(feature: .voiceRewrite, system: system, cachedBlock: cachedBlock(input), instruction: instruction(input),
                          schemaName: schemaName(input.kind), schema: schema(input.kind), maxOutputTokens: maxOutputTokens,
                          effort: .decision, timeout: timeout, language: input.language,
                          tag: input.kind == .reply ? "rewrite-followup" : "rewrite-followup-versions")
    }

    /// A reply's spoken words, checked as a Rewrite passage is (voice-lab §8.9.1): plain spoken words with no link, markup
    /// or control characters; nil when they are not.
    public func spoken(_ raw: String) -> String? {
        let text = AIText.trim(VoiceLabAudioTags.sanitizedRequest(raw, modelID: ""))
        guard !text.isEmpty, text.count <= maxTextChars,
              text.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) == nil,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return text
    }

    /// The checked reply to `input`: its spoken words (one, or up to `alternatives` new ones for "3 more versions", none
    /// repeating a version so far), the note cut to `maxNoteWords` words, and at most `maxNextSteps` next steps of at
    /// most `maxNextStepWords` words that are not a steady bubble.
    public func reply(_ object: JSONValue, for input: RewriteFollowupRequest) throws -> RewriteFollowupReply {
        let texts: [String]
        switch input.kind {
        case .reply:
            guard let raw = object[ai: "text"].aiString, let text = spoken(raw) else {
                throw LLMError.invalidOutput(reason: "The new words are not a plain spoken passage.")
            }
            texts = [text]
        case .versions:
            var seen = Set(input.versions.map(Self.key))
            var found: [String] = []
            for raw in object[ai: "alternatives"].aiArray.compactMap(\.aiString) {
                guard found.count < alternatives, let text = spoken(raw), seen.insert(Self.key(text)).inserted else { continue }
                found.append(text)
            }
            guard !found.isEmpty else { throw LLMError.invalidOutput(reason: "The reply has no new version.") }
            texts = found
        }
        let words = AIText.trim(object[ai: "note"].aiString ?? "").split(whereSeparator: \.isWhitespace)
        let note = words.count > maxNoteWords ? words.prefix(maxNoteWords).joined(separator: " ") + "\u{2026}" : words.joined(separator: " ")
        let steady = Set((steadyBubbles + [keepBubble]).map(Self.key))
        var steps: [String] = [], seenSteps = Set<String>()
        for raw in object[ai: "nextSteps"].aiArray.compactMap(\.aiString) {
            let step = AIText.trim(raw).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let count = step.split(separator: " ").count
            guard steps.count < maxNextSteps, count >= 1, count <= maxNextStepWords, !steady.contains(Self.key(step)),
                  seenSteps.insert(Self.key(step)).inserted, spoken(step) != nil else { continue }
            steps.append(step)
        }
        return RewriteFollowupReply(texts: texts, note: note, nextSteps: steps)
    }

    /// Words compared as the thread compares versions: case, spacing and the punctuation around words aside.
    public static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
