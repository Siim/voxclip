import Foundation

/// The clip style card's chips (doc/design.md §6.9; shared/data/clip-styles.json).
public enum ClipStylePresetID: String, Codable, Sendable, Hashable, CaseIterable {
    case auto, punchy, calm, demo, mine
}

/// Background music preference. `auto` lets the AI choose: the free library first, a generated track when nothing
/// fits, then the user's folder.
public enum ClipMusicPreference: String, Codable, Sendable, Hashable, CaseIterable {
    case auto, off
}

/// How freely Rewrite may change the speaker's words.
public enum ClipRewording: String, Codable, Sendable, Hashable, CaseIterable {
    case off
    case fixOnly = "fix-only"
    case tighten
}

/// The caption field of a clip style: the AI picks per clip, captions are off, or one style the user fixed.
public enum ClipCaptionChoice: Sendable, Hashable, Codable {
    case auto
    case off
    case style(String)

    public init(raw: String) {
        switch raw {
        case "auto": self = .auto
        case "off": self = .off
        default: self = .style(raw)
        }
    }

    public var raw: String {
        switch self {
        case .auto: "auto"
        case .off: "off"
        case .style(let id): id
        }
    }

    public init(from decoder: any Decoder) throws { self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// The AI's caption style for one clip and its one-line reason.
public struct ClipCaptionPick: Codable, Sendable, Hashable {
    public var styleId: String
    public var reason: String
    public init(styleId: String, reason: String) { self.styleId = styleId; self.reason = reason }
}

/// How clips should be made (doc/design.md §6.9, project schema `$defs.clipStyle`). Stored per project once the user
/// chooses on the clip style card; Settings keeps the default a new project's card starts with. The clip autopilot
/// planner reads the same value.
public struct ClipStyle: Codable, Sendable, Hashable {
    public var preset: ClipStylePresetID
    public var captions: ClipCaptionChoice
    public var music: ClipMusicPreference
    public var maxLengthSec: Int
    public var shapes: [AspectRatio]
    public var rewording: ClipRewording
    /// The AI's picks by clip id. Only consulted while `captions` is `.auto`.
    public var captionPicks: [String: ClipCaptionPick]

    public init(preset: ClipStylePresetID, captions: ClipCaptionChoice, music: ClipMusicPreference, maxLengthSec: Int,
                shapes: [AspectRatio], rewording: ClipRewording, captionPicks: [String: ClipCaptionPick] = [:]) {
        self.preset = preset; self.captions = captions; self.music = music; self.maxLengthSec = maxLengthSec
        self.shapes = shapes; self.rewording = rewording; self.captionPicks = captionPicks
    }

    /// The caption style the user fixed, or "off"; nil while the AI picks.
    public var fixedCaptionStyle: String? {
        if case .auto = captions { return nil }
        return captions.raw
    }

    /// The caption style for `clipID`: the user's fixed style always wins; with Auto, the AI's pick for that clip, or
    /// nil when there is none yet (the project's current style then stays).
    public func captionStyle(forClip clipID: String?) -> String? {
        if let fixed = fixedCaptionStyle { return fixed }
        guard let clipID else { return nil }
        return captionPicks[clipID]?.styleId
    }

    /// Records AI picks. A fixed caption style is never overridden: with anything but Auto this changes nothing.
    public func recording(_ picks: [String: ClipCaptionPick]) -> ClipStyle {
        guard case .auto = captions else { return self }
        var next = self
        next.captionPicks.merge(picks) { _, new in new }
        return next
    }

    /// The user chose `id` as the caption style (a gallery tile or the card's Captions row): it becomes the fixed
    /// choice, so no later AI pick replaces it.
    public func fixingCaptions(_ choice: ClipCaptionChoice) -> ClipStyle {
        var next = self
        next.captions = choice
        if case .auto = choice {} else { next.preset = next.preset == .auto ? .mine : next.preset }
        return next
    }

    /// Drops picks for clips that no longer exist.
    public func pruned(clipIDs: Set<String>) -> ClipStyle {
        var next = self
        next.captionPicks = captionPicks.filter { clipIDs.contains($0.key) }
        return next
    }

    /// The status bar item: "Style: Auto · ≤60 s · 16:9+9:16".
    public func summary(presetLabel: String) -> String {
        "Style: \(presetLabel) · ≤\(maxLengthSec) s · " + shapes.map(\.rawValue).joined(separator: "+")
    }

    /// The Settings default: this style without its picks.
    public var settingsDefault: ClipStyle {
        var next = self
        next.captionPicks = [:]
        return next
    }

    private enum CodingKeys: String, CodingKey { case preset, captions, music, maxLengthSec, shapes, rewording, captionPicks }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preset = try values.decode(ClipStylePresetID.self, forKey: .preset)
        captions = try values.decode(ClipCaptionChoice.self, forKey: .captions)
        music = try values.decode(ClipMusicPreference.self, forKey: .music)
        maxLengthSec = try values.decode(Int.self, forKey: .maxLengthSec)
        shapes = try values.decode([AspectRatio].self, forKey: .shapes)
        rewording = try values.decode(ClipRewording.self, forKey: .rewording)
        captionPicks = try values.decodeIfPresent([String: ClipCaptionPick].self, forKey: .captionPicks) ?? [:]
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preset, forKey: .preset)
        try values.encode(captions, forKey: .captions)
        try values.encode(music, forKey: .music)
        try values.encode(maxLengthSec, forKey: .maxLengthSec)
        try values.encode(shapes, forKey: .shapes)
        try values.encode(rewording, forKey: .rewording)
        try values.encode(captionPicks, forKey: .captionPicks)
    }

