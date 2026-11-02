#if DEBUG
import Foundation
import Synchronization
import Testing
@_spi(Testing) @testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia

private struct EnrollmentVectors: Decodable {
    struct Flow: Decodable { let id: String; let events: [String]; let outcome: String }
    struct Recovery: Decodable { let id: String; let elapsedSeconds: Int; let sameQuote: Bool; let action: String; let events: [String] }
    struct Retry: Decodable { let id: String; let localPrepares: Int; let expiredReprepares: Int; let expectedSends: [String] }
    struct Journal: Decodable { let id: String; let ageSeconds: Int; let corruption: String; let retained: Bool }
    let retries: [Retry]; let journals: [Journal]
    struct Attempts: Decodable { let limit: Int; let blockedAtSeconds: Int; let allowedAtSeconds: Int }
    let flows: [Flow]; let mutations: [String]; let attempts: Attempts; let recoveries: [Recovery]
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: FixtureLoader.data("fixtures/voice-lab/enrollment-cases.json"))
    }
}
private final class EnrollmentProbe: Sendable {
    let events = Mutex<[String]>([])
    let embeddings = Mutex(0)
    let key = Mutex("synthetic-enrollment-key")
    let time = Mutex(Date())
}
private struct EnrollmentKeys: KeyProvider {
    let probe: EnrollmentProbe
    func key(for provider: String) async throws -> String? { probe.key.withLock { $0 } }
}
private struct EnrollmentEmbedder: SpeakerEmbedder {
    let modelID = "fixture-calibrated"
    let dimension = 2
    let probe: EnrollmentProbe
    func embed(_ pcm16k: [Float]) async throws -> [Float] {
        probe.embeddings.withLock { $0 += 1 }
        return pcm16k[0] > 0 ? [1, 0] : [0, 1]
    }
}
private enum EnrollmentCrash: Error { case afterVerify }

