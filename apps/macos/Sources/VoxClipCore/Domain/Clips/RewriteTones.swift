import Foundation

/// A Rewrite tone (design.md §6.3.1): a catalogue preset from `shared/data/rewrite-tones.json` ("✦ Viral YouTuber",
/// "Punchy Reel", …) or a tone the user saved (settings `rewrite.myTones`, "my-…" ids). `instruction` is the exact text
/// Rewrite sends as the user instruction and the clip planner applies (ai.md §16.3).
public struct RewriteTone: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The catalogue's short line ("hook, punchy, payoff"); empty for a saved tone, whose menus read "saved".
    public var descriptor: String
    public var instruction: String
    /// Shortens the words; its instruction carries the take-fit rule (phrases near their slot's length).
    public var shortens: Bool
    /// The catalogue's one featured tone, shown with ✦.
    public var featured: Bool

    public init(id: String, title: String, descriptor: String = "", instruction: String, shortens: Bool = false, featured: Bool = false) {
        self.id = id; self.title = title; self.descriptor = descriptor; self.instruction = instruction
        self.shortens = shortens; self.featured = featured
    }

    /// A tone the user saved, rather than a catalogue preset.
    public var isSaved: Bool { id.hasPrefix(RewriteToneCatalog.myTonePrefix) }
    /// The chip and menu title: "✦ Viral YouTuber" for the featured tone.
    public var chipTitle: String { featured ? "✦ " + title : title }
    /// The menu's trailing detail: the descriptor, or "saved".
    public var detail: String { isSaved ? "saved" : descriptor }
}

/// The tone of a clip style (design.md §6.6, project schema `$defs.clipStyle.tone`): Claude picks per clip, the speaker's
/// own tone, or one tone by id (a catalogue tone or a saved "my-…" one). Stored only when it is not Auto.
public enum ClipTone: Sendable, Hashable, Codable {
    case auto
    case asSaid
    case tone(String)

    public init(raw: String) {
        switch raw {
        case "auto": self = .auto
        case "as-said": self = .asSaid
        default: self = .tone(raw)
        }
    }

    public var raw: String {
        switch self {
        case .auto: "auto"
        case .asSaid: "as-said"
        case .tone(let id): id
        }
    }

    public init(from decoder: any Decoder) throws { self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// shared/data/rewrite-tones.json: the catalogue tones in chip order, the card's Auto and As I said it labels, and the limits
/// saved tones share.
public struct RewriteToneCatalog: Sendable, Equatable {
    public struct Choice: Sendable, Equatable { public var label: String; public var detail: String }

    public static let path = "data/rewrite-tones.json"
    public static let myTonePrefix = "my-"
    /// The settings key that keeps the user's saved tones.
    public static let settingsKey = "rewrite.myTones"

    public var tones: [RewriteTone]
    public var auto: Choice
    public var asSaid: Choice
    public var maxTitleScalars: Int
    public var maxInstructionBytes: Int
    public var maxMyTones: Int

    public static func load(shared: SharedResources) throws -> RewriteToneCatalog {
        try parse(Data(contentsOf: shared.root.appendingPathComponent(path)))
    }

    public static func parse(_ data: Data) throws -> RewriteToneCatalog {
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        guard document[ai: "schema"].aiString == "voxclip-rewrite-tones/1", document[ai: "schemaVersion"].aiInt == 1,
              document[ai: "myTonePrefix"].aiString == myTonePrefix,
              let titles = document[ai: "limits"][ai: "maxTitleScalars"].aiInt, let bytes = document[ai: "limits"][ai: "maxInstructionBytes"].aiInt,
              let mine = document[ai: "limits"][ai: "maxMyTones"].aiInt else { throw VoxClipError.sharedResourcesMissing }
        func choice(_ id: String) throws -> Choice {
            guard let item = document[ai: "choices"].aiArray.first(where: { $0[ai: "id"].aiString == id }),
                  let label = item[ai: "label"].aiString, let detail = item[ai: "detail"].aiString else { throw VoxClipError.sharedResourcesMissing }
            return Choice(label: label, detail: detail)
        }
        var seen = Set<String>()
        let tones = try document[ai: "tones"].aiArray.map { item -> RewriteTone in
            guard let id = item[ai: "id"].aiString, ClipStyle.isSlug(id), !["auto", "as-said"].contains(id), !id.hasPrefix(myTonePrefix),
                  seen.insert(id).inserted, let title = item[ai: "title"].aiString, !title.isEmpty, title.unicodeScalars.count <= titles,
                  let descriptor = item[ai: "descriptor"].aiString, let instruction = item[ai: "instruction"].aiString,
                  !instruction.isEmpty, instruction.utf8.count <= bytes else { throw VoxClipError.sharedResourcesMissing }
            return RewriteTone(id: id, title: title, descriptor: descriptor, instruction: instruction,
                               shortens: item[ai: "shortens"].aiBool ?? false, featured: item[ai: "featured"].aiBool ?? false)
        }
        guard !tones.isEmpty else { throw VoxClipError.sharedResourcesMissing }
        return RewriteToneCatalog(tones: tones, auto: try choice("auto"), asSaid: try choice("as-said"), maxTitleScalars: titles,
                                  maxInstructionBytes: bytes, maxMyTones: mine)
    }

    /// The tone `id` names among the catalogue and `saved`, if either has it.
    public func tone(_ id: String, saved: [RewriteTone] = []) -> RewriteTone? {
        tones.first { $0.id == id } ?? saved.first { $0.id == id }
    }

    /// The catalogue tone or saved tone whose instruction is `text` (trimmed): the chip Rewrite's field marks.
    public func tone(matching text: String, saved: [RewriteTone] = []) -> RewriteTone? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (tones + saved).first { $0.instruction == trimmed }
    }

    /// The tone a clip style asks for, resolved: nil for Auto, As I said it, or an id neither list knows (which plans as
    /// Auto).
    public func resolve(_ tone: ClipTone, saved: [RewriteTone]) -> RewriteTone? {
        guard case .tone(let id) = tone else { return nil }
        return self.tone(id, saved: saved)
    }
}

/// The user's saved tones, settings `rewrite.myTones` (design.md §6.3.1 "+ Save as my tone"; settings schema): an array of
/// `{id, title, instruction}` in the order saved, at most `maxMyTones`. Pure: callers read and write the settings value.
public enum MyRewriteTones {
    /// The saved tones a settings value holds; anything unreadable is skipped, never an error.
    public static func decode(_ value: JSONValue?) -> [RewriteTone] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value.aiArray.compactMap { item in
            guard let id = item[ai: "id"].aiString, isID(id), seen.insert(id).inserted, let title = item[ai: "title"].aiString,
                  let instruction = item[ai: "instruction"].aiString, (try? check(title: title, instruction: instruction)) != nil else { return nil }
            return RewriteTone(id: id, title: title, instruction: instruction)
        }
    }

