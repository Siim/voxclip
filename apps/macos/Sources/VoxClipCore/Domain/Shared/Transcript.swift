import Foundation

/// Transcript item identity; editing §2.2.
public enum WordKind: String, Codable, Sendable, Hashable, CaseIterable {
    case word
    case event
    case unlabeledSpeech
}

/// Timing provenance; transcription §3.1 and timed-word schema v1.
public enum TimingSource: String, Codable, Sendable, Hashable, CaseIterable {
    case native
    case dtw
    case tokenGrouped
    case runGrouped
    case detected
}

/// Engine selection identifiers; transcription §3.1 and the shared engine catalogue.
public enum TranscriptEngine: String, Codable, Sendable, Hashable, CaseIterable {
    case elevenlabs
    case whispercpp
    case appleSpeech = "apple-speech"
}

/// Import-pipeline cache version; transcription §3.1. Bump when grouping/refinement output changes.
public let PIPELINE_VERSION = 1

/// Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
public struct TimedWord: Codable, Sendable, Equatable {
    /// id; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var id: String
    /// text; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var text: String
    /// kind; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var kind: WordKind
    /// start; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var start: Double
    /// end; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var end: Double
    /// rawStart; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var rawStart: Double?
    /// rawEnd; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var rawEnd: Double?
    /// conf; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var conf: Double?
    /// speaker; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var speaker: String?
    /// timing; Immutable source timing value; editing §2.2, timed-word.schema.json. Optional fields encode explicit null.
    public var timing: TimingSource

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, text: String, kind: WordKind = .word, start: Double, end: Double, rawStart: Double? = nil, rawEnd: Double? = nil, conf: Double? = nil, speaker: String? = nil, timing: TimingSource = .native) {
        self.id = id
        self.text = text
        self.kind = kind
        self.start = start
        self.end = end
        self.rawStart = rawStart
        self.rawEnd = rawEnd
        self.conf = conf
        self.speaker = speaker
        self.timing = timing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case kind
        case start
        case end
        case rawStart
        case rawEnd
        case conf
        case speaker
        case timing
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.text = try values.decode(String.self, forKey: .text)
        self.kind = try values.decode(WordKind.self, forKey: .kind)
        self.start = try values.decode(Double.self, forKey: .start)
        self.end = try values.decode(Double.self, forKey: .end)
        self.rawStart = try values.decode(Optional<Double>.self, forKey: .rawStart)
        self.rawEnd = try values.decode(Optional<Double>.self, forKey: .rawEnd)
        self.conf = try values.decode(Optional<Double>.self, forKey: .conf)
        self.speaker = try values.decode(Optional<String>.self, forKey: .speaker)
        self.timing = try values.decode(TimingSource.self, forKey: .timing)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.kind, forKey: .kind)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
        try values.encode(self.rawStart, forKey: .rawStart)
        try values.encode(self.rawEnd, forKey: .rawEnd)
        try values.encode(self.conf, forKey: .conf)
        try values.encode(self.speaker, forKey: .speaker)
        try values.encode(self.timing, forKey: .timing)
    }

}

extension TimedWord: Hashable, Identifiable {}

/// Canonical engine metadata for raw and persisted transcripts; transcription §3.1, architecture §3.
public struct EngineRef: Codable, Sendable, Hashable {
    /// id; doc/architecture.md §3; shared/schemas/project.schema.json
    public var id: TranscriptEngine
    /// modelId; shared/schemas/project.schema.json. Never serialized as modelID.
    public var modelId: String?
    /// modelSha256; doc/architecture.md §3; shared/schemas/project.schema.json
    public var modelSha256: String?
    /// engineVersion; doc/architecture.md §3; shared/schemas/project.schema.json
    public var engineVersion: String
    /// locale; doc/architecture.md §3; shared/schemas/project.schema.json
    public var locale: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: TranscriptEngine, modelId: String? = nil, modelSha256: String? = nil, engineVersion: String, locale: String? = nil) {
        self.id = id
        self.modelId = modelId
        self.modelSha256 = modelSha256
        self.engineVersion = engineVersion
        self.locale = locale
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelId
        case modelSha256
        case engineVersion
        case locale
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(TranscriptEngine.self, forKey: .id)
        self.modelId = try values.decode(Optional<String>.self, forKey: .modelId)
        self.modelSha256 = try values.decode(Optional<String>.self, forKey: .modelSha256)
        self.engineVersion = try values.decode(String.self, forKey: .engineVersion)
        self.locale = try values.decode(Optional<String>.self, forKey: .locale)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.modelId, forKey: .modelId)
        try values.encode(self.modelSha256, forKey: .modelSha256)
        try values.encode(self.engineVersion, forKey: .engineVersion)
        try values.encode(self.locale, forKey: .locale)
    }

}

