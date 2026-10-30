import Foundation
import VoxClipCore

struct VoiceSpeakerMatch: Sendable {
    let recordID: String
    let cloneVoiceID: String?
    private let store: VoiceConsentStore
    private let record: VoiceConsentRecord?
    private let statementHash: String
    private let embedder: any SpeakerEmbedder
    fileprivate init(recordID: String, cloneVoiceID: String?, store: VoiceConsentStore, record: VoiceConsentRecord?, statementHash: String, embedder: any SpeakerEmbedder) {
        self.recordID = recordID; self.cloneVoiceID = cloneVoiceID; self.store = store; self.record = record
        self.statementHash = statementHash; self.embedder = embedder
    }
    func capability(for quote: VoiceLabQuote) throws -> VoiceOperationCapability {
        if let record {
            let endpoint = quote.operation == .textToSpeech ? "v1/text-to-speech/\(record.voiceId)/with-timestamps" : "v1/voice-changer/\(record.voiceId)"
            guard [.textToSpeech, .voiceChange].contains(quote.operation), quote.endpoint == endpoint else { throw VoiceLabError.consentRequired }
            return VoiceOperationCapability(quote: quote, reserve: { try await store.dispatchPermit(record, requestID: quote.requestID) }) {
                try await embedder.validateAvailability()
                try await store.validateUse(record)
            }
        }
        guard quote.operation == .createClone else { throw VoiceLabError.consentRequired }
        return VoiceOperationCapability(quote: quote, reserve: {
            try await store.creationDispatchPermit(recordID: recordID, requestID: quote.requestID, statementHash: statementHash)
        }) {
            try await embedder.validateAvailability()
            try await store.dispatchCreation(recordID: recordID, requestID: quote.requestID, statementHash: statementHash)
            try await store.validateCreation(recordID: recordID, requestID: quote.requestID, statementHash: statementHash)
        }
    }
}

public final class VoiceSpeakerCheck: Sendable {
    func match(store: VoiceConsentStore, recordID: String, speech16k: [Float]) async throws -> VoiceSpeakerMatch {
        let record = try await store.load(recordID)
        try await store.validateUse(record)
        guard supports(language: record.statement.language), embedder?.modelID == record.speaker.model,
              threshold == record.speaker.threshold, let owner = VoiceConsentRecord.decodeEmbedding(record.speaker.embedding) else { throw VoiceConsentError.speakerUnavailable }
        let candidate = try await embedding(speech16k)
        guard try Self.cosine(owner, candidate) >= record.speaker.threshold else { throw VoiceConsentError.voiceOwnerMismatch }
        try await store.validateUse(record)
        guard let embedder else { throw VoiceConsentError.speakerUnavailable }
        return VoiceSpeakerMatch(recordID: record.id, cloneVoiceID: record.voiceId, store: store, record: record, statementHash: record.statement.audioSha256, embedder: embedder)
    }
    func enrollmentMatch(store: VoiceConsentStore, recordID: String, language: String, statement: Data, sample: Data) async throws -> VoiceSpeakerMatch {
        guard supports(language: language), let threshold, let embedder else { throw VoiceConsentError.speakerUnavailable }
        let owner = try await embedding(VoiceConsentAudio.pcm16k(statement))
        let candidate = try await embedding(VoiceConsentAudio.pcm16k(sample))
        guard try Self.cosine(owner, candidate) >= threshold else { throw VoiceConsentError.speakerMismatch }
        return VoiceSpeakerMatch(recordID: recordID, cloneVoiceID: nil, store: store, record: nil, statementHash: VoiceLabFingerprint.bytes(statement), embedder: embedder)
    }
    private let production: ONNXSpeakerEmbedder?
    private let calibratedLanguage: String?
    public let threshold: Double?
    #if DEBUG
    private let testing: (any SpeakerEmbedder)?
    #endif
    public static let unavailable = VoiceSpeakerCheck(verifiedModel: nil, trustedEntry: nil, language: nil)
    private init(verifiedModel: ONNXSpeakerEmbedder?, trustedEntry: SpeakerModel?, language: String?) {
        production = verifiedModel; calibratedLanguage = language
        threshold = language.flatMap { trustedEntry?.calibratedThreshold(language: $0) }
        #if DEBUG
        testing = nil
        #endif
    }
    static func make(verifiedModel: ONNXSpeakerEmbedder, trustedEntry: SpeakerModel, language: String) async throws -> VoiceSpeakerCheck {
        let canonical = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(trustedEntry) == encoder.encode(canonical),
              canonical.calibratedThreshold(language: language) != nil else { throw VoiceConsentError.speakerUnavailable }
        try await verifiedModel.validateIdentity(trustedEntry: canonical)
        return VoiceSpeakerCheck(verifiedModel: verifiedModel, trustedEntry: canonical, language: language)
    }
    #if DEBUG
    @_spi(Testing) public init(embedder: (any SpeakerEmbedder)?, calibratedThreshold: Double? = nil, language: String? = nil) {
        production = nil; testing = embedder; threshold = calibratedThreshold; calibratedLanguage = language
    }
    #endif
    public var embedder: (any SpeakerEmbedder)? {
        #if DEBUG
        production ?? testing
        #else
        production
        #endif
    }
    public var available: Bool { embedder != nil && threshold.map { $0.isFinite && (0...1).contains($0) } == true }
    func supports(language: String) -> Bool {
        VoiceLabGate.canCheckOwnVoice(speakerAvailable: available, calibratedThreshold: threshold, language: language) &&
            (calibratedLanguage == nil || calibratedLanguage == language)
    }
    public func embedding(_ pcm16k: [Float]) async throws -> [Float] {
        guard available, let embedder else { throw VoiceConsentError.speakerUnavailable }
        return try await SpeakerAudio.embedding(pcm16k, using: embedder)
    }
    public static func cosine(_ left: [Float], _ right: [Float]) throws -> Double { try SpeakerAudio.cosine(left, right) }
}

