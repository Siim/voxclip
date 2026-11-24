import Foundation
import Testing
@testable import VoxClipCore

@Suite struct VoxConvoPublishingTests {
    @Test func scopedDeviceApprovalAndPublishUseOnlyTheDocumentedEndpoints() async throws {
        let server = try StandIn("ok")
        defer { server.stop() }
        let waits = Waits()
        let api = VoxConvoPublishing(apiOrigin: server.origin, pause: { await waits.add($0) })
        let code = try await api.beginConnection()
        #expect(code.displayCode == "ABCD-1234")
        #expect(code.verificationURL.absoluteString == "https://voxconvo.com/device?user_code=ABCD1234")
        let session = try await api.waitForApproval(code)
        #expect(await waits.values == [5, 5, 10])
        let account = try await api.account(session: session)
        #expect(account?.handle == "creator")
        let file = try server.video()
        let input = draft(file)
        let upload = try await api.prepare(input, session: session) { _ in }
        let url = try await api.post(input, uploaded: upload, session: session)
        #expect(url.absoluteString == "https://voxconvo.com/post/1")
        try await api.disconnect(session: session)
    }

    @Test func finalPostIsNotRetriedAndExplicitRetryReusesTheUpload() async throws {
        let server = try StandIn("uncertain")
        defer { server.stop() }
        let api = VoxConvoPublishing(apiOrigin: server.origin, pause: { _ in })
        let session = try await api.waitForApproval(api.beginConnection())
        let input = draft(try server.video())
        let upload = try await api.prepare(input, session: session) { _ in }
        await #expect(throws: VoxConvoPublishError.postUnconfirmed) { _ = try await api.post(input, uploaded: upload, session: session) }
        #expect(try await api.post(input, uploaded: upload, session: session).lastPathComponent == "2")
    }

    @Test(arguments: ["denied": VoxConvoPublishError.denied, "expired": .expired, "wrong-scope": .invalidResponse])
    func disallowedDeviceApprovalNeverYieldsASession(scenario: String, expected: VoxConvoPublishError) async throws {
        let server = try StandIn(scenario)
        defer { server.stop() }
        let api = VoxConvoPublishing(apiOrigin: server.origin, pause: { _ in })
        let code = try await api.beginConnection()
        await #expect(throws: expected) { _ = try await api.waitForApproval(code) }
    }

    @Test func publishingDoesNotFollowRedirects() async throws {
        let server = try StandIn("redirect")
        defer { server.stop() }
        let api = VoxConvoPublishing(apiOrigin: server.origin, pause: { _ in })
        let session = try await api.waitForApproval(api.beginConnection())
        let input = draft(try server.video())
        let upload = try await api.prepare(input, session: session) { _ in }
        await #expect(throws: VoxConvoPublishError.postUnconfirmed) { _ = try await api.post(input, uploaded: upload, session: session) }
    }

    private func draft(_ file: URL) -> VoxConvoPublishDraft {
        VoxConvoPublishDraft(file: file, duration: 2, text: "Ready to share.", transcript: "Edited words",
            words: [CaptionWord(id: "w", text: "Edited", start: 0, end: 0.5)])
    }

    private actor Waits {
        var values: [Int] = []
        func add(_ seconds: Int) { values.append(seconds) }
    }

    private final class StandIn {
        let process = Process()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let origin: URL

        init(_ scenario: String) throws {
            let script = try SharedResources.locate().root.appendingPathComponent("fixtures/device-flow/voxconvo-stand-in.py")
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, scenario]
            process.standardOutput = pipe
            try process.run()
            try pipe.fileHandleForWriting.close()
            do {
                var line = Data()
                while let byte = try pipe.fileHandleForReading.read(upToCount: 1), byte != Data([10]), line.count < 8 { line.append(byte) }
                let port = try #require(UInt16(String(decoding: line, as: UTF8.self)))
                origin = try #require(URL(string: "http://127.0.0.1:\(port)"))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                if process.isRunning { process.terminate() }
                throw error
            }
        }

        func video() throws -> URL {
            let file = directory.appendingPathComponent("finished.mp4")
            try Data("fixture media bytes".utf8).write(to: file)
            return file
        }

        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
