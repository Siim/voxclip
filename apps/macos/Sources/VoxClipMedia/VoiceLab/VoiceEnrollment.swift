import Foundation
import VoxClipCore

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
    private let reconciler: VoiceOperationReconciler
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
    public init(store: VoiceConsentStore, client: ElevenLabsVoiceLab, speaker: VoiceSpeakerCheck = VoiceSpeakerCheck(), reconciler: VoiceOperationReconciler? = nil, transcribe: @escaping Transcribe) {
        self.store = store; self.client = client; self.speaker = speaker; self.transcribe = transcribe
        self.reconciler = reconciler ?? VoiceOperationReconciler(store: store, client: client)
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
        let store = store; let embedder = speaker.embedder; let statementHash = verification.hash
        let authorization = policy.authorized(for: quote) {
            try await embedder?.validateAvailability()
            try await store.dispatchCreation(recordID: recordID, requestID: quote.requestID, statementHash: statementHash)
            try await store.validateCreation(recordID: recordID, requestID: quote.requestID, statementHash: statementHash)
        }
        pending.removeAll()
        pending[quote.id] = Pending(request: request, policy: authorization, verified: verification, samples: hashes, embedding: owner)
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
        let operation = try await store.beginCreation(record: template, requestID: quote.requestID, region: client.region, at: Date())
        guard await store.claimOperation(operation.id) else { throw VoiceConsentError.creationPending }
        let result: VoiceLabCloneResult
        do {
            result = try await client.createOwnClone(draft.request, policy: draft.policy, requestID: quote.requestID, authorization: .init(quote: quote, approved: true))
        } catch {
            await store.releaseOperation(operation.id)
            try await store.discardStatement(recordID: template.id)
            if let current = try? await store.operation(operation.id), current.state == .intent {
                try await reconciler.reconcile(operationID: operation.id, force: true)
                throw error
            }
            try await store.scheduleRetry(operation.id, at: Date())
            throw VoiceConsentError.creationPending
        }
        let record = template.assigningVoice(result.voiceID, requiresVerification: result.requiresVerification)
        verified.removeValue(forKey: record.id)
        do {
            _ = try await store.transition(operation.id, to: .created, at: Date(), remoteVoiceID: result.voiceID, requiresVerification: result.requiresVerification)
            await store.releaseOperation(operation.id)
            try await reconciler.reconcile(operationID: operation.id, force: true)
        } catch {
            await store.releaseOperation(operation.id)
            throw VoiceConsentSaveError(record: record)
        }
        return record
    }
    public func delete(recordID: String, approved: Bool, enabled: Bool, now: Date = Date()) async throws {
        guard enabled, approved else { throw VoiceLabError.consentRequired }
        guard !busy else { throw VoiceLabError.invalidInput }
        busy = true; defer { busy = false }
        let operation = try await store.beginDeletion(recordID, region: client.region, at: now)
        try await reconciler.reconcile(operationID: operation.id, force: true)
    }
    public func cancel(recordID: String) async throws {
        guard !busy else { throw VoiceLabError.invalidInput }
        verified.removeValue(forKey: recordID)
        pending.removeAll()
        try await store.abandonEnrollment(recordID: recordID)
    }
}
