import Foundation

/// User language choice; transcription §3.3.
public enum LanguageChoice: Codable, Sendable, Hashable { case auto; case forced(String) }

/// Engine options; transcription §3.3.
public struct TranscriptionOptions: Codable, Sendable, Equatable {
    /// diarize; Engine options; transcription §3.3.
    public var diarize: Bool
    /// numSpeakers; Engine options; transcription §3.3.
    public var numSpeakers: Int?
    /// keyterms; Engine options; transcription §3.3.
    public var keyterms: [String]
    /// dtw; Engine options; transcription §3.3.
    public var dtw: Bool

    /// Creates an explicit value without I/O or generated identifiers.
    public init(diarize: Bool = false, numSpeakers: Int? = nil, keyterms: [String] = [], dtw: Bool = true) {
        self.diarize = diarize
        self.numSpeakers = numSpeakers
        self.keyterms = keyterms
        self.dtw = dtw
    }

    private enum CodingKeys: String, CodingKey {
        case diarize
        case numSpeakers
        case keyterms
        case dtw
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.diarize = try values.decodeIfPresent(Bool.self, forKey: .diarize) ?? false
        self.numSpeakers = try values.decodeIfPresent(Int.self, forKey: .numSpeakers) ?? nil
        self.keyterms = try values.decodeIfPresent([String].self, forKey: .keyterms) ?? []
        self.dtw = try values.decodeIfPresent(Bool.self, forKey: .dtw) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.diarize, forKey: .diarize)
        try values.encode(self.numSpeakers, forKey: .numSpeakers)
        try values.encode(self.keyterms, forKey: .keyterms)
        try values.encode(self.dtw, forKey: .dtw)
    }

}

/// Explicit engine selection, never implicit cloud fallback; transcription §3.3.
public struct TranscriptionPlan: Codable, Sendable, Equatable {
    /// engine; Explicit engine selection, never implicit cloud fallback; transcription §3.3.
    public var engine: TranscriptEngine
    /// model; Explicit engine selection, never implicit cloud fallback; transcription §3.3.
    public var model: String?
    /// language; Explicit engine selection, never implicit cloud fallback; transcription §3.3.
    public var language: LanguageChoice
    /// options; Explicit engine selection, never implicit cloud fallback; transcription §3.3.
    public var options: TranscriptionOptions

    /// Creates an explicit value without I/O or generated identifiers.
    public init(engine: TranscriptEngine, model: String? = nil, language: LanguageChoice = .auto, options: TranscriptionOptions = TranscriptionOptions()) {
        self.engine = engine
        self.model = model
        self.language = language
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case engine
        case model
        case language
        case options
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.engine = try values.decode(TranscriptEngine.self, forKey: .engine)
        self.model = try values.decodeIfPresent(String.self, forKey: .model) ?? nil
        self.language = try values.decodeIfPresent(LanguageChoice.self, forKey: .language) ?? .auto
        self.options = try values.decodeIfPresent(TranscriptionOptions.self, forKey: .options) ?? TranscriptionOptions()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.engine, forKey: .engine)
        try values.encode(self.model, forKey: .model)
        try values.encode(self.language, forKey: .language)
        try values.encode(self.options, forKey: .options)
    }

}

/// 16 kHz PCM WAV on the source presentation timeline; transcription §3.3.
public struct ExtractedAudio: Sendable, Equatable {
    public var wav16k: URL
    public var sampleCount: Int64
    public var durationSeconds: Double
    public var timelineStart: Double
    public var audioTrackIndex: Int
    public init(wav16k: URL, sampleCount: Int64, durationSeconds: Double, timelineStart: Double = 0, audioTrackIndex: Int = 0) {
        self.wav16k = wav16k
        self.sampleCount = sampleCount
        self.durationSeconds = durationSeconds
        self.timelineStart = timelineStart
        self.audioTrackIndex = audioTrackIndex
    }
}

/// Adapter request; transcription §3.3.
public struct TranscriptionRequest: Sendable, Equatable {
    public var plan: TranscriptionPlan
    public var audio: ExtractedAudio
    public var contentKey: String
    public init(plan: TranscriptionPlan, audio: ExtractedAudio, contentKey: String) {
        self.plan = plan
        self.audio = audio
        self.contentKey = contentKey
    }
}

/// Engine readiness; transcription §3.3.
public enum Readiness: Sendable, Equatable {
    case ready
    case needsKey(provider: String)
    case needsModels(ids: [String], bytes: Int64)
    case needsSystemAssets(locale: String)
    case unsupportedLanguage(String)
    case unavailable(reason: String)
}

/// Progress stages; transcription §3.3 and §13.
public enum TranscriptionStage: String, Codable, Sendable, Hashable, CaseIterable {
    case preparing
    case uploading
    case transcribing
    case aligning
}

/// Adapter progress callback, coalesced by service into a 10 Hz stream; transcription §13.
public struct TranscriptionProgress: Sendable, Equatable {
    public var stage: TranscriptionStage
    public var fraction: Double?
    public init(stage: TranscriptionStage, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Engine declaration; transcription §3.3.
public struct TranscriberCapabilities: Sendable, Equatable {
    public var timing: TimingSource
    public var verbatim: Bool
    public var autoLanguage: Bool
    public var maxDurationSeconds: Double?
    public var maxUploadBytes: Int64?
    public var onDevice: Bool
    public init(timing: TimingSource, verbatim: Bool, autoLanguage: Bool, maxDurationSeconds: Double? = nil, maxUploadBytes: Int64? = nil, onDevice: Bool) {
        self.timing = timing
        self.verbatim = verbatim
        self.autoLanguage = autoLanguage
        self.maxDurationSeconds = maxDurationSeconds
        self.maxUploadBytes = maxUploadBytes
        self.onDevice = onDevice
    }
}

/// Exact adapter seam; transcription §3.3 and architecture §7.1.
public protocol Transcriber: Sendable {
    var engine: TranscriptEngine { get }
    func capabilities(model: String?) -> TranscriberCapabilities
    func supports(_ language: LanguageChoice, model: String?) async -> Bool
    func readiness(for plan: TranscriptionPlan) async -> Readiness
    func prepare(for plan: TranscriptionPlan, progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ request: TranscriptionRequest, progress: @escaping @Sendable (TranscriptionProgress) -> Void) async throws -> RawTranscript
}
/// One import pipeline with immutable output; transcription §5, §7 and §13.4.
public actor TranscriptionService {
    public init() {}
    public func transcribe(_ request: TranscriptionRequest, using engine: any Transcriber, envelope: AudioEnvelope?) async throws -> Transcript { throw VoxClipError.notImplemented("mac-speech") }
    /// Placeholder completed stream; no job starts in the skeleton.
    public func progress() -> AsyncStream<TranscriptionProgress> {
        // TODO(mac-speech)
        return AsyncStream { $0.finish() }
    }
}
extension TranscriptionOptions: Hashable {}
extension TranscriptionPlan: Hashable {}