public actor VoiceUseGuard {
    private let store: VoiceConsentStore
    private let check: VoiceSpeakerCheck
    private var cache: Set<String> = []
    private var proofs: [String: VoiceSpeakerMatch] = [:]
    public init(store: VoiceConsentStore, check: VoiceSpeakerCheck = .unavailable) { self.store = store; self.check = check }
    func authorize(contentKey: String, recordID: String, speech16k: [Float], voiceChanger: Bool = false, approved: Bool) async throws -> OwnVoicePolicy {
        guard approved else { throw VoiceLabError.consentRequired }
        guard !contentKey.isEmpty else { throw VoiceLabError.invalidInput }
        let record = try await store.load(recordID)
        try await store.validateUse(record)
        guard check.supports(language: record.statement.language), check.embedder?.modelID == record.speaker.model, check.threshold == record.speaker.threshold,
              let owner = VoiceConsentRecord.decodeEmbedding(record.speaker.embedding) else { throw VoiceConsentError.speakerUnavailable }
        let audioHash = speech16k.withUnsafeBytes { VoiceLabFingerprint.bytes(Data($0)) }
        let key = VoiceLabFingerprint.fields([contentKey, audioHash, String(voiceChanger), recordID, record.speaker.embedding, record.statement.audioSha256])
        try await check.embedder?.validateAvailability()
        if !cache.contains(key) {
            let maximum = voiceChanger ? 480_000 : 160_000
            let candidate = try await check.embedding(Array(speech16k.prefix(maximum)))
            guard try VoiceSpeakerCheck.cosine(owner, candidate) >= record.speaker.threshold else {
                throw VoiceConsentError.voiceOwnerMismatch
            }
            try await store.validateUse(record)
            if cache.count >= 256 { cache.removeAll() }
            cache.insert(key)
        }
        return OwnVoicePolicy(recordID: recordID, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
    }
    public func authorize(quote: VoiceLabQuote, contentKey: String, recordID: String, speech16k: [Float], approved: Bool) async throws -> OwnVoicePolicy {
        guard quote.operation == .textToSpeech else { throw VoiceLabError.consentRequired }
        return try await authorizeBoundQuote(quote, contentKey: contentKey, recordID: recordID, speech16k: speech16k, approved: approved)
    }
    public func authorizeConversion(quote: VoiceLabQuote, contentKey: String, recordID: String, audio: Data, approved: Bool) async throws -> OwnVoicePolicy {
        guard quote.operation == .voiceChange, quote.guardAudioHash == VoiceLabFingerprint.bytes(audio) else { throw VoiceLabError.consentRequired }
        return try await authorizeBoundQuote(quote, contentKey: contentKey, recordID: recordID, speech16k: VoiceConsentAudio.pcm16k(audio), approved: approved)
    }
    private func authorizeBoundQuote(_ quote: VoiceLabQuote, contentKey: String, recordID: String, speech16k: [Float], approved: Bool) async throws -> OwnVoicePolicy {
        guard approved, !contentKey.isEmpty else { throw VoiceLabError.consentRequired }
        let record = try await store.load(recordID)
        guard quote.operation == .textToSpeech || quote.operation == .voiceChange else { throw VoiceLabError.consentRequired }
        let expected = quote.operation == .textToSpeech ? "v1/text-to-speech/\(record.voiceId)/with-timestamps" : "v1/voice-changer/\(record.voiceId)"
        guard quote.endpoint == expected else { throw VoiceLabError.consentRequired }
        try await store.validateUse(record)
        try await check.embedder?.validateAvailability()
        let audioHash = speech16k.withUnsafeBytes { VoiceLabFingerprint.bytes(Data($0)) }
        let key = VoiceLabFingerprint.fields([contentKey, audioHash, recordID, record.speaker.embedding, record.statement.audioSha256, record.voiceId, record.speaker.model, String(record.speaker.threshold)])
        let proof: VoiceSpeakerMatch
        if let cached = proofs[key] { proof = cached }
        else {
            proof = try await check.match(store: store, recordID: recordID, speech16k: Array(speech16k.prefix(quote.operation == .voiceChange ? 480_000 : 160_000)))
            if proofs.count >= 256 { proofs.removeAll() }
            proofs[key] = proof
        }
        try await store.validateUse(record)
        let policy = OwnVoicePolicy(recordID: record.id, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        return try policy.authorized(for: quote, proof: proof)
    }
}
