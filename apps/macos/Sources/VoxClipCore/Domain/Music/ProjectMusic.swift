import Foundation

/// Where a background track came from; doc/spec/music.md §2.
public enum MusicSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// A free library track (Openverse), CC0, CC BY or public domain only.
    case library
    /// Composed by Eleven Music for this clip.
    case generated
    /// The user's own file.
    case file
}

/// The terms a track is used under. Library tracks are cc0, by or pdm; nc, nd and sa are never accepted.
public enum MusicLicense: String, Codable, Sendable, Equatable, CaseIterable {
    case cc0, by, pdm, generated, own

    /// The licenses one source may carry.
    public static func allowed(for source: MusicSource) -> Set<MusicLicense> {
        switch source {
        case .library: [.cc0, .by, .pdm]
        case .generated: [.generated]
        case .file: [.own]
        }
    }
}

/// The track file kept in the data folder's `Music/<projectId>/`; never inside the project document.
public struct MusicAsset: Codable, Sendable, Equatable {
    /// `<projectId>/music-<slug>.<ext>`, relative to the data folder's Music root.
    public var file: String
    public var sha256: String
    public var durationSeconds: Double

    public init(file: String, sha256: String, durationSeconds: Double) {
        self.file = file; self.sha256 = sha256; self.durationSeconds = durationSeconds
    }

    public static let extensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "flac"]
}

/// One background track under a clip (or the full video when `clipId` is nil); doc/spec/music.md §2.
/// Every key is written, with null where a source has no value, so both Cores read each entry the same way.
public struct ProjectMusic: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// The clip this track plays under; nil plays under the full-video export.
    public var clipId: String?
    public var asset: MusicAsset
    public var source: MusicSource
    public var title: String
    public var creator: String?
    public var license: MusicLicense
    /// The credit line the export's post text carries; required for CC BY.
    public var attribution: String?
    /// The page the track came from (library), or nil.
    public var sourceUrl: String?
    /// The Eleven Music prompt (generated only).
    public var prompt: String?
    /// The bed's level relative to the clip's measured speech loudness, in dB. -20 sits well under the voice.
    public var gainDb: Double
    /// Dip about 12 dB while someone talks.
    public var ducking: Bool
    public var fadeInSeconds: Double
    public var fadeOutSeconds: Double
    /// Where in the track the clip's music starts.
    public var startOffsetSeconds: Double

    public static let defaultGainDb = -20.0
    public static let gainRange = -40.0...0.0
    public static let defaultFadeIn = 0.5
    public static let defaultFadeOut = 1.5
    public static let fadeRange = 0.0...10.0
    public static let maximumDuration = 1_800.0
    public static let maximumEntries = 65

    public init(id: String, clipId: String?, asset: MusicAsset, source: MusicSource, title: String, creator: String? = nil,
                license: MusicLicense, attribution: String? = nil, sourceUrl: String? = nil, prompt: String? = nil,
                gainDb: Double = ProjectMusic.defaultGainDb, ducking: Bool = true, fadeInSeconds: Double = ProjectMusic.defaultFadeIn,
                fadeOutSeconds: Double = ProjectMusic.defaultFadeOut, startOffsetSeconds: Double = 0) {
        self.id = id; self.clipId = clipId; self.asset = asset; self.source = source; self.title = title; self.creator = creator
        self.license = license; self.attribution = attribution; self.sourceUrl = sourceUrl; self.prompt = prompt; self.gainDb = gainDb
        self.ducking = ducking; self.fadeInSeconds = fadeInSeconds; self.fadeOutSeconds = fadeOutSeconds; self.startOffsetSeconds = startOffsetSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, clipId, asset, source, title, creator, license, attribution, sourceUrl, prompt, gainDb, ducking
        case fadeInSeconds, fadeOutSeconds, startOffsetSeconds
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        clipId = try values.decode(String?.self, forKey: .clipId)
        asset = try values.decode(MusicAsset.self, forKey: .asset)
        source = try values.decode(MusicSource.self, forKey: .source)
        title = try values.decode(String.self, forKey: .title)
        creator = try values.decode(String?.self, forKey: .creator)
        license = try values.decode(MusicLicense.self, forKey: .license)
        attribution = try values.decode(String?.self, forKey: .attribution)
        sourceUrl = try values.decode(String?.self, forKey: .sourceUrl)
        prompt = try values.decode(String?.self, forKey: .prompt)
        gainDb = try values.decode(Double.self, forKey: .gainDb)
        ducking = try values.decode(Bool.self, forKey: .ducking)
        fadeInSeconds = try values.decode(Double.self, forKey: .fadeInSeconds)
        fadeOutSeconds = try values.decode(Double.self, forKey: .fadeOutSeconds)
        startOffsetSeconds = try values.decode(Double.self, forKey: .startOffsetSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(clipId, forKey: .clipId)
        try values.encode(asset, forKey: .asset)
        try values.encode(source, forKey: .source)
        try values.encode(title, forKey: .title)
        try values.encode(creator, forKey: .creator)
        try values.encode(license, forKey: .license)
        try values.encode(attribution, forKey: .attribution)
        try values.encode(sourceUrl, forKey: .sourceUrl)
        try values.encode(prompt, forKey: .prompt)
        try values.encode(gainDb, forKey: .gainDb)
        try values.encode(ducking, forKey: .ducking)
        try values.encode(fadeInSeconds, forKey: .fadeInSeconds)
        try values.encode(fadeOutSeconds, forKey: .fadeOutSeconds)
        try values.encode(startOffsetSeconds, forKey: .startOffsetSeconds)
    }

    /// The line the post text carries for this track, or nil when its terms need none (own files).
    public var creditLine: String? {
        switch license {
        case .own: return nil
        case .generated: return "Music: \u{201C}\(title)\u{201D}, made with Eleven Music."
        case .cc0, .pdm, .by:
            if let attribution, !attribution.isEmpty { return "Music: " + attribution }
            let by = creator.map { " by \($0)" } ?? ""
            let terms = license == .cc0 ? "CC0" : license == .pdm ? "Public Domain Mark" : "CC BY"
            return "Music: \u{201C}\(title)\u{201D}\(by) (\(terms))" + (sourceUrl.map { " \($0)" } ?? "")
        }
    }
}