@Suite("C7 enrollment plan", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
struct VoiceEnrollmentPlanTests {
    private static let statementWav = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 4_000)
    private static let matchingSamples = makeSamples(mismatch: false)
    private static let mismatchingSamples = makeSamples(mismatch: true)
    private var wav: Data { Self.statementWav }
    private func statement() throws -> VoiceConsentStatement {
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: FixtureLoader.data("fixtures/voice-lab/consent-record.json"))
        let statement = try #require(record.statement)
        return .init(language: statement.language, text: statement.text, nonce: statement.nonce)
    }
    private static func makeSamples(mismatch: Bool) -> [VoiceTrainingSample] {
        (0..<4).map { index in
            let fill: Int = mismatch ? -4_000 : 2_000 + index
            let audio = VoiceLabRequestFixtures.wav(rate: 16_000, frames: 240_000, fill: fill)
            return VoiceTrainingSample(wav: audio, speech16k: [], seconds: 15, source: "readAloud", snrDb: 25)
        }
    }
    private func samples(mismatch: Bool = false) -> [VoiceTrainingSample] {
        mismatch ? Self.mismatchingSamples : Self.matchingSamples
    }
    private func client(_ probe: EnrollmentProbe, flow: String = "success") async -> ElevenLabsVoiceLab {
        let base = SpeechStubHTTP.register { request in
            #expect(probe.embeddings.withLock { $0 } > 0) // Even the plan check must follow the local match.
            let path = request.url!.path
            switch path {
            case "/v1/user/subscription":
                probe.events.withLock { $0.append("plan") }
                let can = flow != "plan-denied"
                let used = flow == "no-slots" ? 3 : 0
                return (200, [:], Data("{\"tier\":\"starter\",\"status\":\"active\",\"character_count\":0,\"character_limit\":1000,\"can_use_instant_voice_cloning\":\(can),\"voice_slots_used\":\(used),\"voice_limit\":3}".utf8))
            case "/v1/speech-to-text":
                probe.events.withLock { $0.append("verify") }
                if flow == "verify-fail" { return (200, [:], Data(#"{"language_code":"eng","language_probability":1,"text":"wrong","words":[{"text":"wrong","type":"word","start":0,"end":1}]}"#.utf8)) }
                return (200, ["request-id": "fixture-consent-response"], try FixtureLoader.data("fixtures/voice-lab/consent-scribe.json"))
            case "/v1/voices/add":
                probe.events.withLock { $0.append("create") }
                let body = String(decoding: try VoiceLabRequestFixtures.body(request), as: UTF8.self)
                #expect(body.contains("consent-statement.wav"))
                if flow == "create-fail" { return (500, [:], Data()) }
                return (200, [:], Data(#"{"voice_id":"fixtureOwnVoice","requires_verification":false}"#.utf8))
            default: Issue.record("Unexpected enrollment request: \(path)"); return (500, [:], Data())
            }
        }
        let client = ElevenLabsVoiceLab(keys: EnrollmentKeys(probe: probe), session: URLSession(configuration: SpeechStubHTTP.configuration(for: base)), prices: VoiceLabPricingTests.catalogIfPresent)
        await client.useClock({ probe.time.withLock { $0 } }, monotonic: { .zero })
        return client
    }
    private func service(_ store: VoiceConsentStore, _ client: ElevenLabsVoiceLab, _ probe: EnrollmentProbe) -> VoiceEnrollment {
        VoiceEnrollment(store: store, client: client, speaker: .init(embedder: EnrollmentEmbedder(probe: probe), calibratedThreshold: 0.8))
    }
    private func prepare(_ service: VoiceEnrollment, _ probe: EnrollmentProbe, id: String = UUID().uuidString, mismatch: Bool = false) async throws -> VoiceEnrollmentPlan {
        try await service.preparePlan(recordID: id, statement: statement(), wav: wav,
                                      attestations: .init(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: probe.time.withLock { $0 }),
                                      displayName: "Example", samples: samples(mismatch: mismatch), enabled: true, now: probe.time.withLock { $0 })
    }
    private func errorName(_ error: any Error) -> String {
        if let error = error as? VoiceLabError { return String(describing: error) }
        if let error = error as? VoiceConsentError { return String(describing: error) }
        return String(describing: error)
    }

    @Test func replayEveryFlow() async throws {
        for vector in try EnrollmentVectors.load().flows {
            let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let probe = EnrollmentProbe(); let client = await client(probe, flow: vector.id)
            let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root)); let service = service(store, client, probe)
            var outcome = "created"
            let id = UUID().uuidString
            do {
                let plan = try await prepare(service, probe, id: id, mismatch: vector.id == "speaker-mismatch")
                #expect(probe.events.withLock { $0.isEmpty })
                #expect(plan.quote.estimate.usd == plan.quote.verify!.estimate.usd! + plan.quote.create.estimate.usd!)
                let record = try await service.execute(plan, approved: vector.id != "declined", enabled: vector.id != "disabled", appVersion: "0.1.0")
                let recorded = try #require(record.statement)
                #expect(recorded.text == (try statement()).text)
                #expect(recorded.audioSha256 == VoiceLabFingerprint.bytes(wav))
                #expect(recorded.stt.wer == 0)
                #expect(!recorded.stt.transcriptionId.isEmpty)
                #expect(try await store.load(record.id) == record)
                #expect(try await store.recoverableEnrollments().isEmpty)
                await #expect(throws: (any Error).self) { try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0") }
            } catch { outcome = errorName(error) }
            if vector.id == "create-fail" {
                #expect(try await store.enrollmentRecovery(recordID: id) == nil)
                #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(id)/statement.wav").path))
                #expect(try await store.operations().first?.wasDispatched == true)
            }
            #expect(outcome == vector.outcome, "\(vector.id): \(outcome)")
            #expect(probe.events.withLock { $0 } == vector.events, "\(vector.id)")
        }
    }

    @Test func combinedQuoteBindsEveryField() async throws {
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = EnrollmentProbe(); let client = await client(probe)
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root)); let service = service(store, client, probe)
        let plan = try await prepare(service, probe)
        let original = VoiceLabCloneRequest(displayName: "Example", language: "en", samples: [.init(role: .consentStatement, wav: wav)] + samples().map { .init(role: .training, wav: $0.wav) },
                                             createdAt: probe.time.withLock { $0 }, removeBackgroundNoise: false, recoveryNonce: plan.recordID)
        for mutation in try EnrollmentVectors.load().mutations {
            var files = original.samples; var name = original.displayName; var language = original.language
            var date = original.createdAt; var noise = original.removeBackgroundNoise; var id = original.recoveryNonce
            var statement = try statement()
            switch mutation {
            case "same": break
            case "statementBytes": files[0] = .init(role: .consentStatement, wav: VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 8_000))
            case "statementText": statement = .init(language: "en", text: statement.text + " changed", nonce: statement.nonce)
            case "nonce": statement = .init(language: "en", text: statement.text, nonce: Array(statement.nonce.reversed()))
            case "files": files.removeLast()
            case "fileBytes": files[1] = .init(role: .training, wav: wav)
            case "order": files.swapAt(1, 2)
            case "roles": files[1] = .init(role: .consentStatement, wav: files[1].wav)
            case "name": name = "Other"
            case "language": language = "et"
            case "createdAt": date.addTimeInterval(1)
            case "noiseRemoval": noise = true
            case "recordID": id = UUID().uuidString
            default: Issue.record("Unreplayed mutation \(mutation)")
            }
            let request = VoiceLabCloneRequest(displayName: name, language: language, samples: files, createdAt: date, removeBackgroundNoise: noise, recoveryNonce: id)
            if mutation == "same" { try plan.quote.validate(request: request, statement: statement) }
            else { #expect(throws: VoiceLabError.consentRequired) { try plan.quote.validate(request: request, statement: statement) } }
        }
        #expect(probe.events.withLock { $0.isEmpty })
    }

    @Test func attemptWindowAndNewStatementRerunSpeakerMatch() async throws {
        let vector = try EnrollmentVectors.load().attempts
        let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = EnrollmentProbe(); let client = await client(probe)
        let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root)); let service = service(store, client, probe)
        let id = UUID().uuidString; let start = probe.time.withLock { $0 }
        for index in 0..<vector.limit {
            let before = probe.embeddings.withLock { $0 }
            let original = try statement()
            let unique = VoiceConsentStatement(language: original.language, text: original.text, nonce: original.nonce + [String(index)])
            _ = try await service.preparePlan(recordID: id, statement: unique, wav: wav,
                attestations: .init(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: start),
                displayName: "Example", samples: samples(), enabled: true, now: probe.time.withLock { $0 })
            #expect(probe.embeddings.withLock { $0 } > before)
        }
        probe.time.withLock { $0 = start.addingTimeInterval(Double(vector.blockedAtSeconds)) }
        await #expect(throws: VoiceConsentError.tooManyAttempts) { try await prepare(service, probe, id: id) }
        probe.time.withLock { $0 = start.addingTimeInterval(Double(vector.allowedAtSeconds)) }
        _ = try await prepare(service, probe, id: id)
        #expect(probe.events.withLock { $0.isEmpty })
        // A genuinely different recording invalidates the first plan and repeats the speaker match.
        let first = try await prepare(service, probe)
        let before = probe.embeddings.withLock { $0 }
        await #expect(throws: VoiceConsentError.speakerMismatch) {
            try await service.preparePlan(recordID: first.recordID, statement: statement(),
                                          wav: VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: -4_000),
                                          attestations: .init(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: start),
                                          displayName: "Example", samples: samples(), enabled: true, now: probe.time.withLock { $0 })
        }
        #expect(probe.embeddings.withLock { $0 } > before)
        await #expect(throws: VoiceLabError.consentRequired) { try await service.execute(first, approved: true, enabled: true, appVersion: "0.1.0") }
    }

    @Test func replayLocalRetriesDoNotConsumeStatementAttempts() async throws {
        for vector in try EnrollmentVectors.load().retries {
            let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let probe = EnrollmentProbe(); let client = await client(probe)
            let store = VoiceConsentStore(locations: SpeechTestFiles.locations(root)); let service = service(store, client, probe)
            let id = UUID().uuidString
            for _ in 0..<vector.localPrepares {
                let project = samples(mismatch: true).map { VoiceTrainingSample(wav: $0.wav, speech16k: [], seconds: $0.seconds, source: "project", snrDb: $0.snrDb) }
                await #expect(throws: VoiceConsentError.speakerMismatch) {
                    try await service.preparePlan(recordID: id, statement: statement(), wav: wav,
                        attestations: .init(ownVoice: true, adult: true, ownVideosOnly: true, acceptedAt: probe.time.withLock { $0 }),
                        displayName: "Example", samples: project, enabled: true, now: probe.time.withLock { $0 })
                }
            }
            for _ in 0..<vector.expiredReprepares {
                _ = try await prepare(service, probe, id: id)
                probe.time.withLock { $0.addTimeInterval(300) }
            }
            let plan = try await prepare(service, probe, id: id)
            _ = try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0")
            #expect(probe.events.withLock { $0 } == vector.expectedSends)
        }
    }

    @Test func replayJournalLifetimeAndInvalidJournalsDoNotBlockValidRecovery() async throws {
        for vector in try EnrollmentVectors.load().journals {
            let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let locations = SpeechTestFiles.locations(root); let probe = EnrollmentProbe()
            probe.time.withLock { $0 = Date().addingTimeInterval(-Double(vector.ageSeconds)) }
            let client = await client(probe)
            let store = VoiceConsentStore(locations: locations, fault: { if $0 == .enrollmentVerified { throw EnrollmentCrash.afterVerify } })
            let service = service(store, client, probe); let plan = try await prepare(service, probe)
            await #expect(throws: EnrollmentCrash.afterVerify) { try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0") }
            let dir = store.root.appendingPathComponent(plan.recordID)
            let journal = dir.appendingPathComponent("enrollment.json")
            if vector.corruption == "json" { try Data("broken".utf8).write(to: journal) }
            if vector.corruption == "binding" {
                var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
                value["trainingSeconds"] = -1
                try JSONSerialization.data(withJSONObject: value).write(to: journal)
            }
            if vector.corruption == "statement" { try FileManager.default.removeItem(at: dir.appendingPathComponent("statement.wav")) }
            // A second valid journal must remain available even if the first cannot be decoded.
            probe.time.withLock { $0 = Date() }
            let valid = try await prepare(service, probe)
            await #expect(throws: EnrollmentCrash.afterVerify) { try await service.execute(valid, approved: true, enabled: true, appVersion: "0.1.0") }
            let restarted = VoiceConsentStore(locations: locations)
            let expected = vector.retained ? [plan.recordID, valid.recordID].sorted() : [valid.recordID]
            if vector.corruption == "none" { try await restarted.reconcileAbandonedEnrollments() }
            #expect(try await restarted.recoverableEnrollments() == expected, "\(vector.id)")
            try await restarted.reconcileAbandonedEnrollments()
            #expect(await restarted.takeAbandonedEnrollmentCount() == (vector.retained ? 0 : 1))
            #expect(FileManager.default.fileExists(atPath: journal.path) == vector.retained)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("statement.wav").path) == vector.retained)
            if !vector.retained { #expect(!FileManager.default.fileExists(atPath: dir.path)) }
        }
    }

    @Test func replayEveryRecoveryJournalCase() async throws {
        for vector in try EnrollmentVectors.load().recoveries {
            let root = try SpeechTestFiles.directory(); defer { try? FileManager.default.removeItem(at: root) }
            let locations = SpeechTestFiles.locations(root); let probe = EnrollmentProbe()
            let client = await client(probe)
            let store = VoiceConsentStore(locations: locations, fault: { if $0 == .enrollmentVerified { throw EnrollmentCrash.afterVerify } })
            let service = service(store, client, probe); let plan = try await prepare(service, probe)
            await #expect(throws: EnrollmentCrash.afterVerify) { try await service.execute(plan, approved: true, enabled: true, appVersion: "0.1.0") }
            #expect(probe.events.withLock { $0 } == ["plan", "verify"])
            let restarted = VoiceConsentStore(locations: locations)
            if vector.id == "unsent-intent" || vector.id == "dispatched" {
                let snapshot = try #require(try await restarted.enrollmentRecovery(recordID: plan.recordID))
                let operation = try await restarted.beginClaimedCreation(record: snapshot.record, requestID: plan.quote.create.requestID, region: client.region, at: probe.time.withLock { $0 })
                if vector.id == "dispatched" { _ = try await restarted.transition(operation.id, to: .dispatched, at: probe.time.withLock { $0 }) }
                await restarted.releaseOperation(operation.id)
            }
            if vector.id == "cancelled" { try await restarted.abandonEnrollment(recordID: plan.recordID) }
            if vector.id == "changed-statement" { try await restarted.saveStatement(VoiceLabRequestFixtures.wav(rate: 16_000, frames: 80_000, fill: 8_000), recordID: plan.recordID) }
            if vector.id == "different-creator" { probe.key.withLock { $0 = "synthetic-other-key" } }
            probe.time.withLock { $0.addTimeInterval(Double(vector.elapsedSeconds)) }
            probe.events.withLock { $0.removeAll() }
            let newClient = await self.client(probe); let recoveryService = self.service(restarted, newClient, probe)
            if vector.action == "reject" {
                await #expect(throws: (any Error).self) { try await recoveryService.recoverPlan(recordID: plan.recordID, enabled: true) }
            } else {
                try await restarted.reconcileAbandonedEnrollments()
                try await VoiceOperationReconciler(store: restarted, client: newClient).reconcile()
                #expect(try await restarted.recoverableEnrollments() == [plan.recordID])
                let recovered = try await recoveryService.recoverPlan(recordID: plan.recordID, enabled: true)
                #expect(recovered.verificationPassed)
                #expect(recovered.quote.verify == nil)
                #expect(recovered.quote.estimate.usd == recovered.quote.create.estimate.usd)
                #expect((recovered.quote.create == plan.quote.create) == vector.sameQuote)
                #expect(probe.events.withLock { $0.isEmpty })
                if vector.action == "decline" {
                    await #expect(throws: VoiceLabError.consentRequired) { try await recoveryService.execute(recovered, approved: false, enabled: true, appVersion: "0.1.0") }
                } else {
                    let record = try await recoveryService.execute(recovered, approved: true, enabled: true, appVersion: "0.1.0")
                    #expect(record.statement?.audioSha256 == VoiceLabFingerprint.bytes(wav))
                    #expect(record.statement?.text == (try statement()).text)
                    #expect(try await restarted.recoverableEnrollments().isEmpty)
                }
            }
            #expect(probe.events.withLock { $0 } == vector.events, "\(vector.id)")
        }
    }
}
#endif
