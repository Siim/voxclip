import Foundation

public struct VoiceConsentSaveError: Error, Sendable {
    public let record: VoiceConsentRecord
}

public struct VoiceTrainingSample: Sendable {
    public let wav: Data
    public let speech16k: [Float]
    public let seconds: Double
    public let source: String
    public let snrDb: Double
    public init(wav: Data, speech16k: [Float], seconds: Double, source: String, snrDb: Double) {
        self.wav = wav; self.speech16k = speech16k; self.seconds = seconds; self.source = source; self.snrDb = snrDb
    }
}

public actor VoiceEnrollment {
    public typealias Transcribe = @Sendable (Data, String) async throws -> RawTranscript
    private let store: VoiceConsentStore
    private let client: ElevenLabsVoiceLab
    private var speaker: VoiceSpeakerCheck
    private let transcribe: Transcribe
    private var attempts: [Date] = []
    private var verified: [String: Verified] = [:]
    private var pending: [UUID: Pending] = [:]
    private var busy = false
    private struct Verified: Sendable {
        let statement: VoiceConsentStatement
        let match: VoiceStatementMatch
        let hash: String
        let attestations: VoiceConsentRecord.Attestations
    }
    private struct Pending: Sendable {
        let request: VoiceLabCloneRequest
        let policy: OwnVoicePolicy
        let verified: Verified
        let samples: [VoiceConsentRecord.Sample]
        let embedding: [Float]
    }
    public init(store: VoiceConsentStore, client: ElevenLabsVoiceLab, speaker: VoiceSpeakerCheck = VoiceSpeakerCheck(), transcribe: @escaping Transcribe) {
        self.store = store; self.client = client; self.speaker = speaker; self.transcribe = transcribe
    }
    public var speakerAvailable: Bool { speaker.available }
    public func setSpeakerCheck(_ check: VoiceSpeakerCheck) throws {
        guard !busy else { throw VoiceLabError.invalidInput }
        if speaker.embedder?.modelID != check.embedder?.modelID || speaker.threshold != check.threshold { pending.removeAll() }
        speaker = check
    }
    public func verify(recordID: String, statement: VoiceConsentStatement, wav: Data, attestations: VoiceConsentRecord.Attestations,
                       approved: Bool, enabled: Bool, now: Date = Date()) async throws {
        guard approved, enabled else { throw VoiceLabError.consentRequired }
        guard attestations.complete else { throw VoiceConsentError.attestationsRequired }
        guard !busy else { throw VoiceLabError.invalidInput }
        attempts.removeAll { now.timeIntervalSince($0) >= 600 }
        guard attempts.count < 3 else { throw VoiceConsentError.tooManyAttempts }
        busy = true; defer { busy = false }
        verified.removeValue(forKey: recordID)
        try await store.saveStatement(wav, recordID: recordID)
        attempts.append(now)
        let result = try await transcribe(wav, statement.language)
        let match = try VoiceStatementMatch.verify(result, statement: statement)
        verified[recordID] = Verified(statement: statement, match: match, hash: VoiceLabFingerprint.bytes(wav), attestations: attestations)
    }
    public func prepare(recordID: String, displayName: String, samples: [VoiceTrainingSample],
                        enabled: Bool, now: Date = Date()) async throws -> VoiceLabQuote {
        guard enabled else { throw VoiceLabError.consentRequired }
        guard !busy else { throw VoiceLabError.invalidInput }
        guard speaker.available, let threshold = speaker.threshold else { throw VoiceConsentError.speakerUnavailable }
        guard let verification = verified[recordID] else { throw VoiceLabError.consentRequired }
        guard samples.count <= 24, !samples.isEmpty,
              samples.allSatisfy({ $0.seconds.isFinite && (5...30).contains($0.seconds) && ["readAloud", "project"].contains($0.source) && $0.snrDb.isFinite }),
              (60...120).contains(samples.reduce(0) { $0 + $1.seconds }) else { throw VoiceLabError.invalidInput }
        busy = true; defer { busy = false }
        let statementWAV = try await store.statement(recordID: recordID)
        guard VoiceLabFingerprint.bytes(statementWAV) == verification.hash else { throw VoiceConsentError.invalidRecord }
        let owner = try await speaker.embedding(VoiceConsentAudio.pcm16k(statementWAV))
        var accepted: [VoiceTrainingSample] = []
        var hashes: [VoiceConsentRecord.Sample] = []
        for sample in samples {
            let format = try ElevenLabsVoiceLab.validateWAV(sample.wav, maxBytes: 16 * 1_024 * 1_024)
            guard abs(Double(format.frames) / Double(format.rate) - sample.seconds) < 0.001 else { throw VoiceLabError.invalidAudio }
            let candidate: [Float]
            do { candidate = try await speaker.embedding(VoiceConsentAudio.pcm16k(sample.wav)) }
            catch VoiceConsentError.speakerMismatch { continue }
            let score = try VoiceSpeakerCheck.cosine(owner, candidate)
            if score >= threshold {
                accepted.append(sample)
                hashes.append(.init(sha256: VoiceLabFingerprint.bytes(sample.wav), seconds: sample.seconds, source: sample.source, speakerScore: score))
            }
        }
        guard !accepted.isEmpty, accepted.reduce(0.0, { $0 + $1.seconds }) >= 10 else { throw VoiceConsentError.speakerMismatch }
        let name = try VoiceConsentText.displayName(displayName)
        let prefix = verification.statement.language == "et" ? "Minu nimi on \(name). Täna on " : "My name is \(name). Today is "
        guard verification.statement.text.hasPrefix(prefix) else { throw VoiceLabError.consentRequired }
        let request = VoiceLabCloneRequest(displayName: name, language: verification.statement.language,
                                          samples: [.init(role: .consentStatement, wav: statementWAV)] + accepted.map { .init(role: .training, wav: $0.wav) },
                                          createdAt: now, removeBackgroundNoise: accepted.contains { $0.snrDb < 20 }, recoveryNonce: recordID)
        let policy = OwnVoicePolicy(recordID: recordID, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let quote = try await client.prepareClone(request, policy: policy, requestID: UUID())
        pending.removeAll()
        pending[quote.id] = Pending(request: request, policy: policy, verified: verification, samples: hashes, embedding: owner)
        return quote
    }
    public func create(quote: VoiceLabQuote, approved: Bool, enabled: Bool, appVersion: String) async throws -> VoiceConsentRecord {
        guard enabled, approved else { throw VoiceLabError.consentRequired }
        guard speaker.available, let threshold = speaker.threshold, let embedder = speaker.embedder else { throw VoiceConsentError.speakerUnavailable }
        guard !busy, let draft = pending.removeValue(forKey: quote.id) else { throw VoiceLabError.invalidInput }
        busy = true; defer { busy = false }
        try await embedder.validateAvailability()
        guard VoiceLabFingerprint.bytes(try await store.statement(recordID: draft.policy.recordID)) == draft.verified.hash else { throw VoiceConsentError.invalidRecord }
        let statement = draft.verified.statement
        let template = VoiceConsentRecord(schema: "voxclip-consent/1", recordId: draft.policy.recordID, provider: "elevenlabs", type: "ivc",
                                        voiceId: "pending", voiceName: draft.request.displayName + " (VoxClip)", status: .verificationRequired,
                                        createdAt: VoiceConsentRecord.timestamp(draft.request.createdAt), deletedAt: nil,
                                        statement: .init(language: statement.language, text: statement.text, nonce: statement.nonce, audioFile: "statement.wav", audioSha256: draft.verified.hash, stt: draft.verified.match),
                                        attestations: draft.verified.attestations, samples: draft.samples,
                                        speaker: .init(model: embedder.modelID, threshold: threshold, embedding: VoiceConsentRecord.encodeEmbedding(draft.embedding)), app: .init(version: appVersion, platform: "macos"))
        try await store.beginCreation(.init(requestID: quote.requestID, region: client.region, startedAt: Date(), record: template))
        let result: VoiceLabCloneResult
        do { result = try await client.createOwnClone(draft.request, policy: draft.policy, requestID: quote.requestID, authorization: .init(quote: quote, approved: true)) }
        catch let error as VoiceConsentError {
            try await store.removeJournal("creation.json", recordID: template.id)
            throw error
        } catch let error as VoiceLabError where Self.definitiveRejection(error) {
            try await store.removeJournal("creation.json", recordID: template.id)
            throw error
        }
        catch { throw VoiceConsentError.creationPending }
        let record = template.assigningVoice(result.voiceID, requiresVerification: result.requiresVerification)
        verified.removeValue(forKey: record.id)
        do { try await store.recordCreationResult(record); try await store.completeCreation(record) }
        catch { throw VoiceConsentSaveError(record: record) }
        return record
    }
    private static func definitiveRejection(_ error: VoiceLabError) -> Bool {
        switch error {
        case .missingKey, .consentRequired, .planUnavailable, .noVoiceSlots, .invalidInput, .permissionMissing, .unauthorized, .quotaExceeded, .rateLimited: true
        default: false
        }
    }
    public static func reconcileCreations(store: VoiceConsentStore, client: ElevenLabsVoiceLab) async throws {
        let pending = try await store.pendingCreations().filter { $0.region == client.region }
        guard !pending.isEmpty else { return }
        let voices = try await client.listOwnClones()
        var failure: (any Error)?
        for intent in pending {
            do {
                let matches = voices.filter { $0.consentRecordID == intent.record.id || (intent.record.voiceId != "pending" && $0.id == intent.record.voiceId) }
                guard matches.count == 1, let voice = matches.first else { throw VoiceConsentError.creationPending }
                let record = intent.record.assigningVoice(voice.id, requiresVerification: voice.requiresVerification && !voice.isVerified)
                let statementValid = (try? await store.statement(recordID: record.id)).map { VoiceLabFingerprint.bytes($0) == record.statement.audioSha256 } == true
                let existing = try? await store.load(record.id)
                let deleting = await store.hasDeletion(record.id)
                if intent.cancelled != true && statementValid && existing?.status != .deleted && !deleting {
                    try await store.recordCreationResult(record)
                    try await store.completeCreation(record)
                } else {
                    let deletion = try await store.deleteRecoveredCreation(record, region: client.region)
                    try await resumeDeletion(deletion, store: store, client: client)
                    try await store.removeJournal("creation.json", recordID: record.id)
                }
            } catch { failure = error }
        }
        if let failure { throw failure }
    }
    public func delete(recordID: String, approved: Bool, enabled: Bool, now: Date = Date()) async throws {
        guard enabled, approved else { throw VoiceLabError.consentRequired }
        guard !busy else { throw VoiceLabError.invalidInput }
        busy = true; defer { busy = false }
        let intent = try await store.beginDeletion(recordID, region: client.region, at: now)
        try await Self.resumeDeletion(intent, store: store, client: client)
    }
    public static func resumeDeletions(store: VoiceConsentStore, client: ElevenLabsVoiceLab) async throws {
        var failure: (any Error)?
        for intent in try await store.pendingDeletions() where intent.region == client.region {
            do { try await resumeDeletion(intent, store: store, client: client) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }
    private static func resumeDeletion(_ intent: VoiceDeletionIntent, store: VoiceConsentStore, client: ElevenLabsVoiceLab) async throws {
        var intent = intent
        if !intent.remoteDeleted {
            let record = intent.record
        let requestID = UUID()
        let quote = try await client.prepareConsentDeletion(record, requestID: requestID)
        let policy = OwnVoicePolicy(recordID: record.id, cloneVoiceID: record.voiceId, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        _ = try await client.deleteOwnClone(voiceID: record.voiceId, policy: policy, requestID: requestID, authorization: .init(quote: quote, approved: true))
            intent = try await store.recordRemoteDeletion(intent)
        }
        try await store.finishDeletion(intent)
    }
    public func cancel(recordID: String) async throws {
        guard !busy else { throw VoiceLabError.invalidInput }
        verified.removeValue(forKey: recordID)
        pending.removeAll()
        try await store.abandonEnrollment(recordID: recordID)
    }
}
