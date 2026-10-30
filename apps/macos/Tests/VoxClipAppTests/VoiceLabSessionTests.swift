#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

@Suite("Headless Voice Lab session", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows or provider requests are opened."))
@MainActor struct VoiceLabSessionTests {
    @Test(arguments: [2, 3], [false, true]) func recoveryOperationAccessibilityIdentifiesEachVoiceAndAction(count: Int, sharedSuffix: Bool) throws {
        let shared = try SharedResources.locate()
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z"))
        let fixture = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))
        let records = try (1...count).map { index in
            var json = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
            json["recordId"] = UUID().uuidString.lowercased()
            json["voiceName"] = "My voice (VoxClip)"
            let prefix = ["A", "B", "C"][index - 1]
            json["voiceId"] = sharedSuffix ? "voice-\(prefix)123456" : "owned-voice-00000\(index)"
            json["createdAt"] = "2026-10-30T12:00:00Z"
            return try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let voices = VoiceLabSettings.accessibilityContexts(records: records, operations: [], shared: shared)
        for record in records {
            let context = try #require(voices["record-\(record.id)"])
            for request in [VoiceLabSession.Request.delete(record.id), .removeLocal(record.id)] {
                #expect(VoiceLabSettings.requestAccessibilityLabel(request, contexts: voices) == "\(request.title) \(context)")
            }
        }
        for action in ["Delete voice", "Retry deletion", "Remove from VoxClip only", "Retry saving consent record", "Remove unfinished voice"] {
            let labels = try records.enumerated().map { index, record in
                let context = try #require(voices["record-\(record.id)"])
                let label = VoiceLabSettings.actionAccessibilityLabel(action, context: context)
                let identifier = sharedSuffix ? "voice ID \(record.voiceId)" : "voice ID ending 00000\(index + 1)"
                #expect(label == "\(action) My voice (VoxClip), created 30 October 2026, \(identifier)")
                return label
            }
            #expect(Set(labels).count == count)
        }
        var operations = (1...count).map { index in
            var operation = VoiceOperation(id: UUID(), kind: .create, recordID: "attempt-\(index)", region: .default, at: date)
            operation.expectedVoiceName = "My voice (VoxClip)"
            if index == count { operation.remoteVoiceID = "remote-123456" }
            return operation
        }
        operations.append(VoiceOperation(id: UUID(), kind: .create, recordID: "unnamed", region: .default, at: date))
        let contexts = VoiceLabSettings.accessibilityContexts(records: [], operations: operations, shared: shared)
        for operation in operations {
            let context = try #require(contexts["operation-\(operation.id)"])
            let request = VoiceLabSession.Request.stopLooking(operation.id)
            #expect(VoiceLabSettings.requestAccessibilityLabel(request, contexts: contexts) == "\(request.title) \(context)")
        }
        let stop = VoiceLabSession.Request.stopLooking(operations[0].id).title
        for action in ["Retry", "Remove unfinished voice", stop] {
            let labels = try operations.enumerated().map { index, operation in
                let context = try #require(contexts["operation-\(operation.id)"])
                let label = VoiceLabSettings.actionAccessibilityLabel(action, context: context)
                let name = index == count ? "Unnamed voice" : "My voice (VoxClip)"
                let suffix = index == count - 1 ? "voice ID ending 123456" : "attempt \(index + 1)"
                #expect(label == "\(action) \(name), created 30 October 2026, \(suffix)")
                return label
            }
            #expect(Set(labels).count == operations.count)
        }
        let single = VoiceLabSettings.accessibilityContexts(records: [records[0]], operations: [], shared: shared)
        #expect(single["record-\(records[0].id)"] == "My voice (VoxClip), created 30 October 2026")
    }
    @Test func stoppingIdentitylessRecoveryIsExplicitLocalAndDefaultsToCancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let shared = try SharedResources.locate()
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id)
        let operation = try await store.beginClaimedCreation(record: record.assigningVoice("pending", requiresVerification: true), requestID: UUID(), region: .default, at: Date())
        _ = try await store.transition(operation.id, to: .dispatched, at: Date())
        try await store.requireRecoveryReview(operation.id)
        await store.releaseOperation(operation.id)
        let app = AppModel(); app.settings.values["voiceLab.enabled"] = .bool(true)
        app.settings.values["voiceLab.providerConsent.elevenlabs"] = .bool(false)
        let session = VoiceLabSession(app: app, store: store)
        await session.load(recover: false)
        let action = VoiceLabSession.Request.stopLooking(operation.id)
        #expect(action.title == "I've checked my ElevenLabs account — stop looking" && action.defaultIsCancel)
        session.request(action)
        #expect(session.confirmation == action && session.operations.first?.finished == false)
        await session.approve(action)
        #expect(session.operations.first?.remoteStateUnknown == true && session.operations.first?.finished == true)
        #expect(!app.bool("voiceLab.providerConsent.elevenlabs"))
        #expect(session.message?.contains("remote state is unknown") == true)
        session.stopRecovery()
    }
    @Test(arguments: 0..<8) func recordingRequiresEveryAttestationWithACalibratedSpeaker(bits: Int) throws {
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(true)
        app.speakerModelLibrary.model = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        app.speakerModelLibrary.installed = true
        let session = VoiceLabSession(app: app)
        session.statement = VoiceConsentStatement(language: "en", text: "Offline statement fixture", nonce: [])
        session.displayName = "Example"
        session.ownVoice = bits & 1 != 0
        session.adult = bits & 2 != 0
        session.ownVideosOnly = bits & 4 != 0
        #expect(session.speakerReady)
        #expect(session.canRecord == (bits == 7))
    }
    @Test func nativeCheckFailuresPrintExpectedAndActualValues() {
        let result = DebugUISuite.Result.equal("fixture", expected: true, actual: false)
        #expect(!result.passed)
        #expect(result.name == "fixture; expected: true; actual: false")
        #expect(DebugUISuite.Result.equal("fixture", expected: true, actual: true).name == "fixture")
    }
    @Test(arguments: ElevenLabsRegion.allCases)
    func nativeConsentLogicRunsHeadlesslyWithoutRecordingOrDispatch(region: ElevenLabsRegion) async throws {
        let app = AppModel()
        app.settings.values["transcription.elevenlabs.region"] = .string(region.rawValue)
        let settings = app.settings
        let model = app.speakerModelLibrary.model
        let installed = app.speakerModelLibrary.installed
        let results = try await DebugVoiceLab.run(app: app)
        #expect(results.count == 12)
        for result in results { #expect(result.passed, Comment(rawValue: result.name)) }
        #expect(app.settings == settings)
        #expect(app.speakerModelLibrary.model?.id == model?.id)
        #expect(app.speakerModelLibrary.installed == installed)
    }
    @Test func recoveryExplainsTheRequiredCreatorKeyAndKeepsTheOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let shared = try SharedResources.locate()
        let data = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id)
        let draft = record.assigningVoice("pending", requiresVerification: true)
        let operation = try await store.beginClaimedCreation(record: draft, requestID: UUID(), region: .default, at: Date())
        _ = try await store.transition(operation.id, to: .dispatched, at: Date())
        await store.releaseOperation(operation.id)
        let reconciler = VoiceOperationReconciler(store: store, regionIsCurrent: { _ in false }) { region in
            ElevenLabsVoiceLab(keys: VoiceLabAppKeys(), region: region)
        }
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store, reconciler: reconciler)
        await session.load(force: true)
        #expect(session.message == "Recovery needs the ElevenLabs key that started this voice.")
        #expect(session.operations.count == 1 && session.operations.first?.finished == false)
        session.stopRecovery()
    }
    @Test func createdDateUsesTheFixedMonthTable() throws {
        #expect(VoiceLabSettings.createdDate("2026-10-26T12:00:00Z", shared: try SharedResources.locate()) == "26 October 2026")
        #expect(VoiceLabSettings.createdDate("invalid", shared: try SharedResources.locate()) == "Date unavailable")
    }
    @Test func deletionNeverUsesTheDestructiveDefault() {
        #expect(VoiceLabSession.Request.delete("voice").defaultIsCancel)
        for request: VoiceLabSession.Request in [.subscription, .verify, .create] { #expect(!request.defaultIsCancel) }
    }
    @Test func unavailableSpeakerCheckPreventsRecordingAndPaidApproval() async {
        let app = AppModel(); app.settings.values["voiceLab.enabled"] = .bool(true)
        let session = VoiceLabSession(app: app)
        session.displayName = "Example"; session.ownVoice = true; session.adult = true; session.ownVideosOnly = true
        #expect(!session.canRecord)
        await session.beginStatement()
        #expect(!session.recorder.recording && session.statement == nil)
        session.request(.verify)
        #expect(session.confirmation == nil)
        await session.approve(.verify)
        #expect(session.message == VoiceConsentError.speakerUnavailable.localizedDescription)
        #expect(!app.bool("voiceLab.providerConsent.elevenlabs"))
        for available in [false, true] {
            for language in ["en", "et", "fr"] {
                #expect(VoiceLabGate.canCheckOwnVoice(speakerAvailable: available, calibratedThreshold: 0.45, language: language) == (available && language == "en"))
            }
        }
        for threshold: Double? in [nil, .nan, -.infinity, -1, 1.1] {
            #expect(!VoiceLabGate.canCheckOwnVoice(speakerAvailable: true, calibratedThreshold: threshold, language: "en"))
        }
    }
    @Test func startupAndSettingsFlushDoNotAwaitRemoteRecovery() async {
        let app = AppModel(), barrier = SessionRecoveryBarrier()
        app.voiceRecoveryForTests = { await barrier.pause() }
        await app.start()
        await barrier.wait()
        #expect(!app.loadingSettings)
        await app.flushSettings()
        barrier.resume()
        await barrier.finished()
        #expect(barrier.cancelled)
    }
    private func locations(_ root: URL) -> DataLocations {
        DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
    }
    @Test func reopeningAndCancellingAfterSuccessPreservesTheActiveVoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let session = VoiceLabSession(app: AppModel(), store: store)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        json["recordId"] = session.recordID
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        session.verified = true; session.trainingReady = true
        session.finishCreation()
        #expect(session.recordID != record.id && !session.verified && !session.trainingReady && session.statement == nil)
        session.showEnrollment = true
        await session.cancelEnrollment()
        #expect(try await store.load(record.id) == record)
        #expect(try await store.statement(recordID: record.id) == wav)
        await #expect(throws: VoiceConsentError.inactive) { try await store.withdrawCreation(recordID: record.id) }
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("\(record.id)/statement.wav"))
        let restarted = VoiceConsentStore(locations: locations(root))
        await #expect(throws: (any Error).self) { try await restarted.reconcileAbandonedEnrollments() }
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/record.json").path))
    }
    @Test func enablingBetaLoadsExistingRecordsBeforeAccountApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        let data = try Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any])
        statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let app = AppModel()
        app.settings.values["voiceLab.enabled"] = .bool(false)
        let session = VoiceLabSession(app: app, store: store)
        await session.refreshEnabledState()
        #expect(session.records.isEmpty && session.subscription == nil && session.confirmation == nil)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        await session.refreshEnabledState()
        #expect(session.records == [record] && session.visibleRecords == [record])
        #expect(session.subscription == nil && session.confirmation == .subscription)
        session.confirmation = nil
        app.settings.values["voiceLab.enabled"] = .bool(false)
        await session.refreshEnabledState()
        #expect(session.records.isEmpty)
        app.settings.values["voiceLab.enabled"] = .bool(true)
        await session.refreshEnabledState()
        #expect(session.records == [record] && session.subscription == nil)
    }
    @Test func cancelBeforeServicesExistDeletesTheRecordedStatement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        try await store.saveStatement(wav, recordID: session.recordID)
        session.showEnrollment = true
        await session.cancelEnrollment()
        #expect(!session.showEnrollment)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(session.recordID)/statement.wav").path))
    }
    @Test func withheldCalibrationNeverAdvertisesSpeakerAvailability() throws {
        let app = AppModel()
        let entry = try SpeakerModelCatalog(shared: SharedResources.locate()).entry
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        object["threshold"] = NSNull()
        app.speakerModelLibrary.model = try JSONDecoder().decode(SpeakerModel.self, from: JSONSerialization.data(withJSONObject: object))
        app.speakerModelLibrary.installed = true
        let session = VoiceLabSession(app: app)
        #expect(app.speakerModelLibrary.model?.calibratedThreshold() == nil)
        #expect(session.speakerMessage == VoiceConsentError.speakerUnavailable.localizedDescription)
    }
    @Test func saveFailureCanBeWithdrawnFromTheSheetWithoutServices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root), fault: { step in
            if step == .saveRecord { throw CocoaError(.fileWriteUnknown) }
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceLabAppHTTP.self]
        let client = ElevenLabsVoiceLab(keys: VoiceLabAppKeys(), session: URLSession(configuration: configuration))
        let reconciler = VoiceOperationReconciler(store: store, client: client)
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store, reconciler: reconciler)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        json["recordId"] = session.recordID
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id)
        let operation = try await store.beginClaimedCreation(record: record.assigningVoice("pending", requiresVerification: true), requestID: UUID(), region: .default, at: Date())
        _ = try await store.transition(operation.id, to: .dispatched, at: Date())
        _ = try await store.transition(operation.id, to: .created, at: Date(), remoteVoiceID: record.voiceId, requiresVerification: false)
        await store.releaseOperation(operation.id)
        await #expect(throws: (any Error).self) { try await reconciler.reconcile(force: true) }
        session.unsavedRecord = record; session.showEnrollment = true
        await session.cancelEnrollment()
        #expect(session.unsavedRecord == nil && !session.showEnrollment)
        #expect(try await store.operations().isEmpty)
        #expect(try await store.load(record.id).status == .deleted)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(record.id)/statement.wav").path))
    }
    @Test func journalRowsRemainVisibleWithoutARecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceConsentStore(locations: locations(root))
        let app = AppModel(); let session = VoiceLabSession(app: app, store: store)
        let wav = try VoiceTrainingAudio.wav([Float](repeating: 0.1, count: 5 * 48_000))
        let shared = try SharedResources.locate()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shared.root.appendingPathComponent("fixtures/voice-lab/consent-record.json"))) as? [String: Any])
        var statement = try #require(json["statement"] as? [String: Any]); statement["audioSha256"] = VoiceLabFingerprint.bytes(wav); json["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let operation = try await store.beginDeletion(record.id, region: .default, at: Date())
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("\(record.id)/record.json"))
        await session.load(recover: false)
        #expect(session.records.isEmpty)
        #expect(session.operations.map(\.id) == [operation.id])
        #expect(session.operations.first?.displayState == "Removing…")
    }
}

@MainActor private final class SessionRecoveryBarrier {
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var done = false
    var cancelled = false
    func pause() async {
        await withCheckedContinuation { release = $0; arrived = true; arrival?.resume(); arrival = nil }
        cancelled = Task.isCancelled; done = true; completion?.resume(); completion = nil
    }
    func wait() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
    func resume() { release?.resume(); release = nil }
    func finished() async { if !done { await withCheckedContinuation { completion = $0 } } }
}

private struct VoiceLabAppKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "synthetic-journal-ui-key" }
}
private final class VoiceLabAppHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.httpMethod == "DELETE")
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