public enum MusicProjectError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedVersion, invalidEntry(String), unknownClip, duplicateClip, duplicateIdentity

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Background music needs the current project format."
        case .invalidEntry(let reason): "The project's background music is invalid: \(reason)."
        case .unknownClip: "Background music refers to a clip that is not in the project."
        case .duplicateClip: "A clip has more than one background track."
        case .duplicateIdentity: "Two background tracks share an id."
        }
    }
}

/// The `music` root field: schema v4 only, omitted when empty; doc/spec/music.md §2 and project schema `$defs.music`.
public enum MusicProject {
    static let identifier = #"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z"#
    static let file = #"\A[0-9a-f-]{36}/music-[a-z0-9][a-z0-9_-]{0,57}\.(mp3|m4a|wav|aif|aiff|flac)\z"#
    static let hash = #"\A[0-9a-f]{64}\z"#

    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    /// The typed rules the schema cannot express: clip identity, the project's own asset folder, one track per clip.
    public static func validate(_ project: Project) throws {
        guard !project.music.isEmpty else { return }
        guard project.schemaVersion == 4 else { throw MusicProjectError.unsupportedVersion }
        guard project.music.count <= ProjectMusic.maximumEntries else { throw MusicProjectError.invalidEntry("too many tracks") }
        let clips = Set(project.edits.clips.map(\.id))
        var identities = Set<String>()
        var scopes = Set<String>()
        for entry in project.music {
            try validate(entry, projectId: project.id)
            guard identities.insert(entry.id).inserted else { throw MusicProjectError.duplicateIdentity }
            if let clipId = entry.clipId, !clips.contains(clipId) { throw MusicProjectError.unknownClip }
            guard scopes.insert(entry.clipId ?? "").inserted else { throw MusicProjectError.duplicateClip }
        }
    }

