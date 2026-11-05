import Foundation

/// One visual or audio effect on a stretch of the recording (doc/spec/ai.md §18, design.md §6.8): censoring, overlays, a
/// freeze frame or a sound effect. Times are source seconds, so cuts and clip changes never move an effect off its words.
/// Project root `clipEffects`, schema v4 only, omitted when empty: a project without effects saves byte-identically.
///
/// Geometry has two spaces:
/// - **Picture space** (`blur`, `pixelate`, `arrow`, `circle`): a normalized rect of the recorded frame as it plays (rotation
///   applied), top-left origin, so a crop to another shape or a zoom keeps the effect on the same thing.
/// - **Frame space** (`title`, `lowerThird`, `sticker`, `progress`): a `position` in the exported frame.
public struct ClipEffect: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A 1 kHz tone over the words; the voice is silent there.
        case bleep
        /// Silence over the words.
        case mute
        case blur, pixelate
        case title, lowerThird
        /// An emoji, drawn with the system emoji font.
        case sticker
        case arrow, circle
        /// A bar that fills over the effect's range.
        case progress
        /// The picture holds the frame at `start` until `end`; the voice plays on.
        case freeze
        /// A short sound at `start`.
        case sound

        public var isCensor: Bool { [.bleep, .mute, .blur, .pixelate].contains(self) }
        public var usesWords: Bool { self == .bleep || self == .mute }
        public var usesRect: Bool { [.blur, .pixelate, .arrow, .circle].contains(self) }
        public var usesText: Bool { [.title, .lowerThird, .sticker].contains(self) }
        public var usesPosition: Bool { [.title, .lowerThird, .sticker, .progress].contains(self) }
        public var isTracked: Bool { self == .blur || self == .pixelate }
    }

    /// A normalized rect, top-left origin, every edge inside 0…1.
    public struct Rect: Codable, Sendable, Equatable, Hashable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
        public var isValid: Bool {
            [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= ClipEffect.minimumRectSide
                && height >= ClipEffect.minimumRectSide && x + width <= 1 + 1e-9 && y + height <= 1 + 1e-9
        }
        /// The rect moved and shrunk to lie inside the frame, keeping at least the minimum side.
        public var clamped: Rect {
            let side = ClipEffect.minimumRectSide
            let w = min(1, max(side, width.isFinite ? width : side)), h = min(1, max(side, height.isFinite ? height : side))
            let cx = min(1 - w, max(0, x.isFinite ? x : 0)), cy = min(1 - h, max(0, y.isFinite ? y : 0))
            return Rect(x: cx, y: cy, width: w, height: h)
        }
        public static func lerp(_ a: Rect, _ b: Rect, _ t: Double) -> Rect {
            Rect(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
        }
    }

    /// Where a tracked blur follows: nothing (the rect holds), the nearest face, or the most salient region.
    public enum Tracking: String, Codable, Sendable, CaseIterable { case none, face, saliency }

    /// One tracked rect at source time `t`, sampled every `ClipEffect.trackInterval` and smoothed.
    public struct TrackSample: Codable, Sendable, Equatable {
        public var t: Double
        public var rect: Rect
        public init(t: Double, rect: Rect) { self.t = t; self.rect = rect }
        private enum CodingKeys: String, CodingKey { case t, x, y, width, height }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            t = try values.decode(Double.self, forKey: .t)
            rect = Rect(x: try values.decode(Double.self, forKey: .x), y: try values.decode(Double.self, forKey: .y),
                        width: try values.decode(Double.self, forKey: .width), height: try values.decode(Double.self, forKey: .height))
        }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(t, forKey: .t); try values.encode(rect.x, forKey: .x); try values.encode(rect.y, forKey: .y)
            try values.encode(rect.width, forKey: .width); try values.encode(rect.height, forKey: .height)
        }
    }

    public enum Position: String, Codable, Sendable, CaseIterable { case top, center, bottom, topLeft, topRight, bottomLeft, bottomRight }

    /// A sound effect: one of the bundled synthesized sounds (CC0, `shared/sfx/`), or a free library clip stored under
    /// `<data folder>/SFX/<projectId>/` with its licence (cc0, by or pdm only, as library music).
    public struct Sound: Codable, Sendable, Equatable {
        public enum Source: String, Codable, Sendable { case bundled, library }
        public var source: Source
        /// The bundled sound's id (`whoosh`, `pop`, `ding`); nil for a library clip.
        public var id: String?
        /// `<projectId>/sfx-<slug>.<ext>` under the SFX root; nil for a bundled sound.
        public var file: String?
        public var sha256: String?
        public var durationSeconds: Double
        public var title: String
        public var creator: String?
        public var license: String
        public var attribution: String?
        public var sourceUrl: String?

        public init(source: Source, id: String? = nil, file: String? = nil, sha256: String? = nil, durationSeconds: Double, title: String,
                    creator: String? = nil, license: String, attribution: String? = nil, sourceUrl: String? = nil) {
            self.source = source; self.id = id; self.file = file; self.sha256 = sha256; self.durationSeconds = durationSeconds
            self.title = title; self.creator = creator; self.license = license; self.attribution = attribution; self.sourceUrl = sourceUrl
        }

        static let bundledKeys: Set<String> = ["source", "id", "durationSeconds", "title", "license"]
        static let libraryKeys: Set<String> = ["source", "file", "sha256", "durationSeconds", "title", "creator", "license", "attribution", "sourceUrl"]
        private enum CodingKeys: String, CodingKey { case source, id, file, sha256, durationSeconds, title, creator, license, attribution, sourceUrl }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            source = try values.decode(Source.self, forKey: .source)
            durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
            title = try values.decode(String.self, forKey: .title)
            license = try values.decode(String.self, forKey: .license)
            switch source {
            case .bundled: id = try values.decode(String.self, forKey: .id)
            case .library:
                file = try values.decode(String.self, forKey: .file); sha256 = try values.decode(String.self, forKey: .sha256)
                creator = try values.decode(String?.self, forKey: .creator); attribution = try values.decode(String?.self, forKey: .attribution)
                sourceUrl = try values.decode(String?.self, forKey: .sourceUrl)
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(source, forKey: .source)
            switch source {
            case .bundled: try values.encode(id, forKey: .id)
            case .library:
                try values.encode(file, forKey: .file); try values.encode(sha256, forKey: .sha256); try values.encode(creator, forKey: .creator)
                try values.encode(attribution, forKey: .attribution); try values.encode(sourceUrl, forKey: .sourceUrl)
            }
            try values.encode(durationSeconds, forKey: .durationSeconds); try values.encode(title, forKey: .title)
            try values.encode(license, forKey: .license)
        }
    }

    public var id: String
    /// The clip this effect belongs to, or nil for the full video. Censor kinds render wherever their range plays (every clip
    /// and the full video); the others only in their own clip (or the full video for nil).
    public var clipId: String?
    public var kind: Kind
    public var start: Double
    public var end: Double
    /// `bleep`, `mute`: the covered words, in order.
    public var wordIds: [String]?
    /// Picture-space kinds.
    public var rect: Rect?
    /// `blur`, `pixelate`.
    public var tracking: Tracking?
    /// `blur`, `pixelate`: smoothed samples; empty while untracked (`tracking` none, or not tracked yet), so `rect` holds.
    public var track: [TrackSample]?
    /// `title`, `lowerThird`: the words shown; `sticker`: the emoji.
    public var text: String?
    public var position: Position?
    /// `sticker`: size relative to the default (0.5–3).
    public var scale: Double?
    public var sound: Sound?
    /// `sound`: level relative to the voice, in dB.
    public var gainDb: Double?

    public init(id: String, clipId: String?, kind: Kind, start: Double, end: Double, wordIds: [String]? = nil, rect: Rect? = nil,
                tracking: Tracking? = nil, track: [TrackSample]? = nil, text: String? = nil, position: Position? = nil, scale: Double? = nil,
                sound: Sound? = nil, gainDb: Double? = nil) {
        self.id = id; self.clipId = clipId; self.kind = kind; self.start = start; self.end = end; self.wordIds = wordIds; self.rect = rect
        self.tracking = tracking; self.track = track; self.text = text; self.position = position; self.scale = scale; self.sound = sound
        self.gainDb = gainDb
    }

    // MARK: Limits

    public static let maximumEntries = 500
    public static let maximumSeconds = 600.0
    public static let maximumFreezeSeconds = 5.0
    public static let maximumSoundSeconds = 10.0
    public static let maximumWords = 200
    public static let maximumTitleScalars = 80
    public static let maximumStickerScalars = 16
    public static let maximumTrackSamples = 2_401
    public static let minimumRectSide = 0.01
    public static let scaleRange = 0.5...3.0
    public static let gainRange = -30.0...6.0
    /// Tracked rects are sampled this often (source seconds) and smoothed.
    public static let trackInterval = 0.25
    /// Overlays fade in and out over this many seconds, inside their range.
    public static let overlayFadeSeconds = 0.12
    /// A bleep's tone or silence ramps over this many seconds outside the word bounds, so the words are fully covered.
    public static let bleepRampSeconds = 0.010
    public static let bleepToneHz = 1_000.0
    /// The bleep tone's peak, −12 dBFS.
    public static let bleepToneAmplitude = 0.25
    public static let bundledSoundIDs = ["whoosh", "pop", "ding"]

    /// The keys a kind writes on the wire besides `id clipId kind start end`.
    public static func kindKeys(_ kind: Kind) -> Set<String> {
        switch kind {
        case .bleep, .mute: ["wordIds"]
        case .blur, .pixelate: ["rect", "tracking", "track"]
        case .title, .lowerThird: ["text", "position"]
        case .sticker: ["text", "position", "scale"]
        case .arrow, .circle: ["rect"]
        case .progress: ["position"]
        case .freeze: []
        case .sound: ["sound", "gainDb"]
        }
    }
    static let commonKeys: Set<String> = ["id", "clipId", "kind", "start", "end"]

    private enum CodingKeys: String, CodingKey { case id, clipId, kind, start, end, wordIds, rect, tracking, track, text, position, scale, sound, gainDb }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        clipId = try values.decode(String?.self, forKey: .clipId)
        kind = try values.decode(Kind.self, forKey: .kind)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        let keys = Self.kindKeys(kind)
        func has(_ key: CodingKeys) -> Bool { keys.contains(key.rawValue) }
        if has(.wordIds) { wordIds = try values.decode([String].self, forKey: .wordIds) }
        if has(.rect) { rect = try values.decode(Rect.self, forKey: .rect) }
        if has(.tracking) { tracking = try values.decode(Tracking.self, forKey: .tracking) }
        if has(.track) { track = try values.decode([TrackSample].self, forKey: .track) }
        if has(.text) { text = try values.decode(String.self, forKey: .text) }
        if has(.position) { position = try values.decode(Position.self, forKey: .position) }
        if has(.scale) { scale = try values.decode(Double.self, forKey: .scale) }
        if has(.sound) { sound = try values.decode(Sound.self, forKey: .sound) }
        if has(.gainDb) { gainDb = try values.decode(Double.self, forKey: .gainDb) }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(clipId, forKey: .clipId); try values.encode(kind, forKey: .kind)
        try values.encode(start, forKey: .start); try values.encode(end, forKey: .end)
        let keys = Self.kindKeys(kind)
        func has(_ key: CodingKeys) -> Bool { keys.contains(key.rawValue) }
        if has(.wordIds) { try values.encode(wordIds ?? [], forKey: .wordIds) }
        if has(.rect) { try values.encode(rect, forKey: .rect) }
        if has(.tracking) { try values.encode(tracking ?? ClipEffect.Tracking.none, forKey: .tracking) }
        if has(.track) { try values.encode(track ?? [], forKey: .track) }
        if has(.text) { try values.encode(text, forKey: .text) }
        if has(.position) { try values.encode(position, forKey: .position) }
        if has(.scale) { try values.encode(scale, forKey: .scale) }
        if has(.sound) { try values.encode(sound, forKey: .sound) }
        if has(.gainDb) { try values.encode(gainDb, forKey: .gainDb) }
    }

    // MARK: Render helpers

    /// The rect at source time `time`: the static rect, or the track interpolated between its two nearest samples (held
    /// before the first and after the last).
    public func rect(at time: Double) -> Rect? {
        guard let rect else { return nil }
        guard let track, !track.isEmpty else { return rect }
        if time <= track[0].t { return track[0].rect }
        if time >= track[track.count - 1].t { return track[track.count - 1].rect }
        var lower = 0, upper = track.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if track[middle].t <= time { lower = middle } else { upper = middle }
        }
        let a = track[lower], b = track[upper]
        let span = b.t - a.t
        return span > 0 ? Rect.lerp(a.rect, b.rect, (time - a.t) / span) : a.rect
    }

    /// An overlay's opacity at source time `time`: 0 outside its range, ramping over `overlayFadeSeconds` at each end.
    public func opacity(at time: Double) -> Double {
        guard time >= start, time < end else { return 0 }
        let fade = min(Self.overlayFadeSeconds, (end - start) / 2)
        guard fade > 0 else { return 1 }
        return min(1, (time - start) / fade, (end - time) / fade)
    }
}

