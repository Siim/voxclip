#if DEBUG
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

enum CloneRefusalEvidence: String, CaseIterable, Sendable { case recordedStatement, projectAttestation }
enum CloneRefusalReply: String, CaseIterable, Sendable {
    case subscription, feature, permission, network, cancelled, serverFailure, malformedAccepted, incompleteAccepted, incompleteRefusal, success
    var refusal: VoiceOperation.CreationRefusal? {
        switch self {
        case .subscription: .subscriptionRequired
        case .feature: .featureUnavailable
        case .permission: .clonePermissionMissing
        default: nil
        }
    }
}

private final class CloneRefusalProbe: Sendable {
    let reply: Mutex<CloneRefusalReply>
    let paths = Mutex<[String]>([])
    let uploads = Mutex<[Data]>([])
    let transcriptions = Mutex(0)
    let key = Mutex("synthetic-clone-refusal-key")
    init(_ reply: CloneRefusalReply) { self.reply = Mutex(reply) }
}

private struct CloneRefusalKeys: KeyProvider {
    let probe: CloneRefusalProbe
    func key(for provider: String) async throws -> String? { probe.key.withLock { $0 } }
}

private struct CloneRefusalEmbedder: SpeakerEmbedder {
    let modelID = "fixture-refusal-speaker"
    let dimension = 2
    func embed(_ pcm16k: [Float]) async throws -> [Float] { [1, 0] }
    func voicedSamples(_ pcm16k: [Float]) async throws -> [Float] { pcm16k }
}