    /// The schema rules a decoder cannot express (project schema `$defs.clipStyle`).
    public func validate() throws {
        func fail(_ reason: String) -> VoxClipError { .projectUnreadable("clipStyle." + reason) }
        guard Self.isSlug(captions.raw) else { throw fail("captions") }
        guard (5...600).contains(maxLengthSec) else { throw fail("maxLengthSec") }
        guard !shapes.isEmpty, Set(shapes).count == shapes.count, !shapes.contains(.source) else { throw fail("shapes") }
        for (_, pick) in captionPicks {
            guard Self.isSlug(pick.styleId), pick.styleId != "auto", pick.reason.count <= 120 else { throw fail("captionPicks") }
        }
    }

    /// A style id: lowercase letters and digits in hyphen-separated runs (`^[a-z0-9]+(?:-[a-z0-9]+)*$`).
    static func isSlug(_ text: String) -> Bool {
        let runs = text.split(separator: "-", omittingEmptySubsequences: false)
        return !runs.isEmpty && runs.allSatisfy { run in !run.isEmpty && run.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) } }
    }
}

/// shared/data/clip-styles.json: the presets and the labels the card and status bar show.
public struct ClipStyleCatalog: Sendable, Equatable {
    public struct Preset: Sendable, Equatable, Identifiable {
        public var id: ClipStylePresetID
        public var label: String
        public var detail: String?
        public var style: ClipStyle
        /// Caption style tags the AI may not pick under this preset (Calm story and Demo never get emoji).
        public var excludeCaptionTags: [String]
    }
    public struct Option: Sendable, Equatable { public var id: String; public var label: String; public var detail: String? }

    public var presets: [Preset]
    public var defaultPreset: ClipStylePresetID
    public var lengthChoicesSec: [Int]
    public var shapes: [AspectRatio]
    public var rewording: [Option]
    public var music: [Option]

    public static func load(shared: SharedResources) throws -> ClipStyleCatalog {
        try parse(Data(contentsOf: shared.root.appendingPathComponent("data/clip-styles.json")))
    }

