import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

private actor LipsyncImportBarrier {
    private var entered = false
    private var waiter: TestContinuation<Void>?
    private var arrival: TestContinuation<Void>?
    func block() async {
        entered = true; arrival?.resume(); arrival = nil
        await withTestDeadline { waiter = $0 }
    }
    func waitUntilEntered() async { if !entered { await withTestDeadline { arrival = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}

private actor LipsyncImportHTTP: LipsyncHTTPClient {
    let bytes: Data
    let barrier: LipsyncImportBarrier?
    private(set) var deletions = 0
    init(bytes: Data, barrier: LipsyncImportBarrier? = nil) { self.bytes = bytes; self.barrier = barrier }
    func send(_ request: URLRequest, limit: Int, permit: VoiceDispatchPermit?) async throws -> LipsyncHTTPResponse {
        if let permit { try permit.start {} }
        let id = "11111111-2222-4333-8444-555555555555"
        let prefix = "https://queue.fal.run/fal-ai/latentsync/requests/\(id)"
        let body: String
        if request.httpMethod == "POST" {
            body = "{\"request_id\":\"\(id)\",\"status_url\":\"\(prefix)/status\",\"response_url\":\"\(prefix)\",\"cancel_url\":\"\(prefix)/cancel\"}"
        } else if request.httpMethod == "PUT" {
            return .init(status: 202, body: Data(#"{"status":"CANCELLATION_REQUESTED"}"#.utf8))
        } else if request.httpMethod == "DELETE" {
            deletions += 1
            body = #"{"cdn_delete_results":[{"link":"https://v3.fal.media/files/fixture/output.mp4","exception":null}]}"#
        } else if request.url?.path.hasSuffix("/status") == true {
            body = #"{"status":"COMPLETED"}"#
        } else {
            body = "{\"video\":{\"url\":\"https://v3.fal.media/files/fixture/output.mp4\",\"content_type\":\"video/mp4\",\"file_size\":\(bytes.count)}}"
        }
        return .init(status: 200, body: Data(body.utf8))
    }
    func download(_ request: URLRequest, to file: URL, limit: Int) async throws {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        if let barrier { await barrier.block() }
        try bytes.write(to: file)
    }
}

private struct LipsyncImportKeys: KeyProvider {
    func key(for provider: String) async throws -> String? { "synthetic-import-fixture-key" }
}

@Suite("Lip-sync result import transaction", .timeLimit(.minutes(1)))
struct LipsyncResultImporterTests {
    private let projectID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lipsync-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func prepare(root: URL, http: LipsyncImportHTTP) async throws -> (FalLipsyncProvider, LipsyncQuote, LipsyncJob) {
        let prices = try VoiceLabPriceCatalog.load(shared: SharedResources(root: FixtureLoader.sharedRoot()))
        let provider = FalLipsyncProvider(keys: LipsyncImportKeys(), prices: prices, http: http,
                                         logger: RedactingLogger(homeDirectory: "/synthetic-home"), now: { Date(timeIntervalSince1970: 1_793_577_600) },
                                         monotonic: { .zero }, sleep: { _ in })
        func input(video: Bool) throws -> LipsyncSignedInput {
            let text = "https://fixture-bucket.s3.us-east-1.amazonaws.com/\(video ? "window.mp4" : "mixed.wav")"
                + "?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=fixture&X-Amz-Date=20261102T000000Z"
                + "&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=\(String(repeating: "0", count: 64))&versionId=fixture-version"
            return try LipsyncSignedInput(url: URL(string: text)!, sha256: String(repeating: "a", count: 64),
                                          durationSeconds: 4, contentType: video ? "video/mp4" : "audio/wav", byteCount: 1_200)
        }
        let quote = try await provider.quote(model: provider.models[0], video: input(video: true), audio: input(video: false),
                                              options: .init(syncMode: .cutOff), fps: 30)
        let store = VoiceConsentStore(locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path], home: root))
        let wav = VoiceLabAssetStore.wavHeader(frames: 240_000, sampleRate: 48_000) + Data(repeating: 0, count: 480_000)
        var object = try #require(JSONSerialization.jsonObject(with: FixtureLoader.data("fixtures/voice-lab/consent-record.json")) as? [String: Any])
        var statement = try #require(object["statement"] as? [String: Any])
        statement["audioSha256"] = SpeechSHA256.hex(wav); object["statement"] = statement
        let record = try JSONDecoder().decode(VoiceConsentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        try await store.saveStatement(wav, recordID: record.id); try await store.save(record)
        let approval = try await provider.approve(quote, consentStore: store, recordID: record.id, acceptsPaidJob: true, acceptsMediaTransfer: true)
        return (provider, quote, try await provider.submit(quote, approval: approval))
    }

    @Test func existingSyntheticVideoIsValidatedHashedAndImportedWithoutProjectMutation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try FixtureLoader.data("fixtures/media/counter-1080p.mp4")
        let http = LipsyncImportHTTP(bytes: bytes), (provider, quote, job) = try await prepare(root: root, http: http)
        let result = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                                   paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        #expect(try Data(contentsOf: result.url) == bytes)
        #expect(result.asset.sha256 == SpeechSHA256.hex(bytes)); #expect(result.provenance.outputSHA256 == result.asset.sha256)
        #expect(result.provenance.requestID == job.remoteID); #expect(result.provenance.quoteID == quote.id)
        #expect(result.asset.file == "\(projectID)/\(result.asset.id).mp4")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectID).path) == ["\(result.asset.id).mp4"])
        #expect(await http.deletions == 1)
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .completed)
    }

    @Test func invalidDownloadedMediaRemovesScratchAndUnpublishedResult() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncImportHTTP(bytes: Data("this is not an MP4".utf8))
        let (provider, quote, job) = try await prepare(root: root, http: http)
        await #expect(throws: LipsyncError.invalidMedia) {
            _ = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                               paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectID).path).isEmpty)
        #expect(await http.deletions == 1)
    }

    @Test func cancelDuringDownloadSuppressesLateFileAndImportedRecipe() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let barrier = LipsyncImportBarrier()
        let http = LipsyncImportHTTP(bytes: try FixtureLoader.data("fixtures/media/counter-1080p.mp4"), barrier: barrier)
        let (provider, quote, job) = try await prepare(root: root, http: http)
        let task = Task {
            try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                          paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        }
        await barrier.waitUntilEntered()
        await provider.cancel(job)
        await barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectID).path).isEmpty)
        #expect(await provider.status(quoteID: quote.id)?.billing.mayBill == true)
    }
}
