import Foundation

/// Captions shown in another language over a run of words (doc/spec/ai.md §18.2, Ask Claude's `translate`): the
/// translated text replaces the transcript words in the captions only; the voice, the words and the transcript stay.
/// Project schema v4 root `captionTranslations`, omitted when empty. Every key is written, `clipId` null included.
public struct CaptionTranslation: Codable, Sendable, Hashable {
    public static let maximumEntries = 200
    public static let maximumTextScalars = 1_000
    public static let idPattern = #"\Atr-[1-9][0-9]{0,5}\z"#
    public static let languagePattern = #"\A[a-z]{2,3}(-[a-z0-9]{2,8})*\z"#

    /// "tr-1", "tr-2"…
    public var id: String
    /// The clip it was made in, which alone shows it; nil (made on the Full Take) shows it in every render of those words.
    public var clipId: String?
    /// The first and last transcript words it covers, in transcript order.
    public var startWordId: String
    public var endWordId: String
    /// A BCP 47 language tag in lower case: "es", "pt-br".
    public var language: String
    /// The translation, trimmed, at most `maximumTextScalars` scalars.
    public var text: String

    public init(id: String, clipId: String?, startWordId: String, endWordId: String, language: String, text: String) {
        self.id = id; self.clipId = clipId; self.startWordId = startWordId; self.endWordId = endWordId
        self.language = language; self.text = text
    }

    private enum CodingKeys: String, CodingKey { case id, clipId, startWordId, endWordId, language, text }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(clipId, forKey: .clipId)
        try values.encode(startWordId, forKey: .startWordId)
        try values.encode(endWordId, forKey: .endWordId)
        try values.encode(language, forKey: .language)
        try values.encode(text, forKey: .text)
    }

    /// The translation's words: its text split at white space.
    public var tokens: [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
}

public enum CaptionTranslationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidEntry(String)
}

/// Validation, editing and rendering of `Project.captionTranslations`.
public enum CaptionTranslations {
    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    /// The typed rules: v4 only, unique ids, known words in order, a known clip, a language tag, a non-empty text, no two
    /// over the same words in one scope.
    public static func validate(_ project: Project) throws {
        let entries = project.captionTranslations
        guard !entries.isEmpty else { return }
        guard project.schemaVersion == 4 else { throw CaptionTranslationError.unsupportedVersion }
        guard entries.count <= CaptionTranslation.maximumEntries else { throw CaptionTranslationError.invalidEntry("too many") }
        let order = wordOrder(project)
        let clips = Set(project.edits.clips.map(\.id))
        var ids = Set<String>()
        var covered: [String: [ClosedRange<Int>]] = [:]
        for entry in entries {
            guard matches(entry.id, CaptionTranslation.idPattern), ids.insert(entry.id).inserted else { throw CaptionTranslationError.invalidEntry("id") }
            guard let lower = order[entry.startWordId], let upper = order[entry.endWordId], lower <= upper else {
                throw CaptionTranslationError.invalidEntry("words")
            }
            if let clip = entry.clipId { guard clips.contains(clip) else { throw CaptionTranslationError.invalidEntry("clipId") } }
            guard matches(entry.language, CaptionTranslation.languagePattern) else { throw CaptionTranslationError.invalidEntry("language") }
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == entry.text, entry.text.unicodeScalars.count <= CaptionTranslation.maximumTextScalars else {
                throw CaptionTranslationError.invalidEntry("text")
            }
            let scope = entry.clipId ?? ""
            guard !(covered[scope] ?? []).contains(where: { $0.overlaps(lower...upper) }) else { throw CaptionTranslationError.invalidEntry("overlap") }
            covered[scope, default: []].append(lower...upper)
        }
    }

    /// The wire shape (project schema `$defs.captionTranslation`): a non-empty list of objects with exactly its keys.
    static func validateWire(_ value: JSONValue) throws {
        guard case .array(let entries) = value, !entries.isEmpty, entries.count <= CaptionTranslation.maximumEntries else {
            throw CaptionTranslationError.invalidEntry("not a list")
        }
        for entry in entries {
            guard case .object(let object) = entry, Set(object.keys) == ["id", "clipId", "startWordId", "endWordId", "language", "text"] else {
                throw CaptionTranslationError.invalidEntry("unknown or missing field")
            }
            for key in ["id", "startWordId", "endWordId", "language", "text"] {
                guard case .string = object[key] else { throw CaptionTranslationError.invalidEntry(key) }
            }
            if object["clipId"] != .null { guard case .string = object["clipId"] else { throw CaptionTranslationError.invalidEntry("clipId") } }
        }
    }

