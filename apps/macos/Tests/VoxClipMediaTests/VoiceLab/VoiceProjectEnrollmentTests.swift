#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

private final class ProjectEnrollmentProbe: Sendable {
    let paths = Mutex<[String]>([])
    let uploads = Mutex<[Data]>([])
    let key = Mutex("synthetic-project-enrollment-key")
    let verificationRequired: Bool
    let createStatus: Int
    init(verificationRequired: Bool = false, createStatus: Int = 200) {
        self.verificationRequired = verificationRequired; self.createStatus = createStatus
    }
}

private struct ProjectEnrollmentKeys: KeyProvider {
    let probe: ProjectEnrollmentProbe
    func key(for provider: String) async throws -> String? { probe.key.withLock { $0 } }
}

private struct ProjectEnrollmentEmbedder: SpeakerEmbedder {
    let modelID = "fixture-project-speaker"
    let dimension = 2
    func embed(_ pcm16k: [Float]) async throws -> [Float] { pcm16k[0] > 0 ? [1, 0] : [0, 1] }
}

private final class ProjectEnrollmentHTTP: URLProtocol, @unchecked Sendable {
    static let probes = Mutex<[String: ProjectEnrollmentProbe]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let identifier = request.value(forHTTPHeaderField: "X-Project-Enrollment-Probe") ?? ""
            guard let probe = Self.probes.withLock({ $0[identifier] }), let url = request.url else { throw URLError(.badURL) }
            probe.paths.withLock { $0.append(url.path) }
            let status: Int
            let data: Data
            switch url.path {
            case "/v1/user/subscription":
                status = 200
                data = Data(#"{"tier":"starter","status":"active","character_count":0,"character_limit":1000,"can_use_instant_voice_cloning":true,"voice_slots_used":0,"voice_limit":3}"#.utf8)
            case "/v1/voices/add":
                probe.uploads.withLock { $0.append(Self.body(request)) }
                status = probe.createStatus
                data = Data("{\"voice_id\":\"projectOwner\",\"requires_verification\":\(probe.verificationRequired)}".utf8)
            case "/v1/voices/projectOwner":
                #expect(request.httpMethod == "DELETE")
                status = 200; data = Data(#"{"status":"ok"}"#.utf8)
            default:
                Issue.record("Unexpected project enrollment request: \(url.path)")
                status = 500; data = Data()
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private enum ProjectEnrollmentInterruption: Error { case beforeCreate }

@Suite("Project-attested own-voice enrollment", .serialized, .timeLimit(.minutes(2)))
struct VoiceProjectEnrollmentTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-enrollment-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func locations(_ root: URL) -> DataLocations { DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]) }
    private func attestations(own: Bool = true, adult: Bool = true, ownVideos: Bool = true) -> VoiceConsentRecord.Attestations {
        .init(ownVoice: own, adult: adult, ownVideosOnly: ownVideos, acceptedAt: Date())
    }
    private func wav(fill: Int16, seconds: Int = 15, mixed: Bool = false) -> Data {
        func little(_ value: Int, width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        let frames = seconds * 16_000
        var data = Data("RIFF".utf8)
        data.append(little(36 + frames * 2, width: 4)); data.append(Data("WAVEfmt ".utf8))
        data.append(little(16, width: 4)); data.append(little(1, width: 2)); data.append(little(1, width: 2))
        data.append(little(16_000, width: 4)); data.append(little(32_000, width: 4))
        data.append(little(2, width: 2)); data.append(little(16, width: 2)); data.append(Data("data".utf8))
        data.append(little(frames * 2, width: 4))
        var pcm = [Int16](repeating: fill.littleEndian, count: frames)
        if mixed { pcm.replaceSubrange((frames - 48_000)..<frames, with: repeatElement((-fill).littleEndian, count: 48_000)) }
        data.append(pcm.withUnsafeBytes { Data($0) })
        return data
    }
    private func sample(fill: Int16 = 3_000, seconds: Int = 15, mixed: Bool = false, source: String = "project") -> VoiceTrainingSample {
        .init(wav: wav(fill: fill, seconds: seconds, mixed: mixed), speech16k: [-1], seconds: Double(seconds), source: source, snrDb: 25)
    }
    private func client(_ probe: ProjectEnrollmentProbe) throws -> ElevenLabsVoiceLab {
        let identifier = UUID().uuidString
        ProjectEnrollmentHTTP.probes.withLock { $0[identifier] = probe }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectEnrollmentHTTP.self]
        configuration.httpAdditionalHeaders = ["X-Project-Enrollment-Probe": identifier]
        let prices = try VoiceLabPriceCatalog.load(shared: SharedResources.locate())
        return ElevenLabsVoiceLab(keys: ProjectEnrollmentKeys(probe: probe), session: URLSession(configuration: configuration),
                                  prices: prices, enforceCapabilities: true)
    }
    private func service(_ store: VoiceConsentStore, _ client: ElevenLabsVoiceLab) -> VoiceEnrollment {
        VoiceEnrollment(store: store, client: client,
                        speaker: .init(embedder: ProjectEnrollmentEmbedder(), calibratedThreshold: 0.9, language: "en"))
    }
    private func prepare(_ service: VoiceEnrollment, recordID: String = UUID().uuidString.lowercased(),
                         samples: [VoiceTrainingSample]? = nil) async throws -> VoiceEnrollmentPlan {
        try await service.prepareProjectPlan(recordID: recordID, language: "en", attestations: attestations(), displayName: "Owner",
                                             samples: samples ?? [sample(), sample(fill: 3_001)], enabled: true)
    }

    @Test func trainingOnlyMultipartAndProviderVerificationArePreserved() async throws {
        for requiresVerification in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let probe = ProjectEnrollmentProbe(verificationRequired: requiresVerification)
            let client = try client(probe); let store = VoiceConsentStore(locations: locations(root))
            let service = service(store, client)
            let first = sample(); let second = sample(fill: 3_001)
            let plan = try await prepare(service, samples: [first, second])
            #expect(plan.consentMethod == .projectAttestation)
            #expect(!plan.verificationPassed && !plan.isRecovery)
            #expect(plan.quote.verify == nil && plan.trainingSeconds == 30)
            #expect(probe.paths.withLock { $0.isEmpty })
            #expect(try await store.referenceAudio(recordID: plan.recordID) == first.wav)
            let record = try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
            #expect(record.schema == "voxclip-consent/2" && record.statement == nil)
            #expect(record.projectConsent?.consentText == VoiceConsentRecord.ProjectConsent.text)
            #expect(record.referenceAudioSHA256 == VoiceLabFingerprint.bytes(first.wav))
            #expect(record.status == (requiresVerification ? .verificationRequired : .active))
            #expect(record.samples.map(\.sha256) == [first, second].map { VoiceLabFingerprint.bytes($0.wav) })
            #expect(probe.paths.withLock { $0 } == ["/v1/user/subscription", "/v1/voices/add"])
            let body = try #require(probe.uploads.withLock { $0.first })
            let text = String(decoding: body, as: UTF8.self)
            #expect(text.components(separatedBy: "filename=").count - 1 == 2)
            #expect(text.contains("sample-01.wav") && text.contains("sample-02.wav"))
            #expect(!text.contains("consent-statement.wav") && !text.contains("statement.wav"))
            #expect(text.contains("checkbox project attestation") && text.contains(record.referenceAudioSHA256))
            for sample in [first, second] {
                let range = try #require(body.range(of: sample.wav))
                #expect(body.range(of: sample.wav, in: range.upperBound..<body.endIndex) == nil)
            }
            await #expect(throws: VoiceLabError.consentRequired) {
                try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
            }
            #expect(probe.uploads.withLock { $0.count } == 1)
            if requiresVerification {
                await #expect(throws: VoiceConsentError.inactive) { try await store.validateUse(record) }
            }
        }
    }

    @Test func checkboxesApprovalAndCalibratedLanguageAreRequired() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProjectEnrollmentProbe(); let client = try client(probe)
        let service = service(VoiceConsentStore(locations: locations(root)), client)
        for consent in [attestations(own: false), attestations(adult: false), attestations(ownVideos: false)] {
            await #expect(throws: VoiceConsentError.attestationsRequired) {
                try await service.prepareProjectPlan(recordID: UUID().uuidString, language: "en", attestations: consent,
                                                     displayName: "Owner", samples: [sample(), sample()], enabled: true)
            }
        }
        await #expect(throws: VoiceConsentError.speakerUnavailable) {
            try await service.prepareProjectPlan(recordID: UUID().uuidString, language: "et", attestations: attestations(),
                                                 displayName: "Owner", samples: [sample(), sample()], enabled: true)
        }
        let plan = try await prepare(service)
        await #expect(throws: VoiceLabError.consentRequired) {
            try await service.execute(plan, approved: false, enabled: true, appVersion: "0.1.0")
        }
        await #expect(throws: VoiceLabError.consentRequired) {
            try await service.execute(plan, approved: true, enabled: false, appVersion: "0.1.0")
        }
        #expect(probe.paths.withLock { $0.isEmpty })
    }

    @Test func firstValidProjectReferenceAndEveryAcceptedPartMustMatch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProjectEnrollmentProbe(); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations(root)); let service = service(store, client)
        let first = sample(); let second = sample(fill: 3_001)
        let plan = try await prepare(service, samples: [sample(fill: 0), first, sample(fill: -3_000), sample(mixed: true), second])
        #expect(plan.trainingSeconds == 30)
        #expect(try await store.referenceAudio(recordID: plan.recordID) == first.wav)
        let record = try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
        #expect(record.samples.count == 2)
        #expect(record.samples.map(\.sha256) == [first, second].map { VoiceLabFingerprint.bytes($0.wav) })
        await #expect(throws: VoiceConsentError.speakerMismatch) {
            try await prepare(service, samples: [first, sample(fill: -3_000)])
        }
        await #expect(throws: VoiceLabError.invalidInput) {
            try await prepare(service, samples: [sample(source: "readAloud"), second])
        }
        await #expect(throws: VoiceLabError.invalidInput) {
            try await prepare(service, samples: Array(repeating: sample(seconds: 30), count: 5))
        }
    }

    @Test func referenceTamperingBeforeApprovalCannotSend() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProjectEnrollmentProbe(); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations(root)); let service = service(store, client)
        let plan = try await prepare(service)
        try await store.saveReferenceAudio(wav(fill: 6_000), recordID: plan.recordID)
        await #expect(throws: VoiceConsentError.invalidRecord) {
            try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
        }
        #expect(probe.paths.withLock { $0.isEmpty })
    }

    @Test func durableRecoveryBindsCheckboxesTrainingAndOwnerWithoutScribe() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProjectEnrollmentProbe(); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations(root), fault: {
            if $0 == .enrollmentVerified { throw ProjectEnrollmentInterruption.beforeCreate }
        })
        let service = service(store, client); let original = try await prepare(service)
        await #expect(throws: ProjectEnrollmentInterruption.beforeCreate) {
            try await service.execute(original, approved: true, enabled: true, appVersion: "0.1.0")
        }
        #expect(probe.uploads.withLock { $0.isEmpty })
        let restarted = VoiceConsentStore(locations: locations(root))
        let recovery = try #require(try await restarted.enrollmentRecovery(recordID: original.recordID))
        #expect(recovery.request.samples.allSatisfy { $0.role == .training })
        let consent = try #require(recovery.record.projectConsent)
        #expect(throws: VoiceLabError.consentRequired) {
            try recovery.quote.validate(request: recovery.request, projectConsent: consent, attestations: attestations(own: false))
        }
        let changed = VoiceLabCloneRequest(displayName: recovery.request.displayName, language: recovery.request.language,
                                          samples: Array(recovery.request.samples.reversed()), createdAt: recovery.request.createdAt,
                                          removeBackgroundNoise: false, recoveryNonce: recovery.request.recoveryNonce)
        #expect(throws: VoiceLabError.consentRequired) {
            try recovery.quote.validate(request: changed, projectConsent: consent, attestations: recovery.record.attestations)
        }
        let newClient = try self.client(probe); let recoveredService = self.service(restarted, newClient)
        let recovered = try await recoveredService.recoverPlan(recordID: original.recordID, enabled: true)
        #expect(recovered.isRecovery && !recovered.verificationPassed && recovered.consentMethod == .projectAttestation)
        #expect(recovered.quote.verify == nil && recovered.quote.create == original.quote.create)
        #expect(probe.paths.withLock { $0 } == ["/v1/user/subscription"])
        probe.key.withLock { $0 = "synthetic-different-owner-key" }
        await #expect(throws: VoiceConsentError.creatorMismatch) {
            try await recoveredService.execute(recovered, approved: true, enabled: true, appVersion: "0.1.0")
        }
        #expect(probe.uploads.withLock { $0.isEmpty })
        probe.key.withLock { $0 = "synthetic-project-enrollment-key" }
        let record = try await recoveredService.execute(recovered, approved: true, enabled: true, appVersion: "0.1.0")
        #expect(record.statement == nil && record.status == .active)
        #expect(try await restarted.recoverableEnrollments().isEmpty)
        #expect(probe.uploads.withLock { $0.count } == 1)
        #expect(!probe.paths.withLock { $0 }.contains("/v1/speech-to-text"))
    }

    @Test func dispatchedFailureCannotBeReplayedOrRecoveredAsUnsent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProjectEnrollmentProbe(createStatus: 500); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations(root)); let service = service(store, client)
        let plan = try await prepare(service)
        await #expect(throws: VoiceConsentError.creationPending) {
            try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
        }
        await #expect(throws: (any Error).self) { try await service.recoverPlan(recordID: plan.recordID, enabled: true) }
        await #expect(throws: VoiceLabError.consentRequired) {
            try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
        }
        #expect(probe.uploads.withLock { $0.count } == 1)
        #expect(try await store.operations().contains { $0.recordID == plan.recordID && $0.wasDispatched })
    }

    @Test func publicAttestationBooleansCannotMintDispatchCapability() async throws {
        let probe = ProjectEnrollmentProbe(); let client = try client(probe)
        let request = VoiceLabCloneRequest(displayName: "Owner", language: "en", samples: [sample(), sample(fill: 3_001)].map {
            .init(role: .training, wav: $0.wav)
        }, createdAt: Date(), removeBackgroundNoise: false, recoveryNonce: UUID().uuidString)
        let policy = OwnVoicePolicy(recordID: request.recoveryNonce!, recordActive: true, providerConsentGranted: true,
                                    statementVerified: false, speakerMatched: true, consentMethod: .projectAttestation)
        try policy.validate()
        #expect(!policy.statementVerified)
        let quote = try await client.prepareEnrollmentClone(request, policy: policy, requestID: UUID())
        _ = try await client.validateCreationQuote(quote)
        await #expect(throws: VoiceLabError.consentRequired) {
            try await client.createOwnClone(request, policy: policy, requestID: quote.requestID, authorization: .init(quote: quote, approved: true))
        }
        #expect(probe.uploads.withLock { $0.isEmpty })
    }

    @Test func recoveredReferenceTamperingAndCancellationCannotCreate() async throws {
        for tamper in [false, true] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let probe = ProjectEnrollmentProbe(); let client = try client(probe)
            let store = VoiceConsentStore(locations: locations(root), fault: {
                if $0 == .enrollmentVerified { throw ProjectEnrollmentInterruption.beforeCreate }
            })
            let service = service(store, client); let plan = try await prepare(service)
            await #expect(throws: ProjectEnrollmentInterruption.beforeCreate) {
                try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
            }
            let restarted = VoiceConsentStore(locations: locations(root))
            let recoveredService = self.service(restarted, client)
            if tamper { try await restarted.saveReferenceAudio(wav(fill: 8_000), recordID: plan.recordID) }
            else { try await recoveredService.cancel(recordID: plan.recordID) }
            await #expect(throws: VoiceConsentError.invalidRecord) {
                try await recoveredService.recoverPlan(recordID: plan.recordID, enabled: true)
            }
            #expect(try await restarted.recoverableEnrollments().isEmpty)
            #expect(probe.uploads.withLock { $0.isEmpty })
        }
    }

    @Test func attestedVoiceStillChecksSpeakerAtUseAndDeletesReferenceWithOwnerBinding() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProjectEnrollmentProbe(); let client = try client(probe)
        let store = VoiceConsentStore(locations: locations(root)); let service = service(store, client)
        let plan = try await prepare(service)
        let record = try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
        let check = VoiceSpeakerCheck(embedder: ProjectEnrollmentEmbedder(), calibratedThreshold: 0.9, language: "en")
        let guardService = VoiceUseGuard(store: store, check: check)
        let owner = try VoiceConsentAudio.pcm16k(wav(fill: 3_000))
        let policy = try await guardService.authorize(contentKey: "owner-source", recordID: record.id, speech16k: owner, approved: true)
        #expect(policy.consentMethod == .projectAttestation && !policy.statementVerified && policy.capability == nil)
        await #expect(throws: VoiceConsentError.voiceOwnerMismatch) {
            try await guardService.authorize(contentKey: "other-source", recordID: record.id,
                                             speech16k: VoiceConsentAudio.pcm16k(wav(fill: -3_000)), approved: true)
        }
        probe.key.withLock { $0 = "synthetic-different-owner-key" }
        await #expect(throws: VoiceConsentError.creatorMismatch) {
            try await service.delete(recordID: record.id, approved: true, enabled: true)
        }
        #expect(!probe.paths.withLock { $0 }.contains("/v1/voices/projectOwner"))
        probe.key.withLock { $0 = "synthetic-project-enrollment-key" }
        try await service.delete(recordID: record.id, approved: true, enabled: true)
        #expect(try await store.load(record.id).status == .deleted)
        await #expect(throws: (any Error).self) { try await store.referenceAudio(recordID: record.id) }
        await #expect(throws: VoiceConsentError.inactive) {
            try await guardService.authorize(contentKey: "owner-source", recordID: record.id, speech16k: owner, approved: true)
        }
        #expect(probe.paths.withLock { $0.filter { $0 == "/v1/voices/projectOwner" }.count } == 1)
    }
}
#endif