public enum ClipEffectError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion
    case invalidEntry(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Effects need the current project format."
        case .invalidEntry(let reason): "The project's effects are invalid: \(reason)."
        }
    }
}

/// Project-level rules for `clipEffects` (doc/spec/ai.md §18.2).
public enum ClipEffects {
    static let identifier = #"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z"#
    static let soundFile = #"\A[0-9a-f-]{36}/sfx-[a-z0-9][a-z0-9_-]{0,57}\.(mp3|m4a|wav|aif|aiff|flac|ogg)\z"#
    static let hash = #"\A[0-9a-f]{64}\z"#
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    public static func validate(_ project: Project) throws {
        let effects = project.clipEffects
        guard !effects.isEmpty else { return }
        guard project.schemaVersion == 4 else { throw ClipEffectError.unsupportedVersion }
        guard effects.count <= ClipEffect.maximumEntries else { throw ClipEffectError.invalidEntry("too many effects") }
        guard Set(effects.map(\.id)).count == effects.count else { throw ClipEffectError.invalidEntry("duplicate id") }
        let clips = Set(project.edits.clips.map(\.id))
        let words = Set(project.transcript?.words.map(\.id) ?? [])
        for effect in effects {
            try validate(effect, projectId: project.id)
            if let clip = effect.clipId, !clips.contains(clip) { throw ClipEffectError.invalidEntry("clip") }
            if let ids = effect.wordIds, !ids.allSatisfy(words.contains) { throw ClipEffectError.invalidEntry("word") }
        }
    }

