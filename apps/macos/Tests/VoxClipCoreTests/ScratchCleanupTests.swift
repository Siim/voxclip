import Foundation
import Testing
import Darwin
@testable import VoxClipCore

@Suite("Owned stale scratch") struct ScratchCleanupTests {
    private var deadOwner: ScratchCleanup.ProcessOwner { .init(pid: Int32.max, startSeconds: 1, startMicroseconds: 0) }

    @Test func legacyExternalPartialsAreNeverDeletedOrRenamed() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("Exports"), registry = root.appendingPathComponent("Scratch")
        let work = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(exports, "voxclip-partial-\(UUID().uuidString).partial")
        let expected = try Data(contentsOf: partial)
        func item(_ path: URL) throws -> [String: Any] {
            var attributes = stat()
            try #require(lstat(path.path, &attributes) == 0)
            return ["name": path.lastPathComponent, "identity": ["device": attributes.st_dev, "inode": attributes.st_ino,
                "birthSeconds": attributes.st_birthtimespec.tv_sec, "birthNanoseconds": attributes.st_birthtimespec.tv_nsec]]
        }
        let record: [String: Any] = ["schema": "voxclip-export-scratch/3", "directory": exports.absoluteString,
            "owner": ["pid": deadOwner.pid, "startSeconds": 1, "startMicroseconds": 0],
            "work": try item(work), "partials": [try item(partial)]]
        let journal = try file(registry, UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: record).write(to: journal)
        let names = try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted()
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root)
        #expect((try? Data(contentsOf: partial)) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).sorted() == names)
        #expect(FileManager.default.fileExists(atPath: journal.path))
    }

    @Test func privateDirectoryLeasePinsOwnerIdentityAndPermissions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("Scratch")
        let owned = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: deadOwner)
        _ = try file(owned.url.appendingPathComponent("writer"), "output.tmp")
        _ = try file(owned.url, "video.partial")
        let mode = try FileManager.default.attributesOfItem(atPath: owned.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        let records = try FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)
        #expect(records.count == 1)
        let reference = records[0].appendingPathComponent("reference.json")
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reference)) as? [String: Any])
        #expect(document["schema"] as? String == "voxclip-export-scratch/4")
        #expect(document["identity"] is [String: Any] && document["owner"] is [String: Any])
        let removed = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, before: .distantPast)
        #expect(removed == [owned.url])
        #expect(!FileManager.default.fileExists(atPath: owned.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: registry.path).isEmpty)
    }

    @Test func deadOwnerIsRemovedButALiveOtherProcessIsNot() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let owner = try #require(try ScratchCleanup.processOwner(of: child.processIdentifier))
        let registry = root.appendingPathComponent("Scratch")
        let owned = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: owner)
        let partial = try file(owned.url, "video.partial")
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, before: .distantFuture)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        child.terminate(); child.waitUntilExit()
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, before: .distantPast)
        #expect(!FileManager.default.fileExists(atPath: owned.url.path))
    }

    @Test func reusedPIDWithADifferentStartTimeIsAbandoned() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var owner = try #require(try ScratchCleanup.processOwner(of: getpid()))
        owner.startMicroseconds += 1
        let owned = try ScratchCleanup.createExportDirectory(in: root, owner: owner)
        _ = try file(owned.url, "video.partial")
        _ = ScratchCleanup.sweep(registry: root.appendingPathComponent("Scratch"), cache: root, temporary: root,
                                exportDirectories: [root], before: .distantPast)
        #expect(!FileManager.default.fileExists(atPath: owned.url.path))
    }

    @Test func liveAndUnknownOwnersSurviveClockSkew() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("Scratch")
        let live = try ScratchCleanup.createExportDirectory(in: root, registry: registry)
        let unknown = try ScratchCleanup.createExportDirectory(in: root, registry: registry,
            owner: .init(pid: -1, startSeconds: 1, startMicroseconds: 0))
        for cutoff in [Date.distantPast, .distantFuture] {
            _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, exportDirectories: [root], before: cutoff)
        }
        for owned in [live, unknown] { #expect(FileManager.default.fileExists(atPath: owned.url.path)) }
        #expect(ScratchCleanup.processStart > .distantPast && ScratchCleanup.processStart <= Date())
    }

    @Test func replacementUserDirectoryAndOldPartialSurvive() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("Scratch")
        let owned = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: deadOwner)
        _ = try file(owned.url, "video.partial")
        try FileManager.default.moveItem(at: owned.url, to: root.appendingPathComponent("original-held"))
        let replacement = try file(owned.url, "user.txt")
        let legacyPartial = try file(root, "take.mp4.partial")
        let expected = try Data(contentsOf: replacement)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, exportDirectories: [root])
        #expect(try Data(contentsOf: replacement) == expected)
        #expect(FileManager.default.fileExists(atPath: legacyPartial.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: registry.path).isEmpty)
    }

    @Test func replacementAfterDirectoryOpenCannotRedirectDeletionOrRenameUserFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("Scratch")
        let owned = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: deadOwner)
        _ = try file(owned.url.appendingPathComponent("writer"), "private.tmp")
        let held = root.appendingPathComponent("original-held")
        let userFile = owned.url.appendingPathComponent("user.txt")
        let expected = Data("replacement after validated fd open".utf8)
        var opened = 0
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, afterOpening: { directory in
            opened += 1
            do {
                try FileManager.default.moveItem(at: directory, to: held)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try expected.write(to: userFile)
            } catch { Issue.record("Swap fixture failed: \(error)") }
        })
        #expect(opened == 1)
        #expect(try Data(contentsOf: userFile) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: owned.url.path) == ["user.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: held.path).isEmpty)
    }

    @Test func leasedDirectoriesRefuseSymlinksAndTraversal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("Scratch")
        let target = try file(root.appendingPathComponent("Outside"), "user.txt")
        let owned = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: deadOwner)
        let link = owned.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect((try FileManager.default.attributesOfItem(atPath: link.path)[.type]) as? FileAttributeType == .typeSymbolicLink)
        let second = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: deadOwner)
        let index = try #require(FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil).first)
        let record = index.appendingPathComponent("reference.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        document["directory"] = root.absoluteString + "../" + root.lastPathComponent + "/" + second.url.lastPathComponent
        try JSONSerialization.data(withJSONObject: document).write(to: record)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root)
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func replacedRootSymlinkAndNonPrivatePermissionsAreRefused() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("Scratch")
        let owned = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: deadOwner)
        let outside = try file(root.appendingPathComponent("Outside"), "user.txt")
        let held = root.appendingPathComponent("held")
        try FileManager.default.moveItem(at: owned.url, to: held)
        try FileManager.default.createSymbolicLink(at: owned.url, withDestinationURL: outside.deletingLastPathComponent())
        let nonPrivate = try ScratchCleanup.createExportDirectory(in: root, registry: registry, owner: deadOwner)
        let retained = try file(nonPrivate.url, "retain.partial")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonPrivate.url.path)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, exportDirectories: [root])
        #expect(try Data(contentsOf: outside) == Data("owned scratch".utf8))
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: owned.url.path) == outside.deletingLastPathComponent().path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: held.path) == [".voxclip-owner.json"])
    }

    @Test func unleasedLegacyScratchAndCompletedAssetsAreNeverAgeDeleted() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let upload = try file(root.appendingPathComponent("Cache"), "scribe-\(UUID().uuidString).multipart")
        let cli = try file(root.appendingPathComponent("voxclip-cli-\(UUID().uuidString)"), "input.json")
        let legacy = try file(root.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial"), "writer.tmp")
        let complete = try file(root, "take.mp4")
        let noLease = root.appendingPathComponent(".voxclip-export-\(UUID().uuidString)")
        let unclaimed = try file(noLease, "user.txt")
        _ = ScratchCleanup.sweep(registry: root.appendingPathComponent("Scratch"), cache: root, temporary: root,
                                exportDirectories: [root], before: .distantFuture)
        for path in [upload, cli, legacy, complete, unclaimed] { #expect(FileManager.default.fileExists(atPath: path.path)) }
    }

    @Test func recoveryBackupsAreNotAbandonedScratch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = try ScratchCleanup.createExportDirectory(in: root, owner: deadOwner, recovery: true)
        let backup = try file(owned.url, "previous.mp4")
        _ = ScratchCleanup.sweep(registry: root.appendingPathComponent("Scratch"), cache: root, temporary: root,
                                exportDirectories: [root])
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-scratch-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func file(_ directory: URL, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name)
        try Data("owned scratch".utf8).write(to: path)
        return path
    }
}