    public static func parse(_ data: Data) throws -> ClipStyleCatalog {
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        guard document[ai: "schemaVersion"].aiInt == 1 else { throw VoxClipError.sharedResourcesMissing }
        func options(_ key: String) -> [Option] {
            document[ai: key].aiArray.compactMap { item in
                item[ai: "id"].aiString.map { Option(id: $0, label: item[ai: "label"].aiString ?? $0, detail: item[ai: "detail"].aiString) }
            }
        }
        let presets = try document[ai: "presets"].aiArray.map { item -> Preset in
            guard let raw = item[ai: "id"].aiString, let id = ClipStylePresetID(rawValue: raw),
                  let captions = item[ai: "captions"].aiString, let music = item[ai: "music"].aiString.flatMap(ClipMusicPreference.init(rawValue:)),
                  let length = item[ai: "maxLengthSec"].aiInt, let rewording = item[ai: "rewording"].aiString.flatMap(ClipRewording.init(rawValue:)) else {
                throw VoxClipError.sharedResourcesMissing
            }
            let shapes = item[ai: "shapes"].aiArray.compactMap { $0.aiString.flatMap(AspectRatio.init(rawValue:)) }
            let style = ClipStyle(preset: id, captions: .init(raw: captions), music: music, maxLengthSec: length, shapes: shapes, rewording: rewording)
            try style.validate()
            return Preset(id: id, label: item[ai: "label"].aiString ?? raw, detail: item[ai: "detail"].aiString, style: style,
                          excludeCaptionTags: item[ai: "excludeCaptionTags"].aiArray.compactMap(\.aiString))
        }
        guard Set(presets.map(\.id)) == Set(ClipStylePresetID.allCases),
              let preset = document[ai: "defaultPreset"].aiString.flatMap(ClipStylePresetID.init(rawValue:)) else { throw VoxClipError.sharedResourcesMissing }
        return ClipStyleCatalog(presets: presets, defaultPreset: preset,
                                lengthChoicesSec: document[ai: "lengthChoicesSec"].aiArray.compactMap(\.aiInt),
                                shapes: document[ai: "shapes"].aiArray.compactMap { $0.aiString.flatMap(AspectRatio.init(rawValue:)) },
                                rewording: options("rewording"), music: options("music"))
    }

    public func preset(_ id: ClipStylePresetID) -> Preset { presets.first { $0.id == id } ?? presets[0] }

    /// The style a chip applies. "My style" applies the user's saved default when there is one.
    public func style(for id: ClipStylePresetID, mine: ClipStyle?) -> ClipStyle {
        if id == .mine, var saved = mine { saved.preset = .mine; saved.captionPicks = [:]; return saved }
        return preset(id).style
    }

    /// The style a new project's card starts with: the Settings default, or the catalogue's default preset.
    public func initial(saved: ClipStyle?) -> ClipStyle { saved?.settingsDefault ?? preset(defaultPreset).style }

    /// The caption styles the AI may pick from under `style`: every library style except those whose tags the preset
    /// excludes, in gallery order.
    public func captionCandidates(_ library: [CaptionStyle], for style: ClipStyle) -> [CaptionStyle] {
        let excluded = Set(preset(style.preset).excludeCaptionTags)
        return library.filter { Set($0.tags).isDisjoint(with: excluded) }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// The card's rows, in order (design.md §6.9): Captions, Music, Length, Shape, Rewording.
    public func rows(_ style: ClipStyle, styleName: (String) -> String?) -> [(label: String, value: String)] {
        let captions: String
        switch style.captions {
        case .auto: captions = "Auto · Claude picks per clip"
        case .off: captions = "Off"
        case .style(let id): captions = styleName(id) ?? id
        }
        let musicOption = music.first { $0.id == style.music.rawValue }
        let musicText = [musicOption?.label, musicOption?.detail].compactMap { $0 }.joined(separator: " · ")
        let wording = rewording.first { $0.id == style.rewording.rawValue }?.label ?? style.rewording.rawValue
        return [("Captions", captions), ("Music", musicText.isEmpty ? style.music.rawValue : musicText),
                ("Length", "Up to \(style.maxLengthSec) s"), ("Shape", style.shapes.map(\.rawValue).joined(separator: " and ")),
                ("Rewording", wording)]
    }
}