    static func wordOrder(_ project: Project) -> [String: Int] {
        Dictionary((project.transcript?.words ?? []).enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    /// The next free id: "tr-1", "tr-2"…
    public static func nextID(in project: Project) -> String {
        let used = Set(project.captionTranslations.map(\.id))
        var index = 1
        while used.contains("tr-\(index)") { index += 1 }
        return "tr-\(index)"
    }

    /// `project` with a translation of words `start...end` (transcript indices) in `language`: promoted to v4, replacing
    /// any translation in the same scope over any of those words.
    public static func translating(_ range: ClosedRange<Int>, clipID: String?, language: String, text: String, in project: Project) throws -> Project {
        guard let words = project.transcript?.words, range.lowerBound >= 0, range.upperBound < words.count else {
            throw CaptionTranslationError.invalidEntry("words")
        }
        var result = project.schemaVersion == 4 ? project : try ContextDemoProject.upgradeToV4(project)
        let order = wordOrder(result)
        result.captionTranslations.removeAll { entry in
            guard entry.clipId == clipID, let lower = order[entry.startWordId], let upper = order[entry.endWordId] else { return false }
            return (lower...upper).overlaps(range)
        }
        let translation = CaptionTranslation(id: nextID(in: result), clipId: clipID, startWordId: words[range.lowerBound].id,
                                             endWordId: words[range.upperBound].id, language: language.lowercased(),
                                             text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        result.captionTranslations.append(translation)
        try validate(result)
        return result
    }

    /// Takes the translation of words `range` in `clipID`'s scope back out of `project`, putting back what `base` had there.
    public static func untranslating(_ range: ClosedRange<Int>, clipID: String?, base: Project?, from project: Project) throws -> Project {
        var result = project
        let order = wordOrder(result)
        func overlaps(_ entry: CaptionTranslation) -> Bool {
            guard entry.clipId == clipID, let lower = order[entry.startWordId], let upper = order[entry.endWordId] else { return false }
            return (lower...upper).overlaps(range)
        }
        result.captionTranslations.removeAll(where: overlaps)
        for entry in base?.captionTranslations ?? [] where overlaps(entry) && !result.captionTranslations.contains(where: { $0.id == entry.id }) {
            result.captionTranslations.append(entry)
        }
        try validate(result)
        return result
    }

    /// The translations a render of `clipID` shows: that clip's own first, then the Full Take's.
    public static func rendered(in project: Project, clipID: String?) -> [CaptionTranslation] {
        let own = clipID.map { clip in project.captionTranslations.filter { $0.clipId == clip } } ?? []
        return own + project.captionTranslations.filter { $0.clipId == nil }
    }

    /// `captions` (words on the edited or rendered timeline, with their transcript ids) with each rendered translation
    /// in place of its words. The translation's words are spread over the shown words of its range, in order: with as
    /// many or more translated words, each shown word's time is shared evenly by the translated words it carries; with
    /// fewer, each translated word spans its share of the shown words. Times never leave the original words' bounds, so
    /// cuts, speed and pages work as before. A translated word over a bleeped or muted word is masked (× per letter).
    public static func applying(_ captions: [CaptionWord], project: Project, clipID: String?, effects: [ClipEffect] = []) -> [CaptionWord] {
        let translations = rendered(in: project, clipID: clipID)
        guard !translations.isEmpty, !captions.isEmpty else { return captions }
        let order = wordOrder(project)
        let bleeped = Set(effects.filter(\.kind.usesWords).flatMap { $0.wordIds ?? [] })
        var result = captions
        var consumed = Set<String>()
        for translation in translations {
            guard let lower = order[translation.startWordId], let upper = order[translation.endWordId] else { continue }
            let positions = result.indices.filter { index in order[result[index].id].map { (lower...upper).contains($0) } ?? false }
            guard !positions.isEmpty, positions.allSatisfy({ !consumed.contains(result[$0].id) }) else { continue }
            let slots = positions.map { result[$0] }
            let spread = spreading(translation.tokens, over: slots, bleeped: bleeped)
            guard !spread.isEmpty else { continue }
            consumed.formUnion(slots.map(\.id))
            for position in positions.reversed() { result.remove(at: position) }
            result.insert(contentsOf: spread, at: positions[0])
        }
        return result
    }

    /// The Voice Lab path's `plan` with its captions translated (`applying`).
    public static func applying(_ plan: VoiceLabOutputPlan, project: Project, clipID: String?, effects: [ClipEffect] = []) -> VoiceLabOutputPlan {
        let captions = applying(plan.captions, project: project, clipID: clipID, effects: effects)
        guard captions != plan.captions else { return plan }
        var copy = plan
        copy.captions = captions
        return copy
    }

    /// `tokens` over the shown words `slots` (see `applying`). Ids: a slot's first word keeps the slot's id, the others
    /// add "#n", so every id stays unique and traces back to its transcript word.
    static func spreading(_ tokens: [String], over slots: [CaptionWord], bleeped: Set<String>) -> [CaptionWord] {
        let count = tokens.count, shown = slots.count
        guard count > 0, shown > 0 else { return [] }
        var words: [CaptionWord] = []
        if count >= shown {
            for (index, slot) in slots.enumerated() {
                let first = index * count / shown, last = (index + 1) * count / shown
                let share: Double = (slot.end - slot.start) / Double(last - first)
                for token in first..<last {
                    let offset = Double(token - first)
                    let text = bleeped.contains(slot.id) ? ClipEffects.masked(tokens[token]) : tokens[token]
                    words.append(CaptionWord(id: token == first ? slot.id : "\(slot.id)#\(token - first)", text: text,
                                             start: slot.start + offset * share, end: token == last - 1 ? slot.end : slot.start + (offset + 1) * share))
                }
            }
        } else {
            for (token, text) in tokens.enumerated() {
                let first = token * shown / count, last = (token + 1) * shown / count - 1
                let covered = slots[first...last]
                let masked = covered.contains { bleeped.contains($0.id) }
                words.append(CaptionWord(id: slots[first].id, text: masked ? ClipEffects.masked(text) : text,
                                         start: slots[first].start, end: slots[last].end))
            }
        }
        return words
    }
}
