import Foundation

/// Runtime analysis status; transcription §3.1. Persisted as Transcript.refined.
public enum BoundaryRefinement: String, Codable, Sendable, Hashable, CaseIterable {
    case applied
    case skipped
}

/// Adapter token; transcription §3.2.
public struct RawToken: Codable, Sendable, Equatable {
    /// text; Adapter token; transcription §3.2.
    public var text: String
    /// joinsPrevious; Adapter token; transcription §3.2.
    public var joinsPrevious: Bool
    /// start; Adapter token; transcription §3.2.
    public var start: Double?
    /// end; Adapter token; transcription §3.2.
    public var end: Double?
    /// conf; Adapter token; transcription §3.2.
    public var conf: Double?
    /// speaker; Adapter token; transcription §3.2.
    public var speaker: String?
    /// kind; Adapter token; transcription §3.2.
    public var kind: WordKind?
    /// group; Adapter token; transcription §3.2.
    public var group: Int

    /// Creates an explicit value without I/O or generated identifiers.
    public init(text: String, joinsPrevious: Bool = false, start: Double? = nil, end: Double? = nil, conf: Double? = nil, speaker: String? = nil, kind: WordKind? = nil, group: Int = 0) {
        self.text = text
        self.joinsPrevious = joinsPrevious
        self.start = start
        self.end = end
        self.conf = conf
        self.speaker = speaker
        self.kind = kind
        self.group = group
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case joinsPrevious
        case start
        case end
        case conf
        case speaker
        case kind
        case group
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try values.decode(String.self, forKey: .text)
        self.joinsPrevious = try values.decodeIfPresent(Bool.self, forKey: .joinsPrevious) ?? false
        self.start = try values.decodeIfPresent(Double.self, forKey: .start) ?? nil
        self.end = try values.decodeIfPresent(Double.self, forKey: .end) ?? nil
        self.conf = try values.decodeIfPresent(Double.self, forKey: .conf) ?? nil
        self.speaker = try values.decodeIfPresent(String.self, forKey: .speaker) ?? nil
        self.kind = try values.decodeIfPresent(WordKind.self, forKey: .kind) ?? nil
        self.group = try values.decodeIfPresent(Int.self, forKey: .group) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.joinsPrevious, forKey: .joinsPrevious)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
        try values.encode(self.conf, forKey: .conf)
        try values.encode(self.speaker, forKey: .speaker)
        try values.encode(self.kind, forKey: .kind)
        try values.encode(self.group, forKey: .group)
    }

}

/// Assembler output; transcription §3.2 and editing §5.0.
public struct RawWord: Codable, Sendable, Equatable {
    /// text; Assembler output; transcription §3.2 and editing §5.0.
    public var text: String
    /// start; Assembler output; transcription §3.2 and editing §5.0.
    public var start: Double?
    /// end; Assembler output; transcription §3.2 and editing §5.0.
    public var end: Double?
    /// conf; Assembler output; transcription §3.2 and editing §5.0.
    public var conf: Double?
    /// speaker; Assembler output; transcription §3.2 and editing §5.0.
    public var speaker: String?
    /// kind; Assembler output; transcription §3.2 and editing §5.0.
    public var kind: WordKind

    /// Creates an explicit value without I/O or generated identifiers.
    public init(text: String, start: Double? = nil, end: Double? = nil, conf: Double? = nil, speaker: String? = nil, kind: WordKind = .word) {
        self.text = text
        self.start = start
        self.end = end
        self.conf = conf
        self.speaker = speaker
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case conf
        case speaker
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try values.decode(String.self, forKey: .text)
        self.start = try values.decodeIfPresent(Double.self, forKey: .start) ?? nil
        self.end = try values.decodeIfPresent(Double.self, forKey: .end) ?? nil
        self.conf = try values.decodeIfPresent(Double.self, forKey: .conf) ?? nil
        self.speaker = try values.decodeIfPresent(String.self, forKey: .speaker) ?? nil
        self.kind = try values.decodeIfPresent(WordKind.self, forKey: .kind) ?? .word
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.text, forKey: .text)
        try values.encode(self.start, forKey: .start)
        try values.encode(self.end, forKey: .end)
        try values.encode(self.conf, forKey: .conf)
        try values.encode(self.speaker, forKey: .speaker)
        try values.encode(self.kind, forKey: .kind)
    }

}

/// Grouping policy; transcription §6.
public struct GroupingRule: Codable, Sendable, Hashable {
    public enum End: String, Codable, Sendable { case lastToken, nextWordStart }
    public enum Conf: String, Codable, Sendable { case single, mean, min }
    public var end: End
    public var conf: Conf
    public var bracketEvents: Bool
    public init(end: End, conf: Conf, bracketEvents: Bool) { self.end = end; self.conf = conf; self.bracketEvents = bracketEvents }
}