    public static func validate(_ entry: ProjectMusic, projectId: String) throws {
        func require(_ condition: Bool, _ reason: String) throws { if !condition { throw MusicProjectError.invalidEntry(reason) } }
        func text(_ value: String?, _ range: ClosedRange<Int>) -> Bool { value.map { range.contains($0.count) && !$0.contains("\u{0}") } ?? true }
        try require(matches(entry.id, identifier), "id")
        try require(entry.clipId.map { matches($0, identifier) } ?? true, "clip id")
        try require(matches(entry.asset.file, file) && entry.asset.file.hasPrefix(projectId + "/"), "file")
        try require(matches(entry.asset.sha256, hash), "hash")
        let duration = entry.asset.durationSeconds
        try require(duration.isFinite && duration > 0 && duration <= ProjectMusic.maximumDuration, "duration")
        try require(text(entry.title, 1...200) && text(entry.creator, 1...200), "title or creator")
        try require(MusicLicense.allowed(for: entry.source).contains(entry.license), "license")
        try require(text(entry.attribution, 1...1_000) && (entry.license != .by || entry.attribution != nil), "attribution")
        try require(entry.sourceUrl.map { $0.count <= 2_048 && matches($0, #"\Ahttps://[^\s]+\z"#) } ?? true, "source URL")
        try require(entry.source != .library || entry.sourceUrl != nil, "library source URL")
        try require(text(entry.prompt, 1...2_000) && ((entry.source == .generated) == (entry.prompt != nil)), "prompt")
        try require(entry.gainDb.isFinite && ProjectMusic.gainRange.contains(entry.gainDb), "gain")
        try require(entry.fadeInSeconds.isFinite && ProjectMusic.fadeRange.contains(entry.fadeInSeconds), "fade-in")
        try require(entry.fadeOutSeconds.isFinite && ProjectMusic.fadeRange.contains(entry.fadeOutSeconds), "fade-out")
        try require(entry.startOffsetSeconds.isFinite && entry.startOffsetSeconds >= 0 && entry.startOffsetSeconds < duration, "start offset")
    }

    /// Strict wire shape before decoding: exact keys and JSON types, so a number never stands in for a string or a bool.
    static func validateWire(_ value: JSONValue) throws {
        // Absent when empty: an explicit empty list is not a saved shape.
        guard case .array(let entries) = value, !entries.isEmpty, entries.count <= ProjectMusic.maximumEntries else {
            throw MusicProjectError.invalidEntry("not a list")
        }
        let keys: Set<String> = ["id", "clipId", "asset", "source", "title", "creator", "license", "attribution", "sourceUrl", "prompt",
                                 "gainDb", "ducking", "fadeInSeconds", "fadeOutSeconds", "startOffsetSeconds"]
        for entry in entries {
            guard case .object(let object) = entry, Set(object.keys) == keys,
                  case .object(let asset) = object["asset"], Set(asset.keys) == ["file", "sha256", "durationSeconds"] else {
                throw MusicProjectError.invalidEntry("unknown or missing field")
            }
            func string(_ value: JSONValue?, nullable: Bool = false) -> Bool {
                if case .string = value { return true }
                return nullable && value == .null
            }
            func number(_ value: JSONValue?) -> Bool { if case .number(let number) = value { return number.isFinite } else { return false } }
            guard string(object["id"]), string(object["clipId"], nullable: true), string(asset["file"]), string(asset["sha256"]),
                  number(asset["durationSeconds"]), string(object["source"]), string(object["title"]), string(object["creator"], nullable: true),
                  string(object["license"]), string(object["attribution"], nullable: true), string(object["sourceUrl"], nullable: true),
                  string(object["prompt"], nullable: true), number(object["gainDb"]), number(object["fadeInSeconds"]),
                  number(object["fadeOutSeconds"]), number(object["startOffsetSeconds"]) else {
                throw MusicProjectError.invalidEntry("field type")
            }
            guard case .bool = object["ducking"] else { throw MusicProjectError.invalidEntry("ducking") }
        }
    }

    /// Sets (or with nil removes) the track under `clipId`, promoting the project to v4 when it gains its first track.
    public static func setting(_ entry: ProjectMusic?, clipId: String?, in project: Project) throws -> Project {
        var result = project
        result.music.removeAll { $0.clipId == clipId }
        if let entry {
            guard entry.clipId == clipId else { throw MusicProjectError.invalidEntry("clip") }
            result = try ContextDemoProject.upgradeToV4(result)
            result.music.append(entry)
        }
        try validate(result)
        return result
    }

    /// The track under a clip, or under the full video for nil.
    public static func entry(for clipId: String?, in project: Project) -> ProjectMusic? {
        project.music.first { $0.clipId == clipId }
    }

    /// Keeps only tracks whose clip still exists; full-video tracks stay.
    public static func pruned(_ music: [ProjectMusic], clips: [ClipRange]) -> [ProjectMusic] {
        let identities = Set(clips.map(\.id))
        return music.filter { $0.clipId.map(identities.contains) ?? true }
    }
}
