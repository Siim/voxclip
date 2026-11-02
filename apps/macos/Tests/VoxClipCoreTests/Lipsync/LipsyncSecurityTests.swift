#if DEBUG
import Darwin
import Foundation
import Testing
@testable import VoxClipCore

@Suite("Lip-sync URL and atomic-file policy", .timeLimit(.minutes(1)), .offlineFixtures)
struct LipsyncSecurityTests {
    @Test(arguments: ["localhost", "127.0.0.1", "169.254.169.254", "[::1]", "fal.media.attacker.test", "fixture-bucket.s3.us-east-1.amazonaws.com.attacker.test"])
    func signedInputsCannotPointAtPrivateOrArbitraryHosts(host: String) throws {
        #expect(throws: LipsyncError.unsafeURL) { _ = try LipsyncProviderFixtures.input(host: host) }
    }

    @Test func signedInputsRequireSignatureImmutableVersionAndKnownMime() throws {
        let valid = try LipsyncProviderFixtures.input()
        for name in ["X-Amz-Signature", "X-Amz-Date", "X-Amz-Expires", "X-Amz-Credential", "versionId"] {
            var components = URLComponents(url: valid.url, resolvingAgainstBaseURL: false)!
            components.queryItems?.removeAll { $0.name == name }
            #expect(throws: LipsyncError.unsafeURL) {
                _ = try LipsyncSignedInput(url: components.url!, sha256: valid.sha256, durationSeconds: 10, contentType: "video/mp4", byteCount: 1_200)
            }
        }
        var duplicate = URLComponents(url: valid.url, resolvingAgainstBaseURL: false)!
        duplicate.queryItems?.append(.init(name: "X-Amz-Date", value: "20261102T000000Z"))
        #expect(throws: LipsyncError.unsafeURL) { _ = try LipsyncURLPolicy.signedInputExpiry(duplicate.url!) }
        #expect(throws: LipsyncError.invalidInput) {
            _ = try LipsyncSignedInput(url: valid.url, sha256: valid.sha256, durationSeconds: 10, contentType: "application/octet-stream", byteCount: 1_200)
        }
    }

    @Test(arguments: ["http://fal.media/files/x.mp4", "https://127.0.0.1/files/x.mp4", "https://fal.media.attacker.test/files/x.mp4",
                      "https://user:password@fal.media/files/x.mp4", "https://fal.media:444/files/x.mp4", "file:///private/tmp/x.mp4",
                      "https://fal.media/files/x.mp4#fragment", "https://fal.media/elsewhere/x.mp4", "https://fal.media./files/x.mp4"])
    func resultURLRejectsSSRFAndAuthorityTricks(text: String) throws {
        #expect(throws: LipsyncError.unsafeURL) { try LipsyncURLPolicy.result(#require(URL(string: text))) }
    }

    @Test func followUpURLsMustMatchBothRequestAndRootApp() throws {
        let model = LipsyncModel(provider: "fal", id: "fal-ai/sync-lipsync/v2:lipsync-2", tier: .quality, supportsRemap: true)
        let id = LipsyncProviderFixtures.requestID
        try LipsyncURLPolicy.queue(URL(string: "https://queue.fal.run/fal-ai/sync-lipsync/requests/\(id)/status")!, model: model, requestID: id, suffix: "/status")
        for path in ["fal-ai/sync-lipsync/v2/requests/\(id)/status", "fal-ai/other/requests/\(id)/status", "fal-ai/sync-lipsync/requests/different/status"] {
            #expect(throws: LipsyncError.unsafeURL) {
                try LipsyncURLPolicy.queue(URL(string: "https://queue.fal.run/\(path)")!, model: model, requestID: id, suffix: "/status")
            }
        }
    }

    @Test func stagingDoesNotClobberExistingFileOrFollowSymlinks() throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("result.mp4")
        try Data("original".utf8).write(to: destination)
        do {
            let staged = try LipsyncStagedFile(destination: destination)
            #expect(throws: LipsyncError.unsafeFile) { try staged.commit() }
        }
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        #expect(throws: LipsyncError.unsafeFile) { _ = try LipsyncStagedFile(destination: linked.appendingPathComponent("other.mp4")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".lipsync-") })
    }

    @Test func abandonedStagingAndSuccessfulPublishLeaveNoPartialFiles() throws {
        let root = try LipsyncProviderFixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("result.mp4")
        do { let staged = try LipsyncStagedFile(destination: destination); staged.discard() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        do {
            let staged = try LipsyncStagedFile(destination: destination)
            let payload = Data("fixture".utf8)
            #expect(payload.withUnsafeBytes { write(staged.descriptor, $0.baseAddress, $0.count) } == payload.count)
            try staged.commit()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["result.mp4"])
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
#endif