    /// One effect's own rules, independent of the project's clips and words.
    public static func validate(_ effect: ClipEffect, projectId: String) throws {
        func require(_ condition: Bool, _ reason: String) throws { if !condition { throw ClipEffectError.invalidEntry(reason) } }
        try require(matches(effect.id, identifier), "id")
        try require(effect.clipId.map { matches($0, identifier) } ?? true, "clip id")
        try require(effect.start.isFinite && effect.end.isFinite && effect.start >= 0 && effect.end > effect.start
                    && effect.end - effect.start <= ClipEffect.maximumSeconds + 1e-9, "range")
        let kind = effect.kind
        if kind.usesWords {
            let ids = effect.wordIds ?? []
            try require(!ids.isEmpty && ids.count <= ClipEffect.maximumWords && Set(ids).count == ids.count && ids.allSatisfy { matches($0, identifier) }, "words")
        }
        if kind.usesRect { try require(effect.rect?.isValid == true, "rect") }
        if kind.isTracked {
            let track = effect.track ?? []
            try require(track.count <= ClipEffect.maximumTrackSamples, "track length")
            try require(effect.tracking != ClipEffect.Tracking.none || track.isEmpty, "untracked samples")
            var previous = -Double.infinity
            for sample in track {
                try require(sample.t.isFinite && sample.t > previous && sample.rect.isValid, "track sample")
                previous = sample.t
            }
        }
        if kind.usesText {
            let text = effect.text ?? ""
            let limit = kind == .sticker ? ClipEffect.maximumStickerScalars : ClipEffect.maximumTitleScalars
            try require(!text.isEmpty && text.unicodeScalars.count <= limit && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
                        && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }, "text")
        }
        if kind.usesPosition { try require(effect.position != nil, "position") }
        if kind == .progress { try require(effect.position == .top || effect.position == .bottom, "progress position") }
        if kind == .sticker { try require(effect.scale.map { $0.isFinite && ClipEffect.scaleRange.contains($0) } == true, "scale") }
        if kind == .freeze { try require(effect.end - effect.start <= ClipEffect.maximumFreezeSeconds + 1e-9, "freeze length") }
        if kind == .sound {
            guard let sound = effect.sound else { throw ClipEffectError.invalidEntry("sound") }
            try require(effect.gainDb.map { $0.isFinite && ClipEffect.gainRange.contains($0) } == true, "gain")
            try require(sound.durationSeconds.isFinite && sound.durationSeconds > 0 && sound.durationSeconds <= ClipEffect.maximumSoundSeconds, "sound length")
            try require(abs((effect.end - effect.start) - sound.durationSeconds) < 1e-6, "sound range")
            try require(!sound.title.isEmpty && sound.title.count <= 200, "sound title")
            switch sound.source {
            case .bundled:
                try require(sound.id.map(ClipEffect.bundledSoundIDs.contains) == true && sound.license == "cc0", "bundled sound")
            case .library:
                try require(sound.file.map { matches($0, soundFile) && $0.hasPrefix(projectId + "/") } == true, "sound file")
                try require(sound.sha256.map { matches($0, hash) } == true, "sound hash")
                try require(["cc0", "by", "pdm"].contains(sound.license), "sound license")
                try require(sound.license != "by" || (sound.attribution.map { !$0.isEmpty && $0.count <= 1_000 } == true), "attribution")
                try require(sound.creator.map { !$0.isEmpty && $0.count <= 200 } ?? true, "creator")
                try require(sound.sourceUrl.map { $0.count <= 2_048 && matches($0, #"\Ahttps://[^\s]+\z"#) } == true, "source URL")
            }
        }
    }

    /// Strict wire shape before decoding: exact keys per kind and JSON types.
    static func validateWire(_ value: JSONValue) throws {
        guard case .array(let entries) = value, !entries.isEmpty, entries.count <= ClipEffect.maximumEntries else {
            throw ClipEffectError.invalidEntry("not a list")
        }
        func number(_ value: JSONValue?) -> Bool { if case .number(let number) = value { return number.isFinite } else { return false } }
        func string(_ value: JSONValue?, nullable: Bool = false) -> Bool {
            if case .string = value { return true }
            return nullable && value == .null
        }
        func rect(_ value: JSONValue?, extra: Set<String> = []) -> Bool {
            guard case .object(let object) = value, Set(object.keys) == Set(["x", "y", "width", "height"]).union(extra) else { return false }
            return Set(["x", "y", "width", "height"]).union(extra).allSatisfy { number(object[$0]) }
        }
        for entry in entries {
            guard case .object(let object) = entry, case .string(let raw) = object["kind"], let kind = ClipEffect.Kind(rawValue: raw),
                  Set(object.keys) == ClipEffect.commonKeys.union(ClipEffect.kindKeys(kind)) else {
                throw ClipEffectError.invalidEntry("unknown or missing field")
            }
            guard string(object["id"]), string(object["clipId"], nullable: true), number(object["start"]), number(object["end"]) else {
                throw ClipEffectError.invalidEntry("field type")
            }
            var valid = true
            if let words = object["wordIds"] {
                if case .array(let ids) = words { valid = valid && ids.allSatisfy { string($0) } } else { valid = false }
            }
            if let value = object["rect"] { valid = valid && rect(value) }
            if let value = object["tracking"] { valid = valid && string(value) }
            if let value = object["track"] {
                if case .array(let samples) = value { valid = valid && samples.allSatisfy { rect($0, extra: ["t"]) } } else { valid = false }
            }
            if let value = object["text"] { valid = valid && string(value) }
            if let value = object["position"] { valid = valid && string(value) }
            if let value = object["scale"] { valid = valid && number(value) }
            if let value = object["gainDb"] { valid = valid && number(value) }
            if let value = object["sound"] {
                guard case .object(let sound) = value, case .string(let source) = sound["source"],
                      Set(sound.keys) == (source == "bundled" ? ClipEffect.Sound.bundledKeys : source == "library" ? ClipEffect.Sound.libraryKeys : []) else {
                    throw ClipEffectError.invalidEntry("sound fields")
                }
                valid = valid && number(sound["durationSeconds"]) && string(sound["title"]) && string(sound["license"])
                if source == "bundled" { valid = valid && string(sound["id"]) }
                else {
                    valid = valid && string(sound["file"]) && string(sound["sha256"]) && string(sound["creator"], nullable: true)
                        && string(sound["attribution"], nullable: true) && string(sound["sourceUrl"], nullable: true)
                }
            }
            guard valid else { throw ClipEffectError.invalidEntry("field type") }
        }
    }

    /// `project` with `effects` added (an existing id is replaced in place), promoted to v4 when it gains its first effect.
    public static func adding(_ effects: [ClipEffect], to project: Project) throws -> Project {
        guard !effects.isEmpty else { return project }
        var result = project.schemaVersion == 4 ? project : try ContextDemoProject.upgradeToV4(project)
        for effect in effects {
            if let index = result.clipEffects.firstIndex(where: { $0.id == effect.id }) { result.clipEffects[index] = effect }
            else { result.clipEffects.append(effect) }
        }
        try validate(result)
        return result
    }

    /// `project` without the effects whose ids are in `ids`.
    public static func removing(_ ids: Set<String>, from project: Project) throws -> Project {
        var result = project
        result.clipEffects.removeAll { ids.contains($0.id) }
        try validate(result)
        return result
    }

    /// Keeps only effects whose clip still exists and whose words are still in the transcript.
    public static func pruned(_ effects: [ClipEffect], clips: [ClipRange], words: Set<String>) -> [ClipEffect] {
        let identities = Set(clips.map(\.id))
        return effects.filter { effect in
            (effect.clipId.map(identities.contains) ?? true) && (effect.wordIds?.allSatisfy(words.contains) ?? true)
        }
    }

    /// The effects a render of `clipID` (nil: the full video) draws: every censor effect, and the others of that clip.
    public static func rendered(in project: Project, clipID: String?) -> [ClipEffect] {
        project.clipEffects.filter { $0.kind.isCensor || $0.clipId == clipID }
    }

    /// A fresh id for an effect of `kind` that `existing` does not use: `fx-<kind>-<n>`.
    public static func nextID(_ kind: ClipEffect.Kind, existing: Set<String>) -> String {
        var index = 1
        while existing.contains("fx-\(kind.rawValue)-\(index)") { index += 1 }
        return "fx-\(kind.rawValue)-\(index)"
    }

    /// A bleeped word as captions show it: each letter and digit becomes × (U+00D7), punctuation stays. Every bundled
    /// caption font has it and it is a symbol, so styles that strip punctuation keep it; a block glyph (U+2588) is in none
    /// of them and an asterisk is punctuation, so either would drop the word from the captions.
    public static func masked(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? "\u{00D7}" : $0 }))
    }

    /// `segments` with every word a bleep or mute covers masked (`masked`), for the captions of a render.
    public static func maskingBleeps(_ segments: [EditSegment], effects: [ClipEffect]) -> [EditSegment] {
        let bleeped = Set(effects.filter(\.kind.usesWords).flatMap { $0.wordIds ?? [] })
        guard !bleeped.isEmpty else { return segments }
        return segments.map { segment in
            guard bleeped.contains(segment.id) else { return segment }
            var copy = segment
            copy.text = masked(segment.text)
            return copy
        }
    }

    /// Smooths a raw track: a centred 3-sample moving average of each edge, the ends kept, every rect clamped.
    public static func smoothed(_ samples: [ClipEffect.TrackSample]) -> [ClipEffect.TrackSample] {
        guard samples.count > 2 else { return samples.map { .init(t: $0.t, rect: $0.rect.clamped) } }
        return samples.indices.map { index in
            guard index > 0, index < samples.count - 1 else { return .init(t: samples[index].t, rect: samples[index].rect.clamped) }
            let a = samples[index - 1].rect, b = samples[index].rect, c = samples[index + 1].rect
            let rect = ClipEffect.Rect(x: (a.x + b.x + c.x) / 3, y: (a.y + b.y + c.y) / 3,
                                       width: (a.width + b.width + c.width) / 3, height: (a.height + b.height + c.height) / 3)
            return .init(t: samples[index].t, rect: rect.clamped)
        }
    }

    /// The sample times for a track over `start..<end`: every `trackInterval` from `start`, and `end` itself.
    public static func trackTimes(start: Double, end: Double) -> [Double] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        let count = Int(((end - start) / ClipEffect.trackInterval).rounded(.down))
        var times = (0...min(count, ClipEffect.maximumTrackSamples - 2)).map { start + Double($0) * ClipEffect.trackInterval }
        if let last = times.last, end - last > 1e-6 { times.append(end) }
        return times
    }
}