    /// The settings value for `tones`.
    public static func encode(_ tones: [RewriteTone]) -> JSONValue {
        .array(tones.map { .object(["id": .string($0.id), "title": .string($0.title), "instruction": .string($0.instruction)]) })
    }

    public static func isID(_ id: String) -> Bool {
        id.hasPrefix(RewriteToneCatalog.myTonePrefix) && id.utf8.count <= 64 && ClipStyle.isSlug(id)
    }

    /// A title of 1…32 scalars once trimmed, and an instruction of 1…1,000 UTF-8 bytes (settings schema).
    public static func check(title: String, instruction: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name == title, name.unicodeScalars.count <= 32, !text.isEmpty, text.utf8.count <= 1_000,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VoiceLabError.invalidInput }
    }

    /// `tones` with a new tone named `title` for `instruction`, last. Its id is "my-" and the title's slug, made unique
    /// ("my-pitch-voice", "my-pitch-voice-2"). Throws for an empty or long title or instruction, or a full list.
    public static func saving(_ title: String, instruction: String, to tones: [RewriteTone], limit: Int = 20) throws -> (tones: [RewriteTone], tone: RewriteTone) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        try check(title: name, instruction: text)
        guard tones.count < limit else { throw VoiceLabError.invalidInput }
        let slug = name.lowercased().folding(options: [.diacriticInsensitive], locale: nil).unicodeScalars
            .map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let base = RewriteToneCatalog.myTonePrefix + String((slug.isEmpty ? "tone" : slug).prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var id = base, number = 2
        while tones.contains(where: { $0.id == id }) { id = "\(base)-\(number)"; number += 1 }
        let tone = RewriteTone(id: id, title: name, instruction: text)
        return (tones + [tone], tone)
    }

    /// `tones` with `id` renamed; its id stays, so clip styles that chose it keep it.
    public static func renaming(_ id: String, to title: String, in tones: [RewriteTone]) throws -> [RewriteTone] {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = tones.firstIndex(where: { $0.id == id }) else { throw VoiceLabError.invalidInput }
        try check(title: name, instruction: tones[index].instruction)
        var next = tones
        next[index].title = name
        return next
    }

    /// `tones` without `id`. A clip style that chose it plans as Auto from then on.
    public static func deleting(_ id: String, from tones: [RewriteTone]) -> [RewriteTone] { tones.filter { $0.id != id } }
}
