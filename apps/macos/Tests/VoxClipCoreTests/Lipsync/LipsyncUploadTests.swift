#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

@Suite struct LipsyncUploadTests {
    private var initiate: String {
        #"{"upload_url":"https://storage.fal.ai/upload/fixture","file_url":"https://v3.fal.media/files/fixture/input.mp4"}"#
    }

    private struct MultipartVector: Decodable {
        let bytes: Int
        let parts: [Int]
    }

    @Test(arguments: [200, 403, 413, 503, 422])
    func multipartUploadKeepsSignedQueryAndCompletesBeforeSubmitting(status: Int) async throws {
        let vector = try JSONDecoder().decode(MultipartVector.self, from: Data(contentsOf: FixtureLoader.sharedRoot()
            .appendingPathComponent("fixtures/voice-lab/fal-upload-case.json")))
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, audio) = try LipsyncProviderFixtures.uploadFiles(root)
        let (store, record) = try await LipsyncProviderFixtures.consent(root)
        let url = root.appendingPathComponent("large.mp4")
        try Data([0, 0, 0, 0] + Array("ftyp".utf8)).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(vector.bytes - 1))
        try handle.write(contentsOf: Data([42]))
        try handle.close()
        let video = try LipsyncUploadFile(file: url, durationSeconds: 3, contentType: "video/mp4")
        let base = "https://storage.fal.ai/upload/window"
        let query = "?token=fixture%2Bpart&keep=1"
        let remote = "https://v3.fal.media/files/window"
        let attempts = status == 503 ? 3 : [403, 413].contains(status) ? 1 : 0
        let partReplies: [LipsyncFixtureHTTP.Reply] = attempts == 0
            ? vector.parts.indices.map { $0 == 0 ? .etag("\"header\"") : .json(200, "{\"etag\":\"body-\($0 + 1)\"}") }
            : Array(repeating: .json(status, "{}"), count: attempts)
        let http = LipsyncFixtureHTTP([.json(200, "{\"upload_url\":\"\(base)\(query)\",\"file_url\":\"\(remote)\"}")]
            + partReplies + [.json(status == 422 ? 422 : 204, ""), .json(200, initiate), .json(204, ""),
            .json(200, LipsyncProviderFixtures.receipt(app: "fal-ai/sync-lipsync"))])
        let log = LipsyncFixtureLog()
        let provider = try LipsyncProviderFixtures.provider(http, logger: log)
        func run() async throws {
            let (quote, approval) = try await provider.prepareApprovedUpload(video: video, audio: audio,
                options: .init(syncMode: .cutOff), fps: 30, consentStore: store, recordID: record,
                acceptsPaidJob: true, acceptsMediaTransfer: true)
            _ = try await provider.submit(quote, approval: approval)
        }
        if status != 200 {
            await #expect(throws: LipsyncError.http(status)) { try await run() }
            let requests = await http.requests
            if attempts > 0 {
                #expect(requests.dropFirst().compactMap { $0.url?.absoluteString } == Array(repeating: "\(base)/1\(query)", count: attempts))
                #expect(await log.messages.contains { $0.contains("stage=upload-part 1 status=\(status)") })
            } else {
                #expect(requests.count == vector.parts.count + 2 && requests.last?.url?.absoluteString == "\(base)/complete\(query)")
                #expect(await log.messages.contains { $0.contains("stage=upload-complete status=422") })
            }
            #expect(!requests.contains { $0.url?.host == "queue.fal.run" })
            return
        }
        try await run()
        let requests = await http.requests
        #expect(requests.count == vector.parts.count + 5)
        #expect(requests.first?.url?.absoluteString == "https://rest.fal.ai/storage/upload/initiate-multipart?storage_type=fal-cdn-v3")
        #expect(requests.first?.value(forHTTPHeaderField: "X-Fal-Object-Lifecycle") == "{\"expiration_duration_seconds\":3600}")
        guard requests.count == vector.parts.count + 5 else { return }
        let secrets = await log.secrets
        for (index, size) in vector.parts.enumerated() {
            let request = requests[index + 1]
            let address = "\(base)/\(index + 1)\(query)"
            #expect(request.url?.absoluteString == address && secrets.contains(address))
            #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.httpBody?.count == size)
            #expect(request.httpBody?.last == (index == vector.parts.count - 1 ? 42 : 0))
        }
        let complete = requests[vector.parts.count + 1]
        #expect(complete.url?.absoluteString == "\(base)/complete\(query)" && secrets.contains("\(base)/complete\(query)"))
        #expect(complete.httpMethod == "POST" && complete.value(forHTTPHeaderField: "Authorization") == nil)
        let completeBody = try #require(complete.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: completeBody) as? [String: [[String: Any]]])
        #expect(body["parts"]?.compactMap { $0["partNumber"] as? Int } == vector.parts.indices.map { $0 + 1 })
        #expect(body["parts"]?.compactMap { $0["etag"] as? String } == vector.parts.indices.map { $0 == 0 ? "\"header\"" : "body-\($0 + 1)" })
        let submitBody = try #require(requests.last?.httpBody)
        let submit = try #require(JSONSerialization.jsonObject(with: submitBody) as? [String: Any])
        #expect(submit["video_url"] as? String == remote)
    }

    @Test func approvedUploadUsesDocumentedRetentionAndNeverSendsKeyToPut() async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (video, audio) = try LipsyncProviderFixtures.uploadFiles(root)
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

    /// The account's slot is reserved before the uploads: while another run's job holds it, a lip sync refuses at once with
    /// nothing uploaded (before: it uploaded both files, then waited 5 minutes for the slot and failed).
    @Test func aHeldSlotRefusesBeforeAnyUpload() async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LipsyncFixtureClock(), queue = LipsyncProviderFixtures.queue(clock)
        let other = try LipsyncProviderFixtures.provider(LipsyncFixtureHTTP([.json(200, LipsyncProviderFixtures.receipt())]), clock: clock, queue: queue)
        let running = try await LipsyncProviderFixtures.quote(other)
        _ = try await other.submit(running, approval: LipsyncProviderFixtures.approval(other, quote: running, root: root))
        let own = root.appendingPathComponent("own")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: false)
        let (video, audio) = try LipsyncProviderFixtures.uploadFiles(own)
        let (store, record) = try await LipsyncProviderFixtures.consent(own)
        let http = LipsyncFixtureHTTP([]), provider = try LipsyncProviderFixtures.provider(http, clock: clock, queue: queue)
        await #expect(throws: LipsyncError.busy) {
            _ = try await provider.prepareApprovedUpload(video: video, audio: audio, options: .init(syncMode: .cutOff),
                fps: 30, consentStore: store, recordID: record, acceptsPaidJob: true, acceptsMediaTransfer: true)
        }
        #expect(await http.requests.isEmpty)
    }

    /// A failed upload gives the reserved slot back, so the next lip sync can start.
    @Test func aFailedUploadGivesTheSlotBack() async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (video, audio) = try LipsyncProviderFixtures.uploadFiles(root)
        let (store, record) = try await LipsyncProviderFixtures.consent(root)
        let clock = LipsyncFixtureClock(), queue = LipsyncProviderFixtures.queue(clock)
        let provider = try LipsyncProviderFixtures.provider(LipsyncFixtureHTTP([.json(200, initiate), .json(403, "")]), clock: clock, queue: queue)
        await #expect(throws: LipsyncError.http(403)) {
            _ = try await provider.prepareApprovedUpload(video: video, audio: audio, options: .init(syncMode: .cutOff),
                fps: 30, consentStore: store, recordID: record, acceptsPaidJob: true, acceptsMediaTransfer: true)
        }
        #expect(!(await queue.isHeld(account: "fal")))
    }

    @Test func missingInlineApprovalDoesNotUpload() async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (video, audio) = try LipsyncProviderFixtures.uploadFiles(root)
        let (store, record) = try await LipsyncProviderFixtures.consent(root)
        let http = LipsyncFixtureHTTP([]), provider = try LipsyncProviderFixtures.provider(http)
        await #expect(throws: LipsyncError.approvalRequired) {
            _ = try await provider.prepareApprovedUpload(video: video, audio: audio, options: .init(syncMode: .cutOff),
                fps: 30, consentStore: store, recordID: record, acceptsPaidJob: false, acceptsMediaTransfer: true)
        }
        #expect(await http.requests.isEmpty)
    }

    @Test(arguments: [false, true]) func uploadFailuresNeverSendPaidPOST(afterInitiation: Bool) async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (video, audio) = try LipsyncProviderFixtures.uploadFiles(root)
        let (store, record) = try await LipsyncProviderFixtures.consent(root)
        let http = LipsyncFixtureHTTP(afterInitiation ? [.json(200, initiate), .json(403, "not logged")] : [.json(200, "{}")])
        let provider = try LipsyncProviderFixtures.provider(http), diagnostic = LipsyncFixtureDiagnostic()
        await provider.setDiagnostic(diagnostic)
        let expected: LipsyncError = afterInitiation ? .http(403) : .invalidResponse
        await #expect(throws: expected) {
            _ = try await provider.prepareApprovedUpload(video: video, audio: audio, options: .init(syncMode: .cutOff),
                fps: 30, consentStore: store, recordID: record, acceptsPaidJob: true, acceptsMediaTransfer: true)
        }
        let requests = await http.requests
        #expect(requests.map(\.httpMethod) == (afterInitiation ? ["POST", "PUT"] : ["POST"]))
        #expect(!requests.contains { $0.url?.host == "queue.fal.run" })
        let events = await diagnostic.events
        let failure = try #require(events.last)
        #expect(failure.stage == (afterInitiation ? .upload : .uploadInitiate))
        #expect(failure.status == (afterInitiation ? 403 : 200))
        #expect(failure.error == String(describing: expected))
        #expect(failure.requestID == nil)
        let details = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!details.contains("fixture"))
        #expect(!details.contains("not logged"))
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