/// doc/architecture.md §3; shared/schemas/project.schema.json
public struct Transcript: Codable, Sendable, Equatable {
    /// schemaVersion; doc/architecture.md §3; shared/schemas/project.schema.json
    public var schemaVersion: Int
    /// words; doc/architecture.md §3; shared/schemas/project.schema.json
    public var words: [TimedWord]
    /// language; doc/architecture.md §3; shared/schemas/project.schema.json
    public var language: String?
    /// languageProbability; doc/architecture.md §3; shared/schemas/project.schema.json
    public var languageProbability: Double?
    /// durationSeconds; doc/architecture.md §3; shared/schemas/project.schema.json
    public var durationSeconds: Double
    /// engine; doc/architecture.md §3; shared/schemas/project.schema.json
    public var engine: EngineRef
    /// verbatim; doc/architecture.md §3; shared/schemas/project.schema.json
    public var verbatim: Bool
    /// refined; doc/architecture.md §3; shared/schemas/project.schema.json
    public var refined: Bool
    /// pipelineVersion; doc/architecture.md §3; shared/schemas/project.schema.json
    public var pipelineVersion: Int
    /// rawKey; doc/architecture.md §3; shared/schemas/project.schema.json
    public var rawKey: String
    /// createdAt; doc/architecture.md §3; shared/schemas/project.schema.json
    public var createdAt: Date

    /// Creates an explicit value without I/O or generated identifiers.
    public init(schemaVersion: Int = 1, words: [TimedWord] = [], language: String? = nil, languageProbability: Double? = nil, durationSeconds: Double, engine: EngineRef, verbatim: Bool = true, refined: Bool = false, pipelineVersion: Int = PIPELINE_VERSION, rawKey: String, createdAt: Date) {
        self.schemaVersion = schemaVersion
        self.words = words
        self.language = language
        self.languageProbability = languageProbability
        self.durationSeconds = durationSeconds
        self.engine = engine
        self.verbatim = verbatim
        self.refined = refined
        self.pipelineVersion = pipelineVersion
        self.rawKey = rawKey
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case words
        case language
        case languageProbability
        case durationSeconds
        case engine
        case verbatim
        case refined
        case pipelineVersion
        case rawKey
        case createdAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        self.words = try values.decode([TimedWord].self, forKey: .words)
        self.language = try values.decode(Optional<String>.self, forKey: .language)
        self.languageProbability = try values.decode(Optional<Double>.self, forKey: .languageProbability)
        self.durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
        self.engine = try values.decode(EngineRef.self, forKey: .engine)
        self.verbatim = try values.decode(Bool.self, forKey: .verbatim)
        self.refined = try values.decode(Bool.self, forKey: .refined)
        self.pipelineVersion = try values.decode(Int.self, forKey: .pipelineVersion)
        self.rawKey = try values.decode(String.self, forKey: .rawKey)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.schemaVersion, forKey: .schemaVersion)
        try values.encode(self.words, forKey: .words)
        try values.encode(self.language, forKey: .language)
        try values.encode(self.languageProbability, forKey: .languageProbability)
        try values.encode(self.durationSeconds, forKey: .durationSeconds)
        try values.encode(self.engine, forKey: .engine)
        try values.encode(self.verbatim, forKey: .verbatim)
        try values.encode(self.refined, forKey: .refined)
        try values.encode(self.pipelineVersion, forKey: .pipelineVersion)
        try values.encode(self.rawKey, forKey: .rawKey)
        try values.encode(self.createdAt, forKey: .createdAt)
    }

}
