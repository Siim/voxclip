import Foundation

/// The clip style card's chips (doc/design.md §6.6; shared/data/clip-styles.json).
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

/// One clip's caption look (design.md §6.6): the style, the one-line reason, the overrides it renders with, and who chose
/// it. Claude's picks (Pick styles, Make it postable) and the creator's own choice for that clip share the map.
public struct ClipCaptionPick: Codable, Sendable, Hashable {
    /// Who chose the clip's caption style. Omitted on the wire for Claude, so older picks read as Claude's.
    public enum Chooser: String, Codable, Sendable, Hashable { case ai, user }

    public var styleId: String
    public var reason: String
    /// The caption overrides this clip renders with (a JSON merge patch over the style, as `captions.overrides`): Make it
    /// postable's case, words per line and font. Nil keeps the project's overrides while the styles match, else none.
    public var overrides: [String: JSONValue]?
    public var by: Chooser

    public init(styleId: String, reason: String, overrides: [String: JSONValue]? = nil, by: Chooser = .ai) {
        self.styleId = styleId; self.reason = reason; self.overrides = overrides; self.by = by
    }

    private enum CodingKeys: String, CodingKey { case styleId, reason, overrides, by }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        styleId = try values.decode(String.self, forKey: .styleId)
        reason = try values.decode(String.self, forKey: .reason)
        overrides = try values.decodeIfPresent([String: JSONValue].self, forKey: .overrides)
        // Only "user" is ever written; Claude's picks omit the key.
        let by = try values.decodeIfPresent(String.self, forKey: .by)
        guard by == nil || by == "user" else { throw VoxClipError.projectUnreadable("clipStyle.captionPicks") }
        self.by = by == "user" ? .user : .ai
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(styleId, forKey: .styleId)
        try values.encode(reason, forKey: .reason)
        if let overrides { try values.encode(overrides, forKey: .overrides) }
        if by == .user { try values.encode("user", forKey: .by) }
    }
}

/// How clips should be made (doc/design.md §6.6, project schema `$defs.clipStyle`). Stored per project once the user
/// chooses on the clip style card; Settings keeps the default a new project's card starts with. The clip autopilot
/// planner reads the same value.
public struct ClipStyle: Codable, Sendable, Hashable {
    public var preset: ClipStylePresetID
    public var captions: ClipCaptionChoice
    public var music: ClipMusicPreference
    public var maxLengthSec: Int
    public var shapes: [AspectRatio]
    public var rewording: ClipRewording
    /// Caption picks by clip id: Claude's (consulted while `captions` is `.auto`, or when they keep the fixed style) and the
    /// creator's own per-clip choices (always). `captionPick(forClip:)` says which applies.
    public var captionPicks: [String: ClipCaptionPick]
    /// The tone Claude writes each clip's words in (design.md §6.6 Tone row; shared/data/rewrite-tones.json). Auto lets
    /// Claude pick per clip; stored only when it is not Auto. Rewording Off overrides it: the words stay as said.
    public var tone: ClipTone

    public init(preset: ClipStylePresetID, captions: ClipCaptionChoice, music: ClipMusicPreference, maxLengthSec: Int,
                shapes: [AspectRatio], rewording: ClipRewording, captionPicks: [String: ClipCaptionPick] = [:], tone: ClipTone = .auto) {
        self.preset = preset; self.captions = captions; self.music = music; self.maxLengthSec = maxLengthSec
        self.shapes = shapes; self.rewording = rewording; self.captionPicks = captionPicks; self.tone = tone
    }

    /// The tone the planner gets: As I said it whenever the style never rewords, else the chosen tone.
    public var effectiveTone: ClipTone { rewording == .off ? .asSaid : tone }

    /// The caption style the user fixed, or "off"; nil while the AI picks.
    public var fixedCaptionStyle: String? {
        if case .auto = captions { return nil }
        return captions.raw
    }

    /// The caption style for `clipID`: the creator's own choice for that clip first, then the style they fixed for every
    /// clip; with Auto, Claude's pick for that clip, or nil when there is none yet (the project's style then applies).
    public func captionStyle(forClip clipID: String?) -> String? {
        if let clipID, let pick = captionPicks[clipID], pick.by == .user { return pick.styleId }
        if let fixed = fixedCaptionStyle { return fixed }
        guard let clipID else { return nil }
        return captionPicks[clipID]?.styleId
    }

    /// The pick `clipID` renders with (design.md §6.6): the creator's own always; Claude's while captions are Auto, or
    /// when it keeps the style the creator fixed (Make it postable's case and size for that style). Nil: the project's
    /// captions apply.
    public func captionPick(forClip clipID: String?) -> ClipCaptionPick? {
        guard let clipID, let pick = captionPicks[clipID] else { return nil }
        if pick.by == .user { return pick }
        guard let fixed = fixedCaptionStyle else { return pick }
        return pick.styleId == fixed ? pick : nil
    }

