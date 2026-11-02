import Darwin
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite("Context capture private asset lifecycle", .offlineFixtures)
struct ContextDemoCaptureFileTests {
    private let projectID = "11111111-1111-4111-8111-111111111111"
    private let bytes = Data([0, 0, 0, 24] + Array("ftypmp42".utf8) + [0, 0, 0, 0])

    private func root() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("voxclip-context-files-\(UUID().uuidString)")
    }

    @Test func privateScopesPublishExclusivelyAndDiscardOnlyOwnedFiles() throws {
        let root = root(), store = ContextDemoAssetStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try store.create(projectId: projectID)
        var information = stat()
        #expect(lstat(file.directory.path, &information) == 0 && information.st_mode & 0o777 == 0o700)
        try bytes.write(to: file.partialURL)
        #expect(try store.bytes(file) == bytes.count)
        let digest = try store.publish(file)
        try store.complete(file)
        #expect(try store.verify(relativePath: file.relativePath, expected: digest) == file.finalURL)
        let unrelated = file.finalURL.deletingLastPathComponent().appendingPathComponent("unrelated.mp4")
        try Data("preserve".utf8).write(to: unrelated)
        try store.remove(relativePath: file.relativePath)
        #expect(try Data(contentsOf: unrelated) == Data("preserve".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.finalURL.path))
    }

    @Test func occupiedFinalNameIsNotOverwrittenOrDeletedByFailedPublicationCleanup() throws {
        let root = root(), store = ContextDemoAssetStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try store.create(projectId: projectID)
        try bytes.write(to: file.partialURL)
        let previous = Data("existing output must survive".utf8)
        try previous.write(to: file.finalURL)
        #expect(throws: ContextDemoCaptureError.unsafeStorage) { try store.publish(file) }
        try store.remove(file)
        #expect(try Data(contentsOf: file.finalURL) == previous)
    }

    @Test func sameSizedTamperingFailsDigestReadback() throws {
        let root = root(), store = ContextDemoAssetStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try store.create(projectId: projectID)
        try bytes.write(to: file.partialURL)
        let digest = try store.publish(file)
        try store.complete(file)
        var replacement = bytes
        replacement[replacement.count - 1] = 1
        try replacement.write(to: file.finalURL)
        #expect(throws: ContextDemoCaptureError.invalidRecording) {
            try store.verify(relativePath: file.relativePath, expected: digest)
        }
    }

    @Test func symbolicAndHardLinkedPartialFilesAreRejectedWithoutTouchingTarget() throws {
        for symbolic in [false, true] {
            let root = root(), store = ContextDemoAssetStore(rootURL: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = try store.create(projectId: projectID)
            let original = root.appendingPathComponent("unrelated.mp4")
            try bytes.write(to: original)
            if symbolic { try FileManager.default.createSymbolicLink(at: file.partialURL, withDestinationURL: original) }
            else { try FileManager.default.linkItem(at: original, to: file.partialURL) }
            #expect(throws: ContextDemoCaptureError.unsafeStorage) { try store.publish(file) }
            try store.remove(file)
            #expect(try Data(contentsOf: original) == bytes)
        }
    }

    @Test func linkedAssetDirectoryAndTraversalAreRejected() throws {
        let root = root(), destination = self.root(), store = ContextDemoAssetStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("context-demo"), withDestinationURL: destination)
        #expect(throws: ContextDemoCaptureError.unsafeStorage) { try store.create(projectId: projectID) }
        for relative in ["../escape.mp4", "/tmp/escape.mp4", "context-demo/\(projectID)/../escape.mp4"] {
            #expect(throws: ContextDemoCaptureError.unsafeStorage) { try store.remove(relativePath: relative) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func sparseOversizedFileFailsBeforeReadingItsPayload() throws {
        let root = root(), store = ContextDemoAssetStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try store.create(projectId: projectID)
        let descriptor = Darwin.open(file.partialURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(ftruncate(descriptor, off_t(ContextDemoCaptureLimits.maximumBytes + 1)) == 0)
        #expect(throws: ContextDemoCaptureError.fileBudgetExceeded) { try store.bytes(file) }
        #expect(throws: ContextDemoCaptureError.fileBudgetExceeded) { try store.publish(file) }
        try store.remove(file)
    }

    @Test func replacedOperationDirectoryCannotBeAcceptedAsOurScope() throws {
        let root = root(), store = ContextDemoAssetStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try store.create(projectId: projectID)
        try FileManager.default.moveItem(at: file.directory, to: root.appendingPathComponent("displaced-operation"))
        try FileManager.default.createDirectory(at: file.directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file.partialURL)
        #expect(throws: ContextDemoCaptureError.unsafeStorage) { try store.publish(file) }
    }

    @Test func arbitraryNonMP4BytesNeverPublish() throws {
        let root = root(), store = ContextDemoAssetStore(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try store.create(projectId: projectID)
        try Data("not an MPEG4 recording".utf8).write(to: file.partialURL)
        #expect(throws: ContextDemoCaptureError.invalidRecording) { try store.publish(file) }
        try store.remove(file)
        #expect(!FileManager.default.fileExists(atPath: file.finalURL.path))
    }
}
