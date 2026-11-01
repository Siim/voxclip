import Foundation

/// A suggestion for Rewrite's Ask field (design.md §6.3.1): choosing one fills the field and does not send.
struct RewriteSuggestion: Identifiable, Equatable, Sendable {
    /// What the field shows: "Fix mistakes", or a recent instruction.
    let title: String
    /// What a send with it asks the AI.
    let instruction: String
    /// R1's quote of a preset, after its title in semibold: "fix slips and repeats, keep my words, …". Nil for a recent
    /// instruction, which R1 quotes as typed.
    let asked: String?
    var id: String { asked == nil ? "recent:" + title : title }
    /// Its row in the suggestions: the title, or "Recent: “{text}”".
    var menuTitle: String { asked == nil ? "Recent: “\(title)”" : title }
}

/// The Ask field's suggestions and what each field text sends (design.md §6.3.1). The empty field asks Fix mistakes.
enum RewriteSuggestions {
    static let fixMistakes = RewriteSuggestion(title: "Fix mistakes",
        instruction: "Fix slips and repeats. Keep my words and my voice; change as little as possible.",
        asked: "fix slips and repeats, keep my words, change as little as possible.")
    static let presets: [RewriteSuggestion] = [
        fixMistakes,
        RewriteSuggestion(title: "Make it clearer",
            instruction: "Make it clearer. Keep my words where they work; change as little as possible.",
            asked: "keep my words where they work, change as little as possible."),
        RewriteSuggestion(title: "Make it shorter",
            instruction: "Make it shorter, mostly by cutting. Keep my words and my voice.",
            asked: "mostly by cutting, keep my words and my voice."),
        RewriteSuggestion(title: "Fix grammar and punctuation only",
            instruction: "Fix grammar, punctuation and capitals only. Don't add or change words unless a word is wrong.",
            asked: "grammar, punctuation and capitals only, no new words unless a word is wrong."),
    ]
    /// How many recent instructions a project keeps.
    static let recentLimit = 3

    /// The presets, then `recent` (most recent first) as "Recent: …" rows.
    static func list(recent: [String]) -> [RewriteSuggestion] {
        presets + recent.prefix(recentLimit).map { RewriteSuggestion(title: $0, instruction: $0, asked: nil) }
    }
    /// What the field's `text` sends: Fix mistakes for an empty field, a preset for its title, else the text as typed.
    static func suggestion(for text: String) -> RewriteSuggestion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fixMistakes }
        return presets.first { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
            ?? RewriteSuggestion(title: trimmed, instruction: trimmed, asked: nil)
    }
    /// `recent` with `text` asked now: most recent first, distinct, at most three. Presets and the empty field are not
    /// recorded; they are always offered.
    static func noting(_ text: String, in recent: [String]) -> [String] {
        let asked = suggestion(for: text)
        guard asked.asked == nil else { return recent }
        return Array(([asked.title] + recent.filter { $0 != asked.title }).prefix(recentLimit))
    }
}

extension AppModel {
    /// The Ask field's suggestions for `projectID`: the presets, then its last three distinct instructions. App-local and
    /// in memory: never written to the project file or the settings.
    func rewriteSuggestions(for projectID: String) -> [RewriteSuggestion] {
        RewriteSuggestions.list(recent: rewriteRecents[projectID] ?? [])
    }
    /// Records an instruction a Rewrite of `projectID` sent.
    func noteRewriteInstruction(_ text: String, for projectID: String) {
        let next = RewriteSuggestions.noting(text, in: rewriteRecents[projectID] ?? [])
        if next != rewriteRecents[projectID] ?? [] { rewriteRecents[projectID] = next }
    }
}
