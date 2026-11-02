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

/// UI seam for V16/V17: prepare locally, present quote.estimate, then execute after one click.
public struct VoiceEnrollmentPlan: Sendable, Equatable {
    public let recordID: String
    public let quote: EnrollmentQuote
    public let trainingSeconds: Double
    public let verificationPassed: Bool
    public var consentMethod: VoiceConsentRecord.ConsentMethod { quote.consentMethod }
    public let isRecovery: Bool
    init(recordID: String, quote: EnrollmentQuote, trainingSeconds: Double, verificationPassed: Bool, isRecovery: Bool = false) {
        self.recordID = recordID; self.quote = quote; self.trainingSeconds = trainingSeconds
        self.verificationPassed = verificationPassed; self.isRecovery = isRecovery
    }
}

public actor VoiceEnrollment {
    public typealias Transcribe = @Sendable (Data, String) async throws -> RawTranscript
    private let store: VoiceConsentStore
    private let client: ElevenLabsVoiceLab
    private var speaker: VoiceSpeakerCheck
    private let reconciler: VoiceOperationReconciler
    private let transcribe: Transcribe?
    private var attempts: [String: Date] = [:]
    private var pending: [UUID: Pending] = [:]
    private var busy = false
    private var plans: [UUID: VoiceEnrollmentPlan] = [:]
    private struct Verified: Sendable {
        let statement: VoiceConsentStatement?
        let match: VoiceStatementMatch?
        let hash: String
        let attestations: VoiceConsentRecord.Attestations
        var projectConsent: VoiceConsentRecord.ProjectConsent? = nil
        var creatorFingerprint: String? = nil
        var language: String { projectConsent?.language ?? statement?.language ?? "" }
    }
    private struct Pending: Sendable {
        let request: VoiceLabCloneRequest
        let policy: OwnVoicePolicy
        let verified: Verified
        let samples: [VoiceConsentRecord.Sample]
        let trainingSeconds: Double
        let embedding: [Float]
    }
    public init(store: VoiceConsentStore, client: ElevenLabsVoiceLab, speaker: VoiceSpeakerCheck = .unavailable, reconciler: VoiceOperationReconciler? = nil) {
        self.store = store; self.client = client; self.speaker = speaker; self.transcribe = nil
        self.reconciler = reconciler ?? VoiceOperationReconciler(store: store, client: client)
    }
    #if DEBUG
    public init(store: VoiceConsentStore, client: ElevenLabsVoiceLab, speaker: VoiceSpeakerCheck = .unavailable, reconciler: VoiceOperationReconciler? = nil, transcribe: @escaping Transcribe) {
        self.store = store; self.client = client; self.speaker = speaker; self.transcribe = transcribe
        self.reconciler = reconciler ?? VoiceOperationReconciler(store: store, client: client)
    }
    #endif
    public var speakerAvailable: Bool { speaker.available }
    public func setSpeakerCheck(_ check: VoiceSpeakerCheck) throws {
        guard !busy else { throw VoiceLabError.invalidInput }
        if speaker.embedder?.modelID != check.embedder?.modelID || speaker.threshold != check.threshold { pending.removeAll(); plans.removeAll() }
        speaker = check
    }

    /// Local only: save the live statement, run every speaker check, then fix both billable requests.
    public func preparePlan(recordID: String, statement: VoiceConsentStatement, wav: Data,
                            attestations: VoiceConsentRecord.Attestations, displayName: String,
                            samples: [VoiceTrainingSample], enabled: Bool, now: Date = Date()) async throws -> VoiceEnrollmentPlan {
        guard enabled else { throw VoiceLabError.consentRequired }
        guard attestations.complete else { throw VoiceConsentError.attestationsRequired }
        guard speaker.supports(language: statement.language) else { throw VoiceConsentError.speakerUnavailable }
        guard !busy else { throw VoiceLabError.invalidInput }
        let attempt = try statementAttempt(statement: statement, wav: wav, now: now)
        busy = true; defer { busy = false }
        pending.removeAll(); plans.removeAll()
        try await store.validateEnrollmentStart(recordID: recordID)
        try await store.clearEnrollmentRecovery(recordID: recordID)
        try await store.saveStatement(wav, recordID: recordID)
        if attempts[attempt] == nil { attempts[attempt] = now }
        let verification = Verified(statement: statement, match: nil, hash: VoiceLabFingerprint.bytes(wav), attestations: attestations)
        let create = try await prepareDraft(recordID: recordID, displayName: displayName, samples: samples,
                                            verification: verification, now: now)
        let verify = try await client.prepareConsentVerification(wav: wav, language: statement.language, requestID: UUID())
        let draft = pending[create.id]!
        let quote = try EnrollmentQuote(verify: verify, create: create, request: draft.request, statement: statement)
        let plan = VoiceEnrollmentPlan(recordID: recordID, quote: quote, trainingSeconds: draft.trainingSeconds, verificationPassed: false)
        plans[quote.id] = plan
        return plan
    }

    public func prepareProjectPlan(recordID: String, language: String, attestations: VoiceConsentRecord.Attestations,
                                   displayName: String, samples: [VoiceTrainingSample], enabled: Bool,
                                   now: Date = Date()) async throws -> VoiceEnrollmentPlan {
        guard enabled else { throw VoiceLabError.consentRequired }
        guard attestations.complete else { throw VoiceConsentError.attestationsRequired }
        guard speaker.supports(language: language), let threshold = speaker.threshold else { throw VoiceConsentError.speakerUnavailable }
        guard !busy else { throw VoiceLabError.invalidInput }
        busy = true; defer { busy = false }
        pending.removeAll(); plans.removeAll()
        try await store.validateEnrollmentStart(recordID: recordID)
        let name = try VoiceConsentText.displayName(displayName)
        func total(_ list: [VoiceTrainingSample]) -> Double {
            Double(list.reduce(0) { $0 + Int(($1.seconds * 1_000 + 0.5).rounded(.down)) }) / 1_000
        }
        guard !samples.isEmpty, samples.count <= 24,
              samples.allSatisfy({ $0.source == "project" && $0.seconds.isFinite && (5...30).contains($0.seconds) && $0.snrDb.isFinite }),
              (30...120).contains(total(samples)) else { throw VoiceLabError.invalidInput }
        var accepted: [VoiceTrainingSample] = []
        var hashes: [VoiceConsentRecord.Sample] = []
        var owner: [Float]?
        for sample in samples {
            let format = try ElevenLabsVoiceLab.validateWAV(sample.wav, maxBytes: 16 * 1_024 * 1_024)
            guard abs(Double(format.frames) / Double(format.rate) - sample.seconds) < 0.001 else { throw VoiceLabError.invalidAudio }
            let candidate: (whole: [Float], parts: [[Float]])
            do { candidate = try await speaker.partEmbeddings(VoiceConsentAudio.pcm16k(sample.wav)) }
            catch VoiceConsentError.speakerMismatch { continue }
            let reference = owner ?? candidate.whole
            let score = try candidate.parts.reduce(VoiceSpeakerCheck.cosine(reference, candidate.whole)) {
                try min($0, VoiceSpeakerCheck.cosine(reference, $1))
            }
            guard score >= threshold else { continue }
            if owner == nil { owner = candidate.whole }
            accepted.append(sample)
            hashes.append(.init(sha256: VoiceLabFingerprint.bytes(sample.wav), seconds: sample.seconds, source: "project", speakerScore: score))
        }
        guard let owner, let reference = accepted.first, total(accepted) >= 30 else { throw VoiceConsentError.speakerMismatch }
        try await store.clearEnrollmentRecovery(recordID: recordID)
        try await store.saveReferenceAudio(reference.wav, recordID: recordID)
        let consent = VoiceConsentRecord.ProjectConsent(language: language, audioSha256: VoiceLabFingerprint.bytes(reference.wav))
        let verification = Verified(statement: nil, match: nil, hash: consent.audioSha256, attestations: attestations, projectConsent: consent)
        let request = VoiceLabCloneRequest(displayName: name, language: language,
                                          samples: accepted.map { .init(role: .training, wav: $0.wav) }, createdAt: now,
                                          removeBackgroundNoise: false, recoveryNonce: recordID)
        let policy = OwnVoicePolicy(recordID: recordID, recordActive: true, providerConsentGranted: true,
                                    statementVerified: false, speakerMatched: true, consentMethod: .projectAttestation)
        let create = try await client.prepareEnrollmentClone(request, policy: policy, requestID: UUID())
        let proof = try await speaker.projectEnrollmentMatch(store: store, recordID: recordID, language: language, samples: request.samples.map(\.wav))
        let draft = Pending(request: request, policy: try policy.authorized(for: create, proof: proof), verified: verification,
                            samples: hashes, trainingSeconds: total(accepted), embedding: owner)
        let quote = try EnrollmentQuote(create: create, request: request, projectConsent: consent, attestations: attestations)
        let plan = VoiceEnrollmentPlan(recordID: recordID, quote: quote, trainingSeconds: draft.trainingSeconds, verificationPassed: false)
        pending[quote.id] = draft; plans[quote.id] = plan
        return plan
    }

    /// The single paid approval. A failed plan check spends nothing; a failed Scribe check creates nothing.
    public func execute(_ plan: VoiceEnrollmentPlan, approved: Bool, enabled: Bool, appVersion: String) async throws -> VoiceConsentRecord {
        guard approved, enabled else { throw VoiceLabError.consentRequired }
        guard !busy, plans[plan.quote.id] == plan, var draft = pending[plan.quote.id] else { throw VoiceLabError.consentRequired }
        guard speaker.supports(language: draft.verified.language) else { throw VoiceConsentError.speakerUnavailable }
        busy = true; defer { busy = false }
        if let consent = draft.verified.projectConsent {
            try plan.quote.validate(request: draft.request, projectConsent: consent, attestations: draft.verified.attestations)
        } else {
            guard let statement = draft.verified.statement else { throw VoiceConsentError.invalidRecord }
            try plan.quote.validate(request: draft.request, statement: statement)
        }
        guard VoiceLabFingerprint.bytes(try await store.referenceAudio(recordID: plan.recordID)) == draft.verified.hash else { throw VoiceConsentError.invalidRecord }
        try await speaker.embedder?.validateAvailability()
        let quotes: [VoiceLabQuote]
        if plan.consentMethod == .projectAttestation || plan.verificationPassed { quotes = [plan.quote.create] }
        else {
            guard let verify = plan.quote.verify else { throw VoiceLabError.consentRequired }
            quotes = [verify, plan.quote.create]
        }
        guard await client.quotesAreFresh(quotes) else { throw VoiceLabError.consentRequired }
        let creator = try await client.validateCreationQuote(plan.quote.create) // Plan check precedes Scribe.
        if let fingerprint = draft.verified.creatorFingerprint {
            guard fingerprint == creator else { throw VoiceConsentError.creatorMismatch }
        }
        if plan.isRecovery {
            guard let recovery = try await store.enrollmentRecovery(recordID: plan.recordID), recovery.quote == plan.quote,
                  recovery.record.creator?.keyFingerprint == creator else { throw VoiceConsentError.creatorMismatch }
        }
        if plan.verificationPassed {
            if let fingerprint = draft.verified.creatorFingerprint {
                guard fingerprint == creator, draft.verified.match != nil else { throw VoiceConsentError.creatorMismatch }
            } else {
                guard let recovery = try await store.enrollmentRecovery(recordID: plan.recordID) else { throw VoiceConsentError.invalidRecord }
                guard recovery.record.creator?.keyFingerprint == creator, recovery.quote == plan.quote else { throw VoiceConsentError.creatorMismatch }
            }
        }
        try await client.approveRun(plan.quote.id, quotes: quotes)
        plans.removeValue(forKey: plan.quote.id); pending.removeValue(forKey: plan.quote.id)

        do {
            if plan.consentMethod == .recordedStatement && !plan.verificationPassed {
                let verification = try await verifyStatement(draft.verified, wav: draft.request.samples[0].wav, quote: plan.quote.verify)
                draft = Pending(request: draft.request, policy: draft.policy, verified: verification,
                                samples: draft.samples, trainingSeconds: draft.trainingSeconds, embedding: draft.embedding)
            }
            // Both entry points share the same durable boundary; a recovery never transcribes again.
            let template = try consentRecord(draft, appVersion: appVersion, creatorFingerprint: creator)
            try await store.saveEnrollmentRecovery(.init(quote: plan.quote, request: draft.request, record: template, trainingSeconds: draft.trainingSeconds))
            try Task.checkCancellation()
            guard try await client.creatorKeyFingerprint() == creator else { throw VoiceConsentError.creatorMismatch }
            let record = try await createPrepared(quote: plan.quote.create, draft: draft, appVersion: appVersion, creatorFingerprint: creator)
            await client.discardRun(plan.quote.id, quotes: quotes)
            return record
        } catch {
            // Leave an unsent create quote available to an explicit recovery action, without extending its deadline.
            await client.unapproveRun(plan.quote.id)
            throw error
        }
    }

    /// No network calls and no automatic retry. Present the returned quote, then call execute after a click.
    public func recoverPlan(recordID: String, enabled: Bool) async throws -> VoiceEnrollmentPlan {
        guard enabled else { throw VoiceLabError.consentRequired }
        guard !busy else { throw VoiceLabError.invalidInput }
        busy = true; defer { busy = false }
        guard let recovery = try await store.enrollmentRecovery(recordID: recordID) else { throw VoiceConsentError.invalidRecord }
        let record = recovery.record
        guard record.recordedRegion == client.region,
              record.creator?.keyFingerprint == (try await client.creatorKeyFingerprint()) else { throw VoiceConsentError.creatorMismatch }
        guard speaker.supports(language: record.language), speaker.embedder?.modelID == record.speaker.model,
              speaker.threshold == record.speaker.threshold, let embedding = VoiceConsentRecord.decodeEmbedding(record.speaker.embedding) else { throw VoiceConsentError.speakerUnavailable }
        let operations = try await store.operations().filter { $0.recordID == recordID }
        for operation in operations {
            if operation.state == .refused {
                try await store.discardUnresolvedDraft(operation)
                continue
            }
            guard operation.kind == .create, operation.state == .intent, !operation.wasDispatched,
                  await store.claimOperation(operation.id) else { throw VoiceConsentError.creationPending }
            do { try await store.discardUnsentCreation(operation.id) }
            catch { await store.releaseOperation(operation.id); throw error }
            await store.releaseOperation(operation.id)
        }
        let statement = record.statement.map { VoiceConsentStatement(language: $0.language, text: $0.text, nonce: $0.nonce) }
        let policy = OwnVoicePolicy(recordID: recordID, recordActive: true, providerConsentGranted: true,
                                    statementVerified: record.consentMethod == .recordedStatement, speakerMatched: true, consentMethod: record.consentMethod)
        let request = recovery.request
        let create: VoiceLabQuote
        if !operations.contains(where: { $0.state == .refused }),
           try await client.restoreEnrollmentCreation(recovery.quote.create, request: request, policy: policy) {
            create = recovery.quote.create
        } else {
            create = try await client.prepareEnrollmentClone(request, policy: policy, requestID: UUID())
        }
        let quote: EnrollmentQuote
        let proof: VoiceSpeakerMatch
        if let consent = record.projectConsent {
            quote = try EnrollmentQuote(create: create, request: request, projectConsent: consent, attestations: record.attestations)
            proof = try await speaker.projectEnrollmentMatch(store: store, recordID: recordID, language: request.language, samples: request.samples.map(\.wav))
        } else {
            guard let statement, request.samples.count >= 2 else { throw VoiceConsentError.invalidRecord }
            quote = try EnrollmentQuote(verify: nil, create: create, request: request, statement: statement)
            proof = try await speaker.enrollmentMatch(store: store, recordID: recordID, language: request.language,
                                                     statement: request.samples[0].wav, sample: request.samples[1].wav)
        }
        try await store.saveEnrollmentRecovery(.init(quote: quote, request: request, record: record, trainingSeconds: recovery.trainingSeconds))
        let draft = Pending(request: request, policy: try policy.authorized(for: quote.create, proof: proof),
                            verified: .init(statement: statement, match: record.statement?.stt, hash: record.referenceAudioSHA256,
                                            attestations: record.attestations, projectConsent: record.projectConsent, creatorFingerprint: record.creator?.keyFingerprint),
                            samples: record.samples, trainingSeconds: recovery.trainingSeconds, embedding: embedding)
        let plan = VoiceEnrollmentPlan(recordID: recordID, quote: quote, trainingSeconds: draft.trainingSeconds,
                                       verificationPassed: record.consentMethod == .recordedStatement, isRecovery: true)
        pending.removeAll(); plans.removeAll()
        pending[quote.id] = draft; plans[quote.id] = plan
        return plan
    }

    private func statementAttempt(statement: VoiceConsentStatement, wav: Data, now: Date) throws -> String {
        attempts = attempts.filter { now.timeIntervalSince($0.value) < 600 }
        let key = VoiceLabFingerprint.fields([VoiceLabFingerprint.bytes(wav)] + statement.nonce)
        guard attempts[key] != nil || attempts.count < 3 else { throw VoiceConsentError.tooManyAttempts }
        return key
    }

    /// The Scribe check under the combined approval, after the local speaker match.
    private func verifyStatement(_ draft: Verified, wav: Data, quote: VoiceLabQuote?) async throws -> Verified {
        guard let statement = draft.statement, draft.projectConsent == nil else { throw VoiceLabError.consentRequired }
        // Recheck the live statement embedding before its approved Scribe request.
        _ = try await speaker.embedding(VoiceConsentAudio.pcm16k(wav))
        let fingerprint = try await client.creatorKeyFingerprint()
        let raw: RawTranscript
        if let transcribe { raw = try await transcribe(wav, statement.language) }
        else {
            guard let quote else { throw VoiceLabError.consentRequired }
            raw = try await client.transcribeConsentStatement(wav: wav, language: statement.language,
                                                             authorization: .init(quote: quote, approved: true))
        }
        let match = try VoiceStatementMatch.verify(raw, statement: statement)
        guard try await client.creatorKeyFingerprint() == fingerprint else { throw VoiceConsentError.creatorMismatch }
        return Verified(statement: statement, match: match, hash: draft.hash, attestations: draft.attestations, creatorFingerprint: fingerprint)
    }

    private func prepareDraft(recordID: String, displayName: String, samples: [VoiceTrainingSample], verification: Verified,
                              now: Date) async throws -> VoiceLabQuote {
        guard speaker.available, let threshold = speaker.threshold else { throw VoiceConsentError.speakerUnavailable }
        guard let statement = verification.statement, verification.projectConsent == nil else { throw VoiceLabError.consentRequired }
        guard speaker.supports(language: statement.language) else { throw VoiceConsentError.speakerUnavailable }
        // §6.5–§6.6: one source per clone. A read-aloud lasts 60–120 s and keeps 10 s; project spans (§6.5.1) total
        // 30–120 s and must keep 30 s after the speaker match, with no refill from unselected spans. Project totals add
        // whole milliseconds, as the selection does, so a cut's sub-millisecond rounding cannot move a set across 30 s.
        let source = samples.first?.source
        let project = source == "project"
        func total(_ list: [VoiceTrainingSample]) -> Double {
            project ? Double(list.reduce(0) { $0 + Int(($1.seconds * 1_000 + 0.5).rounded(.down)) }) / 1_000 : list.reduce(0) { $0 + $1.seconds }
        }
        guard samples.count <= 24, !samples.isEmpty, source == "readAloud" || project,
              samples.allSatisfy({ $0.seconds.isFinite && (5...30).contains($0.seconds) && $0.source == source && $0.snrDb.isFinite }),
              (project ? 30...120 : 60...120).contains(total(samples)) else { throw VoiceLabError.invalidInput }
        let statementWAV = try await store.statement(recordID: recordID)
        guard VoiceLabFingerprint.bytes(statementWAV) == verification.hash else { throw VoiceConsentError.invalidRecord }
        let owner = try await speaker.embedding(VoiceConsentAudio.pcm16k(statementWAV))
        var accepted: [VoiceTrainingSample] = []
        var hashes: [VoiceConsentRecord.Sample] = []
        for sample in samples {
            let format = try ElevenLabsVoiceLab.validateWAV(sample.wav, maxBytes: 16 * 1_024 * 1_024)
            guard abs(Double(format.frames) / Double(format.rate) - sample.seconds) < 0.001 else { throw VoiceLabError.invalidAudio }
            let candidate: (whole: [Float], parts: [[Float]])
            do {
                let pcm = try VoiceConsentAudio.pcm16k(sample.wav)
                candidate = project ? try await speaker.partEmbeddings(pcm) : (try await speaker.embedding(pcm), [])
            } catch VoiceConsentError.speakerMismatch { continue }
            // Without speaker labels a project span can hold another voice beside the user's, and the mean of its windows
            // can still pass. Each part must pass on its own, and the span scores as its lowest part.
            let score = try candidate.parts.reduce(VoiceSpeakerCheck.cosine(owner, candidate.whole)) { try min($0, VoiceSpeakerCheck.cosine(owner, $1)) }
            if score >= threshold {
                accepted.append(sample)
                hashes.append(.init(sha256: VoiceLabFingerprint.bytes(sample.wav), seconds: sample.seconds, source: sample.source, speakerScore: score))
            }
        }
        guard !accepted.isEmpty, total(accepted) >= (project ? 30 : 10) else { throw VoiceConsentError.speakerMismatch }
        let name = try VoiceConsentText.displayName(displayName)
        let prefix = try VoiceConsentText(shared: SharedResources.locate()).statementOpening(name: name, language: statement.language)
        guard statement.text.hasPrefix(prefix) else { throw VoiceLabError.consentRequired }
        let request = VoiceLabCloneRequest(displayName: name, language: statement.language,
                                          samples: [.init(role: .consentStatement, wav: statementWAV)] + accepted.map { .init(role: .training, wav: $0.wav) },
                                          createdAt: now, removeBackgroundNoise: !project && accepted.contains { $0.snrDb < 20 }, recoveryNonce: recordID)
        let policy = OwnVoicePolicy(recordID: recordID, recordActive: true, providerConsentGranted: true, statementVerified: true, speakerMatched: true)
        let quote = try await client.prepareEnrollmentClone(request, policy: policy, requestID: UUID())
        let proof = try await speaker.enrollmentMatch(store: store, recordID: recordID, language: statement.language, statement: statementWAV, sample: accepted[0].wav)
        let authorization = try policy.authorized(for: quote, proof: proof)
        pending.removeAll(); plans.removeAll()
        pending[quote.id] = Pending(request: request, policy: authorization, verified: verification, samples: hashes, trainingSeconds: total(accepted), embedding: owner)
        return quote
    }
    private func createPrepared(quote: VoiceLabQuote, draft: Pending, appVersion: String, creatorFingerprint: String) async throws -> VoiceConsentRecord {
        guard let embedder = speaker.embedder else { throw VoiceConsentError.speakerUnavailable }
        try await embedder.validateAvailability()
        guard VoiceLabFingerprint.bytes(try await store.referenceAudio(recordID: draft.policy.recordID)) == draft.verified.hash else { throw VoiceConsentError.invalidRecord }
        let template = try consentRecord(draft, appVersion: appVersion, creatorFingerprint: creatorFingerprint)
        let operation = try await store.beginClaimedCreation(record: template, requestID: quote.requestID, region: client.region, at: Date())
        let record: VoiceConsentRecord
        do {
            record = try await createClaimed(draft, template: template, operation: operation, quote: quote)
        } catch {
            await store.releaseOperation(operation.id)
            if let current = try? await store.operation(operation.id), [.intent, .withdrawing].contains(current.state) {
                try await reconciler.reconcile(operationID: operation.id, force: true)
            }
            throw error
        }
        await store.releaseOperation(operation.id)
        do { try await reconciler.reconcile(operationID: operation.id, force: true) }
        catch { throw VoiceConsentSaveError(record: record) }
        return record
    }
    private func consentRecord(_ draft: Pending, appVersion: String, creatorFingerprint: String) throws -> VoiceConsentRecord {
        guard let threshold = speaker.threshold, let embedder = speaker.embedder else { throw VoiceLabError.consentRequired }
        if let consent = draft.verified.projectConsent {
            guard draft.verified.statement == nil, draft.verified.match == nil else { throw VoiceConsentError.invalidRecord }
            return VoiceConsentRecord(schema: "voxclip-consent/2", recordId: draft.policy.recordID, provider: "elevenlabs", type: "ivc",
                                      voiceId: "pending", voiceName: draft.request.displayName + " (VoxClip)", status: .verificationRequired,
                                      createdAt: VoiceConsentRecord.timestamp(draft.request.createdAt), deletedAt: nil, statement: nil,
                                      attestations: draft.verified.attestations, samples: draft.samples,
                                      speaker: .init(model: embedder.modelID, threshold: threshold, embedding: VoiceConsentRecord.encodeEmbedding(draft.embedding)),
                                      app: .init(version: appVersion, platform: "macos"), creator: .init(region: client.region, keyFingerprint: creatorFingerprint),
                                      projectConsent: consent)
        }
        guard let statement = draft.verified.statement, let match = draft.verified.match else { throw VoiceLabError.consentRequired }
        return VoiceConsentRecord(schema: "voxclip-consent/1", recordId: draft.policy.recordID, provider: "elevenlabs", type: "ivc",
                                        voiceId: "pending", voiceName: draft.request.displayName + " (VoxClip)", status: .verificationRequired,
                                        createdAt: VoiceConsentRecord.timestamp(draft.request.createdAt), deletedAt: nil,
                                        statement: .init(language: statement.language, text: statement.text, nonce: statement.nonce, audioFile: "statement.wav", audioSha256: draft.verified.hash, stt: match),
                                        attestations: draft.verified.attestations, samples: draft.samples,
                                        speaker: .init(model: embedder.modelID, threshold: threshold, embedding: VoiceConsentRecord.encodeEmbedding(draft.embedding)), app: .init(version: appVersion, platform: "macos"), creator: .init(region: client.region, keyFingerprint: creatorFingerprint))
    }
    private func createClaimed(_ draft: Pending, template: VoiceConsentRecord, operation: VoiceOperation, quote: VoiceLabQuote) async throws -> VoiceConsentRecord {
        let result: VoiceLabCloneResult
        do {
            result = try await client.createOwnClone(draft.request, policy: draft.policy, requestID: quote.requestID, authorization: .init(quote: quote, approved: true))
        } catch {
            if let current = try? await store.operation(operation.id), current.state == .intent {
                try await store.discardUnsentCreation(operation.id)
                throw error
            }
            if let refusal = VoiceOperation.CreationRefusal(error: error) {
                let settled = try await store.refuseCreation(operation.id, refusal: refusal, at: Date())
                try? await store.discardUnresolvedDraft(settled)
                throw error
            }
            try await store.clearEnrollmentRecovery(recordID: template.id)
            try await store.discardStatement(recordID: template.id)
            try await store.scheduleRetry(operation.id, at: Date())
            throw VoiceConsentError.creationPending
        }
        try await store.clearEnrollmentRecovery(recordID: template.id)
        let record = template.assigningVoice(result.voiceID, requiresVerification: result.requiresVerification)

        do {
            _ = try await store.transition(operation.id, to: .created, at: Date(), remoteVoiceID: result.voiceID, requiresVerification: result.requiresVerification)
        } catch {
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

        pending.removeAll(); plans.removeAll()
        try await store.clearEnrollmentRecovery(recordID: recordID)
        try await store.abandonEnrollment(recordID: recordID)
    }
}
