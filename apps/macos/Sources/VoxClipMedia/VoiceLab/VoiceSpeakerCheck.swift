import Foundation
import VoxClipCore

public final class VoiceSpeakerCheck: Sendable {
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
    func supports(language: String) -> Bool { available && (calibratedLanguage == nil || calibratedLanguage == language) }
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
        let record = try await store.load(recordID)
        guard quote.operation == .textToSpeech || quote.operation == .voiceChange else { throw VoiceLabError.consentRequired }
        let expected = quote.operation == .textToSpeech ? "v1/text-to-speech/\(record.voiceId)/with-timestamps" : "v1/voice-changer/\(record.voiceId)"
        guard quote.endpoint == expected else { throw VoiceLabError.consentRequired }
        let policy = try await authorize(contentKey: contentKey, recordID: recordID, speech16k: speech16k, voiceChanger: quote.operation == .voiceChange, approved: approved)
        let store = store; let embedder = check.embedder
        return policy.authorized(for: quote) {
            try await embedder?.validateAvailability()
            try await store.validateUse(record)
        }
    }
}
