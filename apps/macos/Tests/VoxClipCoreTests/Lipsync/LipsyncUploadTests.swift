#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

@Suite struct LipsyncUploadTests {
    private func files(_ root: URL) throws -> (LipsyncUploadFile, LipsyncUploadFile) {
        let video = root.appendingPathComponent("window.mp4")
        let audio = root.appendingPathComponent("mixed.wav")
        try Data([0, 0, 0, 12] + Array("ftypisom".utf8)).write(to: video)
        try VoiceLabRequestFixtures.wav(rate: 48_000, frames: 144_000, fill: 400).write(to: audio)
        return try (LipsyncUploadFile(file: video, durationSeconds: 3, contentType: "video/mp4"),
            LipsyncUploadFile(file: audio, durationSeconds: 3, contentType: "audio/wav"))
    }

    private var initiate: String {
        #"{"upload_url":"https://storage.fal.ai/upload/fixture","file_url":"https://v3.fal.media/files/fixture/input.mp4"}"#
    }

    @Test func approvedUploadUsesDocumentedRetentionAndNeverSendsKeyToPut() async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (video, audio) = try files(root)
        let (store, record) = try await LipsyncProviderFixtures.consent(root)
        let http = LipsyncFixtureHTTP([.json(200, initiate), .json(200, ""), .json(200, initiate), .json(204, ""),
            .json(200, LipsyncProviderFixtures.receipt(app: "fal-ai/sync-lipsync"))])
        let provider = try LipsyncProviderFixtures.provider(http)
        let (quote, approval) = try await provider.prepareApprovedUpload(video: video, audio: audio,
            options: .init(syncMode: .cutOff), fps: 30, consentStore: store, recordID: record,
            acceptsPaidJob: true, acceptsMediaTransfer: true)
        #expect(quote.model == provider.rewriteModel)
        #expect(quote.estimate.usd == Decimal(string: "0.4"))
        _ = try await provider.submit(quote, approval: approval)
        let requests = await http.requests
        #expect(requests.count == 5)
        for index in [0, 2] {
            #expect(requests[index].url?.absoluteString == "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")
            #expect(requests[index].value(forHTTPHeaderField: "Authorization") != nil)
            #expect(requests[index].value(forHTTPHeaderField: "X-Fal-Object-Lifecycle") == "{\"expiration_duration_seconds\":3600}")
        }
        for index in [1, 3] {
            #expect(requests[index].httpMethod == "PUT")
            #expect(requests[index].value(forHTTPHeaderField: "Authorization") == nil)
            #expect(requests[index].httpBody?.isEmpty == false)
        }
        #expect(requests[4].value(forHTTPHeaderField: "X-Fal-Object-Lifecycle-Preference") != nil)
        let requestBody = try #require(requests[4].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["sync_mode"] as? String == "cut_off")
    }

    @Test func missingInlineApprovalDoesNotUpload() async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (video, audio) = try files(root)
        let (store, record) = try await LipsyncProviderFixtures.consent(root)
        let http = LipsyncFixtureHTTP([]), provider = try LipsyncProviderFixtures.provider(http)
        await #expect(throws: LipsyncError.approvalRequired) {
            _ = try await provider.prepareApprovedUpload(video: video, audio: audio, options: .init(syncMode: .cutOff),
                fps: 30, consentStore: store, recordID: record, acceptsPaidJob: false, acceptsMediaTransfer: true)
        }
        #expect(await http.requests.isEmpty)
    }

    @Test func diagnosticUsesOnlyTypedSafeFieldsAndRefusesUserLibrary() async throws {
        #expect(LipsyncDiagnostic(environment: [:]) == nil)
        #expect(LipsyncDiagnostic(environment: ["VOXCLIP_DATA_DIR": "/Users/example/Library/Application Support/VoxClip"]) == nil)
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostic = try #require(LipsyncDiagnostic(environment: ["VOXCLIP_DATA_DIR": root.path]))
        await diagnostic.record(.init(stage: .failure, requestID: "not-a-uuid-secret", status: 503, bytes: 123, error: .network))
        let diagnosticURL = await diagnostic.url
        let line = try Data(contentsOf: diagnosticURL)
        let event = try JSONDecoder().decode(LipsyncDiagnosticEvent.self, from: line)
        #expect(event.requestID == nil && event.status == 503 && event.bytes == 123)
        #expect(!String(decoding: line, as: UTF8.self).contains("secret"))
    }
}
#endif
