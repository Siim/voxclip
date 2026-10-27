import Foundation

/// The character range for one transcript line's new text (voice-lab §8.1), computed by the caller from the length budget.
public struct PatchRewriteLineRange: Codable, Sendable, Equatable {
    /// The line's `[a-b]` label as `formatTranscript` emits it (ai.md §11.3).
    public let line: String
    /// The new text's `VoiceLabTextLength` range, with `1 ≤ minChars ≤ maxChars ≤ 5,000`.
    public let minChars: Int
    public let maxChars: Int
    public init(line: String, minChars: Int, maxChars: Int) {
        self.line = line; self.minChars = minChars; self.maxChars = maxChars
    }
}

/// One Fix with AI request (voice-lab §8.1, path 3). `entries` are the in-scope transcript items with their absolute indices
/// and display text (ai.md §11.2), and `ranges` holds one range per formatted line, in line order.
public struct PatchRewriteRequest: Codable, Sendable {
    public let id: UUID
    public let entries: [ClipWord]
    public let ranges: [PatchRewriteLineRange]
    /// What to fix, for example "I said 2024; it's 2025". It must not be empty after `jsTrim`.
    public let instruction: String
    public let language: String
    public init(id: UUID, entries: [ClipWord], ranges: [PatchRewriteLineRange], instruction: String, language: String) {
        self.id = id; self.entries = entries; self.ranges = ranges; self.instruction = instruction; self.language = language
    }
}

/// Prepared by `PatchRewriteService` for one exact send; preparation performs no provider call.
public struct PatchRewriteQuote: Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let connector: ConnectorID
    public let model: String
    public let estimate: CostEstimate
    let fingerprint: String
}

/// An affirmative answer to one service-issued Fix with AI quote.
public struct PatchRewriteAuthorization: Sendable, Equatable {
    public let quote: PatchRewriteQuote
    public let approved: Bool
    public var requestID: UUID { quote.requestID }
    public var connector: ConnectorID { quote.connector }
    public var model: String { quote.model }
    public var estimate: CostEstimate { quote.estimate }
    public init(quote: PatchRewriteQuote, approved: Bool) {
        self.quote = quote; self.approved = approved
    }
}

/// One validated line edit. Review data is inert: it cannot invoke synthesis or change source word timing.
public struct PatchRewriteEdit: Sendable, Equatable {
    /// The emitted `[a-b]` label of the line this edit replaces.
    public let line: String
    /// The new text of the whole line, exactly as the model returned it.
    public let text: String
    public let reason: String
    /// Core's own `VoiceLabTextLength` of `text`.
    public let length: Int
    /// Whether `length` lies in the line's range. An edit outside it is kept and shown with the fit meter (§8.9.1).
    public let inRange: Bool
    /// The edit adds a digit run, a URL or a capitalised token found nowhere in the transcript or the instruction (§8.1).
    public let checkThis: Bool
    /// `text` is empty after `jsTrim`: the edit deletes the whole line, and is in range with length 0.
    public let isDeletion: Bool
}

/// Validated Fix with AI edits in arrival order, and what validation dropped.
public struct PatchRewriteProposal: Sendable {
    public let id: UUID
    public let edits: [PatchRewriteEdit]
    /// Edits whose line matched no emitted `[a-b]` label.
    public let unknownLines: Int
    /// Later edits for a line that already had one; the first is kept.
    public let duplicateLines: Int
    /// `edits` items dropped as malformed: those structural validation drops (ai.md §2.3), and those whose text or reason
    /// holds a control character other than tab or whose text is over 2,000 UTF-8 bytes (§8.1).
    public let malformedItems: Int
    /// The badge for an edit with `checkThis`, from `shared/prompts/patch-rewrite.json`.
    public let checkThisMessage: String
    public let connector: ConnectorID
    public let model: String
    public let providerRequestID: String?
}