private final class CloneRefusalHTTP: URLProtocol, @unchecked Sendable {
    static let probes = Mutex<[String: CloneRefusalProbe]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let identifier = request.value(forHTTPHeaderField: "X-Clone-Refusal-Probe") ?? ""
            let probe = try #require(Self.probes.withLock { $0[identifier] })
            let url = try #require(request.url)
            probe.paths.withLock { $0.append((request.httpMethod ?? "") + " " + url.path) }
            let status: Int
            let body: Data
            var incomplete = false
            switch url.path {
            case "/v1/user/subscription":
                status = 200
                body = Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":1000,"can_use_instant_voice_cloning":true,"voice_slots_used":0,"voice_limit":3}"#.utf8)
            case "/v2/voices":
                status = 200; body = Data(#"{"voices":[],"has_more":false}"#.utf8)
            case "/v1/voices/add":
                let upload = try VoiceLabRequestFixtures.body(request)
                probe.uploads.withLock { $0.append(upload) }
                switch probe.reply.withLock({ $0 }) {
                case .subscription, .cancelled, .incompleteRefusal:
                    status = 403; body = Data(#"{"detail":{"status":"subscription_required"}}"#.utf8)
                    incomplete = probe.reply.withLock { $0 == .incompleteRefusal }
                case .feature:
                    status = 403; body = Data(#"{"detail":{"status":"feature_not_available"}}"#.utf8)
                case .permission:
                    status = 401; body = Data(#"{"detail":{"status":"missing_permission","permission":"create_instant_voice_clone"}}"#.utf8)
                case .network: throw URLError(.networkConnectionLost)
                case .serverFailure:
                    status = 503; body = Data(#"{"detail":{"status":"subscription_required"}}"#.utf8)
                case .malformedAccepted:
                    status = 200; body = Data(#"{"requires_verification":false}"#.utf8)
                case .incompleteAccepted:
                    status = 200; body = Data(#"{"voice_id":"acceptedOwner","requires_verification":false}"#.utf8); incomplete = true
                case .success:
                    status = 200; body = Data(#"{"voice_id":"retriedOwner","requires_verification":false}"#.utf8)
                }
            default:
                Issue.record("Unexpected refusal-test request: \(url.path)")
                throw URLError(.unsupportedURL)
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            if incomplete { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
            else { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private enum CloneRefusalInterruption: Error { case persistence }

@Suite("Definitive clone endpoint refusals", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
struct CloneDefinitiveRefusalTests {
    private func client(_ probe: CloneRefusalProbe) throws -> ElevenLabsVoiceLab {
        let identifier = UUID().uuidString
        CloneRefusalHTTP.probes.withLock { $0[identifier] = probe }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloneRefusalHTTP.self]
        configuration.httpAdditionalHeaders = ["X-Clone-Refusal-Probe": identifier]
        return ElevenLabsVoiceLab(keys: CloneRefusalKeys(probe: probe), session: URLSession(configuration: configuration),
                                  prices: try VoiceLabPriceCatalog.load(shared: SharedResources.locate()), enforceCapabilities: true)
    }
    private func service(_ store: VoiceConsentStore, _ client: ElevenLabsVoiceLab, _ probe: CloneRefusalProbe) async throws -> VoiceEnrollment {
        let mapper = ElevenLabsTranscriber(keys: SpeechTestKeys(value: nil), session: URLSession(configuration: .ephemeral),
                                          catalog: try SpeechTestFiles.catalog())
        let transcript = try await mapper.mapResponse(FixtureLoader.data("fixtures/voice-lab/consent-scribe.json"), diarize: false)
        return VoiceEnrollment(store: store, client: client,
                               speaker: .init(embedder: CloneRefusalEmbedder(), calibratedThreshold: 0.9, language: "en")) { _, language in
            #expect(language == "en")
            probe.transcriptions.withLock { $0 += 1 }
            return transcript
        }
    }
    private func prepare(_ service: VoiceEnrollment, evidence: CloneRefusalEvidence, recordID: String = UUID().uuidString) async throws -> VoiceEnrollmentPlan {
        let audio = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 240_000, fill: 4_000)
        let attestations = VoiceConsentRecord.Attestations(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: Date())
        let sample = VoiceTrainingSample(wav: audio, speech16k: [], seconds: 15,
                                         source: evidence == .projectAttestation ? "project" : "readAloud", snrDb: 25)
        if evidence == .projectAttestation {
            return try await service.prepareProjectPlan(recordID: recordID, language: "en", attestations: attestations,
                                                        displayName: "Example", samples: [sample, sample], enabled: true)
        }
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: FixtureLoader.data("fixtures/voice-lab/consent-record.json"))
        let statement = try #require(record.statement)
        return try await service.preparePlan(recordID: recordID, statement: .init(language: statement.language, text: statement.text, nonce: statement.nonce),
                                             wav: VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000),
                                             attestations: attestations, displayName: "Example", samples: Array(repeating: sample, count: 4), enabled: true)
    }

    @Test func classifierRequiresTheExistingNarrowTypedEndpointErrors() {
        #expect(VoiceOperation.CreationRefusal(error: VoiceLabError.subscriptionRequired) == .subscriptionRequired)
        #expect(VoiceOperation.CreationRefusal(error: VoiceLabError.featureUnavailable) == .featureUnavailable)
        #expect(VoiceOperation.CreationRefusal(error: VoiceLabError.permissionMissing("create_instant_voice_clone")) == .clonePermissionMissing)
        for error in [VoiceLabError.network, .cancelled, .providerFailure(500), .providerFailure(503), .malformedResponse, .responseTooLarge,
                      .permissionMissing("voices_read"), .permissionMissing("unknown"), .unauthorized, .quotaExceeded, .rateLimited,
                      .planUnavailable, .noVoiceSlots, .voiceAccessDenied, .modelAccessDenied] {
            #expect(VoiceOperation.CreationRefusal(error: error) == nil)
        }
        #expect(VoiceOperation.CreationRefusal(error: NSError(domain: "subscription_required", code: 403)) == nil)
    }

    @Test(arguments: CloneRefusalEvidence.allCases, [CloneRefusalReply.subscription, .feature, .permission])
    func settledRefusalSurvivesRestartAndRequiresFreshExplicitApproval(evidence: CloneRefusalEvidence, reply: CloneRefusalReply) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = SpeechTestFiles.locations(root)
        let probe = CloneRefusalProbe(reply); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations); let service = try await service(store, client, probe)
        let original = try await prepare(service, evidence: evidence)
        let refusal = try #require(reply.refusal)
        await #expect(throws: refusal.error) { try await service.execute(original, approved: true, enabled: true, appVersion: "0.1.0") }
        let settled = try await store.operation(original.quote.create.requestID)
        #expect(settled.state == .refused && settled.finished && settled.wasDispatched)
        #expect(settled.creationRefusal == refusal && settled.creationRefusal?.error == refusal.error)
        #expect(settled.remoteVoiceID == nil && settled.remoteStateUnknown != true)
        #expect(!settled.blocksCreation(at: settled.startedAt) && !settled.needsCreatorRecoveryReview)
        #expect(settled.attempts == 0 && !settled.failed && settled.nextAttemptAt == nil)
        #expect(settled.creatorKeyFingerprint == (try await client.creatorKeyFingerprint()))
        let recovery = try #require(try await store.enrollmentRecovery(recordID: original.recordID))
        #expect(try await store.referenceAudio(recordID: original.recordID) == recovery.request.samples[0].wav)
        #expect(recovery.record.consentMethod == original.consentMethod)
        #expect(settled.audit?.consentMethod == original.consentMethod)
        #expect(settled.audit?.recordingSha256s == recovery.record.samples.map(\.sha256))
        #expect(probe.transcriptions.withLock { $0 } == (evidence == .recordedStatement ? 1 : 0))
        #expect(probe.paths.withLock { $0 } == ["GET /v1/user/subscription", "POST /v1/voices/add"])
        await #expect(throws: VoiceConsentError.creationPending) {
            _ = try await store.beginClaimedCreation(record: recovery.record, requestID: settled.id, region: .default, at: Date())
        }

        let restarted = VoiceConsentStore(locations: locations)
        let newClient = try self.client(probe)
        try await restarted.reconcileAbandonedEnrollments()
        let reconciler = VoiceOperationReconciler(store: restarted, client: newClient)
        try await reconciler.reconcile(force: true)
        try await reconciler.reconcile(force: true)
        #expect(try await restarted.operation(settled.id) == settled)
        #expect(try await restarted.recoverableEnrollments() == [original.recordID])
        #expect(probe.paths.withLock { $0.count } == 2)

        let newService = try await self.service(restarted, newClient, probe)
        probe.key.withLock { $0 = "synthetic-other-account-key" }
        await #expect(throws: VoiceConsentError.creatorMismatch) { try await newService.recoverPlan(recordID: original.recordID, enabled: true) }
        probe.key.withLock { $0 = "synthetic-clone-refusal-key" }
        let retry = try await newService.recoverPlan(recordID: original.recordID, enabled: true)
        #expect(retry.isRecovery && retry.quote.verify == nil)
        #expect(retry.quote.create.id != original.quote.create.id && retry.quote.create.requestID != settled.id)
        #expect(probe.paths.withLock { $0.count } == 2)
        await #expect(throws: VoiceLabError.consentRequired) { try await service.execute(original, approved: true, enabled: true, appVersion: "0.1.0") }
        await #expect(throws: VoiceLabError.consentRequired) { try await newService.execute(retry, approved: false, enabled: true, appVersion: "0.1.0") }
        #expect(probe.uploads.withLock { $0.count } == 1)
        probe.reply.withLock { $0 = .success }
        let created = try await newService.execute(retry, approved: true, enabled: true, appVersion: "0.1.0")
        #expect(created.voiceId == "retriedOwner" && created.status == .active)
        #expect(created.schema == recovery.record.schema && created.consentMethod == recovery.record.consentMethod)
        #expect(created.statement == recovery.record.statement && created.projectConsent == recovery.record.projectConsent)
        #expect(created.attestations == recovery.record.attestations && created.samples == recovery.record.samples)
        #expect(created.speaker == recovery.record.speaker)
        #expect(created.referenceAudioSHA256 == recovery.record.referenceAudioSHA256 && created.creator == recovery.record.creator)
        #expect(probe.transcriptions.withLock { $0 } == (evidence == .recordedStatement ? 1 : 0))
        #expect(probe.uploads.withLock { $0.count } == 2)
        let uploads = probe.uploads.withLock { $0.map { String(decoding: $0, as: UTF8.self) } }
        #expect(uploads.allSatisfy { $0.contains("consent-statement.wav") == (evidence == .recordedStatement) })
        try await reconciler.reconcile(force: true)
        #expect(try await restarted.load(original.recordID) == created)
        #expect(try await restarted.operation(settled.id) == settled)
        #expect(try await restarted.enrollmentRecovery(recordID: original.recordID) == nil)
        #expect(!probe.paths.withLock { $0.contains(where: { $0.hasPrefix("DELETE") || $0.contains("/v2/voices") }) })
    }

    @Test(arguments: [CloneRefusalReply.network, .cancelled, .serverFailure, .malformedAccepted, .incompleteAccepted, .incompleteRefusal])
    func uncertainDispatchedOutcomesKeepAmbiguousRecovery(reply: CloneRefusalReply) async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = SpeechTestFiles.locations(root)
        let probe = CloneRefusalProbe(reply); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations); let service = try await service(store, client, probe)
        let plan = try await prepare(service, evidence: .projectAttestation)
        if reply == .cancelled {
            await client.runAfterLastByte {
                if probe.uploads.withLock({ !$0.isEmpty }) { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let execution = Task { try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0") }
        await #expect(throws: VoiceConsentError.creationPending) { try await execution.value }
        await client.runAfterLastByte(nil)
        let operation = try await store.operation(plan.quote.create.requestID)
        #expect(operation.state == .dispatched && operation.wasDispatched && !operation.finished)
        #expect(operation.creationRefusal == nil && operation.remoteVoiceID == nil)
        #expect(operation.blocksCreation(at: operation.startedAt) && operation.nextAttemptAt != nil)
        #expect(try await store.enrollmentRecovery(recordID: plan.recordID) == nil)
        #expect(try await store.recoverableEnrollments().isEmpty)
        await #expect(throws: (any Error).self) { try await store.referenceAudio(recordID: plan.recordID) }
        await #expect(throws: VoiceConsentError.invalidRecord) { try await service.recoverPlan(recordID: plan.recordID, enabled: true) }
        let restarted = VoiceConsentStore(locations: locations)
        try await VoiceOperationReconciler(store: restarted, client: client).reconcile(force: true)
        #expect(try await restarted.operation(operation.id).state == .dispatched)
        #expect(probe.uploads.withLock { $0.count } == 1)
        #expect(probe.paths.withLock { $0.filter { $0 == "GET /v2/voices" }.count } == 1)
    }

    @Test func refusalWriteFailureCannotPretendSettlementOrPermitReplay() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = SpeechTestFiles.locations(root)
        let probe = CloneRefusalProbe(.subscription); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations, fault: {
            if $0 == .creationRefused { throw CloneRefusalInterruption.persistence }
        })
        let service = try await service(store, client, probe)
        let plan = try await prepare(service, evidence: .projectAttestation)
        await #expect(throws: CloneRefusalInterruption.persistence) { try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0") }
        let operation = try await store.operation(plan.quote.create.requestID)
        #expect(operation.state == .dispatched && operation.creationRefusal == nil && operation.blocksCreation(at: operation.startedAt))
        #expect(try await store.enrollmentRecovery(recordID: plan.recordID) != nil)
        #expect(try await store.recoverableEnrollments().isEmpty)
        await #expect(throws: VoiceConsentError.creationPending) { try await service.recoverPlan(recordID: plan.recordID, enabled: true) }
        let restarted = VoiceConsentStore(locations: locations)
        try await VoiceOperationReconciler(store: restarted, client: client).reconcile(force: true)
        #expect(try await restarted.operation(operation.id).creationRefusal == nil)
        #expect(try await restarted.enrollmentRecovery(recordID: plan.recordID) == nil)
        #expect(probe.uploads.withLock { $0.count } == 1)
    }

    @Test func refusedDraftCleanupIsRestartableAndCannotRemoveANewAttempt() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = SpeechTestFiles.locations(root)
        let probe = CloneRefusalProbe(.subscription); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations, fault: {
            if $0 == .removeDraft { throw CloneRefusalInterruption.persistence }
        })
        let service = try await service(store, client, probe)
        let plan = try await prepare(service, evidence: .projectAttestation)
        await #expect(throws: VoiceLabError.subscriptionRequired) { try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0") }
        #expect(try await store.load(plan.recordID).voiceId == "pending")
        let restarted = VoiceConsentStore(locations: locations)
        let newService = try await self.service(restarted, client, probe)
        let retry = try await newService.recoverPlan(recordID: plan.recordID, enabled: true)
        let recovery = try #require(try await restarted.enrollmentRecovery(recordID: plan.recordID))
        let newOperation = try await restarted.beginClaimedCreation(record: recovery.record, requestID: retry.quote.create.requestID, region: .default, at: Date())
        await restarted.releaseOperation(newOperation.id)
        try await VoiceOperationReconciler(store: restarted, client: client).reconcile(operationID: plan.quote.create.requestID, force: true)
        #expect(try await restarted.load(plan.recordID) == recovery.record)
        #expect(try await restarted.referenceAudio(recordID: plan.recordID) == recovery.request.samples[0].wav)
        #expect(probe.uploads.withLock { $0.count } == 1)
        await #expect(throws: VoiceConsentError.creationPending) {
            _ = try await restarted.beginClaimedCreation(record: recovery.record, requestID: UUID(), region: .default, at: Date())
        }
    }

    @Test func refusalTransitionIsNarrowAndRetainsDispatchAndAuditEvidence() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let locations = SpeechTestFiles.locations(root)
        let store = VoiceConsentStore(locations: locations)
        let reference = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000)
        var fixture = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(fixture["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(reference); fixture["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: fixture))
            .assigningVoice("pending", requiresVerification: true)
        try await store.saveStatement(reference, recordID: record.id)
        let date = Date()
        let operation = try await store.beginClaimedCreation(record: record, requestID: UUID(), region: .default, at: date)
        await store.releaseOperation(operation.id)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.refuseCreation(operation.id, refusal: .subscriptionRequired, at: date) }
        _ = try await store.transition(operation.id, to: .dispatched, at: date)
        let dispatched = try await store.operation(operation.id)
        #expect(try JSONDecoder().decode(VoiceOperation.self, from: JSONEncoder().encode(dispatched)).creationRefusal == nil)
        let refused = try await store.refuseCreation(operation.id, refusal: .subscriptionRequired, at: date)
        #expect(refused.wasDispatched && refused.audit == operation.audit && refused.creatorKeyFingerprint == operation.creatorKeyFingerprint)
        for state in [VoiceOperation.State.created, .withdrawing, .dispatched] {
            await #expect(throws: VoiceConsentError.invalidRecord) { try await store.transition(operation.id, to: state, at: date, remoteVoiceID: "notCreated") }
        }
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.discardUnsentCreation(operation.id) }
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.removeOperation(refused) }
        await #expect(throws: VoiceConsentError.invalidRecord) { try await store.scheduleRetry(operation.id, at: date) }
        let operationsRoot = await store.operationsRoot
        let operationFile = operationsRoot.appendingPathComponent(operation.id.uuidString + ".json")
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: operationFile)) as? [String: Any])
        #expect(object["state"] as? String == "refused" && object["creationRefusal"] as? String == "subscriptionRequired")
        #expect(object["record"] == nil && object["request"] == nil && object["audio"] == nil && object["embedding"] == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: operationFile.path)[.posixPermissions] as? Int == 0o600)
        let restarted = VoiceConsentStore(locations: locations)
        #expect(try await restarted.operation(operation.id) == refused)
        var invalid = object; invalid.removeValue(forKey: "creationRefusal")
        try JSONSerialization.data(withJSONObject: invalid).write(to: operationFile, options: .atomic)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await restarted.operation(operation.id) }
        invalid = object; invalid["state"] = "dispatched"
        try JSONSerialization.data(withJSONObject: invalid).write(to: operationFile, options: .atomic)
        await #expect(throws: VoiceConsentError.invalidRecord) { try await restarted.operation(operation.id) }
    }
}
#endif
