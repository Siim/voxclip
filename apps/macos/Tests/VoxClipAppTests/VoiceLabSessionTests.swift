import Foundation
import Testing
@testable import VoxClipCore
import VoxClipMedia
@testable import VoxClip

@Suite("Headless Voice Lab session", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXCLIP_DATA_DIR"] != nil, "Use an isolated VOXCLIP_DATA_DIR for app-model tests; no windows or provider requests are opened."))
@MainActor struct VoiceLabSessionTests {
    private func locations(_ root: URL) -> DataLocations {
        DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path])
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
}