    /// Records AI picks. A fixed caption style is never overridden: with anything but Auto this changes nothing. The
    /// creator's own pick for a clip is never replaced.
    public func recording(_ picks: [String: ClipCaptionPick]) -> ClipStyle {
        guard case .auto = captions else { return self }
        var next = self
        for (clipID, pick) in picks where captionPicks[clipID]?.by != .user { next.captionPicks[clipID] = pick }
        return next
    }

    /// Records Make it postable's caption look for one clip: under Auto any style, under a fixed style only that style
    /// (with Claude's overrides). Nil when it cannot apply: the creator chose this clip's style, or the style is fixed to
    /// another one or Off.
    public func recordingLook(_ pick: ClipCaptionPick, forClip clipID: String) -> ClipStyle? {
        guard captionPicks[clipID]?.by != .user else { return nil }
        if let fixed = fixedCaptionStyle, fixed != pick.styleId { return nil }
        var next = self
        var recorded = pick
        recorded.by = .ai
        next.captionPicks[clipID] = recorded
        return next
    }

    /// The creator chose `styleId` for one clip (the Captions panel or the card while that clip is open): it stays that
    /// clip's style whatever the project default or Claude does later. The overrides carry over when the style is the
    /// same as the clip's current one.
    public func choosingCaptionStyle(_ styleId: String, forClip clipID: String, current: CaptionSettings) -> ClipStyle {
        var next = self
        let overrides = current.styleId == styleId ? current.overrides : nil
        next.captionPicks[clipID] = ClipCaptionPick(styleId: styleId, reason: "", overrides: overrides, by: .user)
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

    private enum CodingKeys: String, CodingKey { case preset, captions, music, maxLengthSec, shapes, rewording, captionPicks, tone }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preset = try values.decode(ClipStylePresetID.self, forKey: .preset)
        captions = try values.decode(ClipCaptionChoice.self, forKey: .captions)
        music = try values.decode(ClipMusicPreference.self, forKey: .music)
        maxLengthSec = try values.decode(Int.self, forKey: .maxLengthSec)
        shapes = try values.decode([AspectRatio].self, forKey: .shapes)
        rewording = try values.decode(ClipRewording.self, forKey: .rewording)
        captionPicks = try values.decodeIfPresent([String: ClipCaptionPick].self, forKey: .captionPicks) ?? [:]
        // Omitted is Auto; the schema never lets "auto" be written.
        let tone = try values.decodeIfPresent(String.self, forKey: .tone)
        if tone == "auto" { throw VoxClipError.projectUnreadable("clipStyle.tone") }
        self.tone = tone.map(ClipTone.init(raw:)) ?? .auto
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
        if tone != .auto { try values.encode(tone, forKey: .tone) }
    }

    /// The schema rules a decoder cannot express (project schema `$defs.clipStyle`).
    public func validate() throws {
        func fail(_ reason: String) -> VoxClipError { .projectUnreadable("clipStyle." + reason) }
        guard Self.isSlug(captions.raw) else { throw fail("captions") }
        guard (5...600).contains(maxLengthSec) else { throw fail("maxLengthSec") }
        guard !shapes.isEmpty, Set(shapes).count == shapes.count, !shapes.contains(.source) else { throw fail("shapes") }
        if tone != .auto { guard Self.isSlug(tone.raw), tone.raw.utf8.count <= 64 else { throw fail("tone") } }
        for (_, pick) in captionPicks {
            guard Self.isSlug(pick.styleId), pick.styleId != "auto", pick.reason.unicodeScalars.count <= 120 else { throw fail("captionPicks") }
        }
    }

    /// A style id: lowercase letters and digits in hyphen-separated runs (`^[a-z0-9]+(?:-[a-z0-9]+)*$`).
    static func isSlug(_ text: String) -> Bool {
        let runs = text.split(separator: "-", omittingEmptySubsequences: false)
        return !runs.isEmpty && runs.allSatisfy { run in !run.isEmpty && run.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) } }
    }
}

extension Project {
    /// The captions a render of `clipID` uses (design.md §6.6): the clip's caption pick when one applies
    /// (`ClipStyle.captionPick(forClip:)`), else the project's captions. The position stays the project's. Preview,
    /// export, Export all, the SRT and the export fingerprint all read this, so a clip renders in its own style.
    public func captionSettings(forClip clipID: String?) -> CaptionSettings {
        guard let pick = clipStyle?.captionPick(forClip: clipID) else { return captions }
        var settings = captions
        settings.styleId = pick.styleId
        settings.overrides = pick.overrides ?? (pick.styleId == captions.styleId ? captions.overrides : [:])
        return settings
    }

    /// This project with its captions resolved for `clipID`, for a render of that clip.
    public func resolvingCaptions(forClip clipID: String?) -> Project {
        var next = self
        next.captions = captionSettings(forClip: clipID)
        return next
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
}
