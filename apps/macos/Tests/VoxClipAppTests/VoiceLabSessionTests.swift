#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore
@_spi(Testing) @testable import VoxClipMedia
@testable import VoxClip

@Suite("Headless Voice Lab session", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows or provider requests are opened."))
@MainActor struct VoiceLabSessionTests {
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