/// Cached adapter output; transcription §3.2 and §14.2.
public struct RawTranscript: Codable, Sendable, Equatable {
    /// engine; Cached adapter output; transcription §3.2 and §14.2.
    public var engine: EngineRef
    /// adapterVersion; Cached adapter output; transcription §3.2 and §14.2.
    public var adapterVersion: Int
    /// grouping; Cached adapter output; transcription §3.2 and §14.2.
    public var grouping: GroupingRule
    /// tokens; Cached adapter output; transcription §3.2 and §14.2.
    public var tokens: [RawToken]
    /// language; Cached adapter output; transcription §3.2 and §14.2.
    public var language: String?
    /// languageProbability; Cached adapter output; transcription §3.2 and §14.2.
    public var languageProbability: Double?
    /// verbatim; Cached adapter output; transcription §3.2 and §14.2.
    public var verbatim: Bool
    /// timing; Cached adapter output; transcription §3.2 and §14.2.
    public var timing: TimingSource
    /// providerRequestID; Cached adapter output; transcription §3.2 and §14.2.
    public var providerRequestID: String?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(engine: EngineRef, adapterVersion: Int = 1, grouping: GroupingRule, tokens: [RawToken], language: String? = nil, languageProbability: Double? = nil, verbatim: Bool, timing: TimingSource, providerRequestID: String? = nil) {
        self.engine = engine
        self.adapterVersion = adapterVersion
        self.grouping = grouping
        self.tokens = tokens
        self.language = language
        self.languageProbability = languageProbability
        self.verbatim = verbatim
        self.timing = timing
        self.providerRequestID = providerRequestID
    }

    private enum CodingKeys: String, CodingKey {
        case engine
        case adapterVersion
        case grouping
        case tokens
        case language
        case languageProbability
        case verbatim
        case timing
        case providerRequestID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.engine = try values.decode(EngineRef.self, forKey: .engine)
        self.adapterVersion = try values.decodeIfPresent(Int.self, forKey: .adapterVersion) ?? 1
        self.grouping = try values.decode(GroupingRule.self, forKey: .grouping)
        self.tokens = try values.decode([RawToken].self, forKey: .tokens)
        self.language = try values.decodeIfPresent(String.self, forKey: .language) ?? nil
        self.languageProbability = try values.decodeIfPresent(Double.self, forKey: .languageProbability) ?? nil
        self.verbatim = try values.decode(Bool.self, forKey: .verbatim)
        self.timing = try values.decode(TimingSource.self, forKey: .timing)
        self.providerRequestID = try values.decodeIfPresent(String.self, forKey: .providerRequestID) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.engine, forKey: .engine)
        try values.encode(self.adapterVersion, forKey: .adapterVersion)
        try values.encode(self.grouping, forKey: .grouping)
        try values.encode(self.tokens, forKey: .tokens)
        try values.encode(self.language, forKey: .language)
        try values.encode(self.languageProbability, forKey: .languageProbability)
        try values.encode(self.verbatim, forKey: .verbatim)
        try values.encode(self.timing, forKey: .timing)
        try values.encode(self.providerRequestID, forKey: .providerRequestID)
    }

}

/// 10 ms RMS values, no media framework objects; editing §5.1 and architecture §4.
public struct AudioEnvelope: Codable, Sendable, Equatable {
    /// sampleRate; 10 ms RMS values, no media framework objects; editing §5.1 and architecture §4.
    public var sampleRate: Double
    /// frameSeconds; 10 ms RMS values, no media framework objects; editing §5.1 and architecture §4.
    public var frameSeconds: Double
    /// levels; 10 ms RMS values, no media framework objects; editing §5.1 and architecture §4.
    public var levels: [Float]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(sampleRate: Double, frameSeconds: Double = 0.01, levels: [Float]) {
        self.sampleRate = sampleRate
        self.frameSeconds = frameSeconds
        self.levels = levels
    }

    private enum CodingKeys: String, CodingKey {
        case sampleRate
        case frameSeconds
        case levels
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.sampleRate = try values.decode(Double.self, forKey: .sampleRate)
        self.frameSeconds = try values.decodeIfPresent(Double.self, forKey: .frameSeconds) ?? 0.01
        self.levels = try values.decode([Float].self, forKey: .levels)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.sampleRate, forKey: .sampleRate)
        try values.encode(self.frameSeconds, forKey: .frameSeconds)
        try values.encode(self.levels, forKey: .levels)
    }

}

/// Shared grouping implementation point; transcription §6.
public enum WordAssembler {
    public static func group(_ tokens: [RawToken], rule: GroupingRule, timelineStart: Double) throws -> [RawWord] { throw VoxClipError.notImplemented("mac-speech") }
}
/// Import normalization and gap detection; transcription §7.
public func cleanWords(_ words: [RawWord], timing: TimingSource) throws -> [TimedWord] { throw VoxClipError.notImplemented("mac-speech") }
public func tightenIntoSound(_ words: [TimedWord], envelope: AudioEnvelope, timing: TimingSource) throws -> [TimedWord] { throw VoxClipError.notImplemented("mac-speech") }
public func findUnlabeledSpeech(_ words: [TimedWord], envelope: AudioEnvelope) throws -> [TimedWord] { throw VoxClipError.notImplemented("mac-speech") }
/// Language choice does not silently change a local job into an upload; transcription §11.
public enum LanguageRouter {
    public static func route(language: LanguageChoice, preferred: TranscriptEngine, installedModels: [String]) throws -> TranscriptionPlan { throw VoxClipError.notImplemented("mac-speech") }
}
extension RawToken: Hashable {}
extension RawWord: Hashable {}
