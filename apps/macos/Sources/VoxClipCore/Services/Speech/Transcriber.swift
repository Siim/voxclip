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

public protocol SpeechLanguageDetector: Sendable {
    func detectLanguage(_ request: TranscriptionRequest) async throws -> SpeechLanguageDetection
}
public struct TranscriptionResult: Sendable {
    public var transcript: Transcript
    public var fromCache: Bool = false
    public init(transcript: Transcript, fromCache: Bool = false) {
        self.transcript = transcript
        self.fromCache = fromCache
    }
}
/// One import pipeline with immutable output; transcription §5, §7 and §13.4.
public actor TranscriptionService {
    private let locations: DataLocations
    private let catalog: BundledModelCatalog?
    /// The app-wide queue every public initializer shares; tests pass a private one.
    let gate: SpeechJobGate
    private var active = false
    private var generation = UUID()
    private var observers: [UUID: AsyncStream<TranscriptionProgress>.Continuation] = [:]
    public init() {
        locations = DataLocations()
        catalog = (try? SharedResources.locate()).map { BundledModelCatalog(shared: $0) }
        gate = .shared
    }
    public init(locations: DataLocations, catalog: BundledModelCatalog? = nil) { self.init(locations: locations, catalog: catalog, gate: .shared) }
    init(locations: DataLocations, catalog: BundledModelCatalog? = nil, gate: SpeechJobGate) { self.locations = locations; self.catalog = catalog; self.gate = gate }
    public func detectLanguage(_ request: TranscriptionRequest, using detector: any SpeechLanguageDetector) async throws -> SpeechLanguageDetection {
        guard !active else { throw VoxClipError.transcriptionFailed("This project already has a transcription job") }
        active = true
        defer { active = false }
        // Detection reads the source's cache entry, so eviction leaves it alone meanwhile (architecture §8.2).
        let lease = await CacheKeyRegistry.shared(cache: locations.cache).lease(request.contentKey)
        defer { lease.release() }
        let key = locations.cache.appendingPathComponent(request.contentKey).appendingPathComponent("language-detection").path
        do { try await gate.acquire(local: true, key: key) }
        catch is CancellationError { throw VoxClipError.cancelled }
        do {
            let detection = try await detector.detectLanguage(request)
            try Task.checkCancellation()
            await gate.release(local: true, key: key)
            return detection
        } catch {
            await gate.release(local: true, key: key)
            if Task.isCancelled || error is CancellationError { throw VoxClipError.cancelled }
            throw error
        }
    }
    public func transcribe(_ request: TranscriptionRequest, using engine: any Transcriber, envelope: AudioEnvelope?) async throws -> Transcript {
        try await transcribeResult(request, using: engine, envelope: envelope).transcript
    }
    public func transcribeResult(_ request: TranscriptionRequest, using engine: any Transcriber, envelope: AudioEnvelope?) async throws -> TranscriptionResult {
        guard !active else { throw VoxClipError.transcriptionFailed("This project already has a transcription job") }
        guard request.plan.engine == engine.engine, request.audio.durationSeconds.isFinite, request.audio.durationSeconds > 0,
              request.contentKey.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw VoxClipError.transcriptionFailed("Invalid transcription request") }
        active = true
        generation = UUID()
        let job = generation
        defer { active = false; for observer in observers.values { observer.finish() }; observers.removeAll() }
        // The job reads the extracted audio and writes raw transcripts into the source's cache entry, so eviction leaves
        // that entry alone until it ends (architecture §8.2).
        let lease = await CacheKeyRegistry.shared(cache: locations.cache).lease(request.contentKey)
        defer { lease.release() }
        let delivery = AsyncStream<TranscriptionProgress>.makeStream()
        let publishing = Task { [weak self] in
            for await value in delivery.stream { await self?.publish(value, job: job) }
        }
        let reporter = SpeechProgressThrottle { delivery.continuation.yield($0) }
        defer { reporter.cancel(); delivery.continuation.finish(); publishing.cancel() }
        let originalRequest = request
        let request: TranscriptionRequest
        if let catalog { request = try await SpeechRawCacheKey.normalizedRequest(originalRequest, catalog: catalog) }
        else if let elevenLabs = engine as? ElevenLabsTranscriber { request = try await elevenLabs.normalizedRequest(originalRequest) }
        else {
            let catalog = (try? SharedResources.locate()).map { BundledModelCatalog(shared: $0) }
            request = try await SpeechRawCacheKey.normalizedRequest(originalRequest, catalog: catalog)
        }
        let identity: EngineRef
        if let provider = engine as? any SpeechCacheIdentityProviding { identity = try await provider.cacheIdentity(for: request.plan) }
        else {
            let model = request.plan.engine == .elevenlabs ? "scribe_v2" : request.plan.model
            var hash: String?
            if engine.engine == .whispercpp, let model, let catalog { hash = try await catalog.model(id: model).files.first(where: { $0.role == "model" })?.sha256 }
            identity = EngineRef(id: engine.engine, modelId: model, modelSha256: hash, engineVersion: "", locale: nil)
        }
        let key = SpeechRawCacheKey(request: request, identity: identity)
        guard identity.id == engine.engine else { throw SpeechErrorCopy.unsupported(engine.engine, language: request.plan.language) }
        let rawKey = try key.digest()
        let directory = locations.cache.appendingPathComponent(request.contentKey).appendingPathComponent("transcripts")
        let url = try key.url(in: directory)
        // One job per raw cache entry: identical jobs in one data folder run one at a time (transcription §13.4).
        let local = engine.engine != .elevenlabs, gateKey = url.path
        do { try await gate.acquire(local: local, key: gateKey) }
        catch is CancellationError { throw VoxClipError.cancelled }
        do {
            try Task.checkCancellation()
            let raw: RawTranscript
            let fromCache: Bool
            if let cached = try? SpeechRawCacheEntry.read(url), let matched = cached.matchingRaw(for: key) {
                raw = matched
                fromCache = engine.engine == .elevenlabs
            } else {
                guard await engine.supports(request.plan.language, model: request.plan.model) else { throw SpeechErrorCopy.unsupported(engine.engine, language: request.plan.language) }
                reporter.report(TranscriptionProgress(stage: .preparing, fraction: 0))
                try await engine.prepare(for: request.plan) { fraction in reporter.report(TranscriptionProgress(stage: .preparing, fraction: fraction)) }
                if let elevenLabs = engine as? ElevenLabsTranscriber {
                    let result = try await elevenLabs.transcribeWithCache(request, cacheURL: url) { reporter.report($0) }
                    raw = result.raw
                    fromCache = result.fromCache
                } else {
                    raw = try await engine.transcribe(request) { reporter.report($0) }
                    fromCache = false
                    try Task.checkCancellation()
                    if (try? SpeechRawCacheEntry.read(url))?.key != key {
                        let entry = SpeechRawCacheEntry(key: key, raw: raw, providerResponse: nil)
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try? entry.write(url)
                    }
                }
            }
            reporter.report(TranscriptionProgress(stage: .aligning, fraction: 0))
            let grouped = try WordAssembler.group(raw.tokens, rule: raw.grouping, timelineStart: request.audio.timelineStart)
            let imported = try SpeechEditingImportAdapter.pipeline(grouped, envelope: envelope, timing: raw.timing, verbatim: raw.verbatim, duration: request.audio.durationSeconds)
            let words = imported.words
            guard words.contains(where: { $0.kind == .word }) else { throw VoxClipError.noSpeech }
            let refined = imported.refined
            try Task.checkCancellation()
            let result = Transcript(words: words, language: raw.language, languageProbability: raw.languageProbability, durationSeconds: request.audio.durationSeconds, engine: raw.engine, verbatim: raw.verbatim, refined: refined, rawKey: rawKey, createdAt: Date())
            reporter.report(TranscriptionProgress(stage: .aligning, fraction: 1))
            await reporter.finish()
            delivery.continuation.finish()
            await publishing.value
            await gate.release(local: local, key: gateKey)
            return TranscriptionResult(transcript: result, fromCache: fromCache)
        } catch {
            await gate.release(local: local, key: gateKey)
            if Task.isCancelled || error is CancellationError { throw VoxClipError.cancelled }
            throw error
        }
    }
    public func progress() -> AsyncStream<TranscriptionProgress> {
        let identifier = UUID()
        let pair = AsyncStream<TranscriptionProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[identifier] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(identifier) } }
        return pair.stream
    }
    private func publish(_ value: TranscriptionProgress, job: UUID) {
        guard active, job == generation else { return }
        for observer in observers.values { observer.yield(value) }
    }
    private func removeObserver(_ identifier: UUID) { observers.removeValue(forKey: identifier) }
}
extension TranscriptionOptions: Hashable {}
extension TranscriptionPlan: Hashable {}
