import Foundation
import Testing
@testable import VoxClipCore

@Suite("Owned stale scratch") struct ScratchCleanupTests {
    private var deadOwner: ScratchCleanup.ProcessOwner { .init(pid: Int32.max, startSeconds: 1, startMicroseconds: 0) }

    @Test func leasedItemsStillRefuseSymlinksAndTraversal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("Exports"), registry = root.appendingPathComponent("Scratch")
        let work = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(exports, "voxclip-partial-\(UUID().uuidString).partial")
        let record = try ScratchCleanup.registerExport(workDirectory: work, partials: [partial], registry: registry, owner: deadOwner)
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent(partial.lastPathComponent)
        try FileManager.default.moveItem(at: partial, to: target)
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: target)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root)
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect((try FileManager.default.attributesOfItem(atPath: partial.path)[.type]) as? FileAttributeType == .typeSymbolicLink)
        #expect(!FileManager.default.fileExists(atPath: record.path))

        let secondWork = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(secondWork, "writer.tmp")
        let secondPartial = try file(exports, "voxclip-partial-\(UUID().uuidString).partial")
        let secondRecord = try ScratchCleanup.registerExport(workDirectory: secondWork, partials: [secondPartial], registry: registry, owner: deadOwner)
        let secondTarget = outside.appendingPathComponent(secondPartial.lastPathComponent)
        try FileManager.default.moveItem(at: secondPartial, to: secondTarget)
        let contents = try Data(contentsOf: secondRecord)
        let parsed = try JSONSerialization.jsonObject(with: contents)
        var document = try #require(parsed as? [String: Any])
        var items = try #require(document["partials"] as? [[String: Any]])
        items[0]["name"] = "../Outside/" + secondTarget.lastPathComponent
        document["partials"] = items
        try JSONSerialization.data(withJSONObject: document).write(to: secondRecord)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root)
        #expect(FileManager.default.fileExists(atPath: secondTarget.path))
        #expect(FileManager.default.fileExists(atPath: secondWork.path))
        #expect(!FileManager.default.fileExists(atPath: secondRecord.path))
    }

    @Test func deadOwnerIsRemovedButALiveOtherProcessIsNot() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let observed = try ScratchCleanup.processOwner(of: child.processIdentifier)
        let owner = try #require(observed)
        let work = root.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(root, "voxclip-partial-\(UUID().uuidString).partial")
        let registry = root.appendingPathComponent("Scratch")
        let record = try ScratchCleanup.registerExport(workDirectory: work, partials: [partial], registry: registry, owner: owner)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, exportDirectories: [root], before: .distantFuture)
        for path in [partial, work, record] { #expect(FileManager.default.fileExists(atPath: path.path)) }
        child.terminate(); child.waitUntilExit()
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, before: .distantPast)
        for path in [partial, work, record] { #expect(!FileManager.default.fileExists(atPath: path.path)) }
    }

    @Test func reusedPIDWithADifferentStartTimeIsAbandoned() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let observed = try ScratchCleanup.processOwner(of: ProcessInfo.processInfo.processIdentifier)
        var owner = try #require(observed)
        owner.startSeconds -= 1
        let work = root.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(root, "voxclip-partial-\(UUID().uuidString).partial")
        let registry = root.appendingPathComponent("Scratch")
        let record = try ScratchCleanup.registerExport(workDirectory: work, partials: [partial], registry: registry, owner: owner)
        _ = ScratchCleanup.sweep(registry: registry, cache: root, temporary: root, before: .distantPast)
        for path in [partial, work, record] { #expect(!FileManager.default.fileExists(atPath: path.path)) }
    }
    @Test func liveOwnerSurvivesASecondInstanceAndClockSkew() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("Exports"), registry = root.appendingPathComponent("Scratch")
        let work = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(exports, "voxclip-partial-\(UUID().uuidString).partial")
        let record = try ScratchCleanup.registerExport(workDirectory: work, partials: [partial], registry: registry)
        _ = ScratchCleanup.sweep(registry: registry, cache: root.appendingPathComponent("Cache"), temporary: root,
            exportDirectories: [exports], before: .distantFuture)
        for path in [work, partial, record] { #expect(FileManager.default.fileExists(atPath: path.path)) }
    }
    @Test func replacementUserFileSurvivesAStaleExportJournal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("Exports"), registry = root.appendingPathComponent("Scratch")
        let work = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(exports, "voxclip-partial-\(UUID().uuidString).partial")
        _ = try ScratchCleanup.registerExport(workDirectory: work, partials: [partial], registry: registry, owner: deadOwner)
        try FileManager.default.moveItem(at: partial, to: exports.appendingPathComponent("original-held.mp4"))
        let replacement = Data("user replacement, never VoxClip scratch".utf8)
        try replacement.write(to: partial)
        _ = ScratchCleanup.sweep(registry: registry, cache: root.appendingPathComponent("Cache"), temporary: root,
            before: Date().addingTimeInterval(100))
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect((try? Data(contentsOf: partial)) == replacement)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-scratch-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func file(_ directory: URL, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("owned fixture".utf8).write(to: url)
        return url
    }

    @Test func unleasedLegacyScratchAndCompletedAssetsAreNeverAgeDeleted() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Cache"), temporary = root.appendingPathComponent("Temp")
        let entry = cache.appendingPathComponent(String(repeating: "a", count: 64))
        let staleUpload = try file(entry, "scribe-\(UUID().uuidString).multipart")
        let transcript = try file(entry, "transcript.json"), audio = try file(entry, "audio-16k.wav")
        let lookalike = try file(entry, "scribe-not-owned.multipart")
        let unowned = try file(cache.appendingPathComponent("uploads"), "scribe-\(UUID().uuidString).multipart")
        let cli = temporary.appendingPathComponent("VoxClip/cli/\(UUID().uuidString)")
        _ = try file(cli, "stdin.txt")
        let freshCLI = temporary.appendingPathComponent("VoxClip/cli/\(UUID().uuidString)")
        let freshInput = try file(freshCLI, "stdin.txt")
        let exports = root.appendingPathComponent("Exports")
        let legacyWork = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(legacyWork, "writer.tmp")
        let ambiguousPartial = try file(exports, "user-video.mp4.partial")
        let completed = try file(exports, "user-video.mp4")
        let cutoff = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(1)], ofItemAtPath: freshInput.path)
        let removed = ScratchCleanup.sweep(registry: root.appendingPathComponent("Scratch"), cache: cache, temporary: temporary,
            exportDirectories: [exports], before: cutoff)
        let removedNames = Set(removed.map(\.lastPathComponent))
        #expect(removed.isEmpty && removedNames.isEmpty)
        for stale in [staleUpload, cli, legacyWork] { #expect(FileManager.default.fileExists(atPath: stale.path)) }
        for kept in [transcript, audio, lookalike, unowned, freshCLI, freshInput, ambiguousPartial, completed] {
            #expect(FileManager.default.fileExists(atPath: kept.path), "Must retain \(kept.lastPathComponent)")
        }
        #expect(ScratchCleanup.processStart > .distantPast && ScratchCleanup.processStart <= Date())
    }

    @Test func deadOwnerCleanupIgnoresWallClockAndModificationDates() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("Exports"), registry = root.appendingPathComponent("Scratch")
        let work = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(exports, "take.mp4.partial"), sidecar = try file(exports, "take.srt.partial")
        let complete = try file(exports, "take.mp4")
        let record = try ScratchCleanup.registerExport(workDirectory: work, partials: [partial, sidecar], registry: registry, owner: deadOwner)
        let cutoff = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(1)], ofItemAtPath: partial.path)
        _ = ScratchCleanup.sweep(registry: registry, cache: root.appendingPathComponent("Cache"), temporary: root, before: cutoff)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: record.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path) && !FileManager.default.fileExists(atPath: work.path))
        #expect(FileManager.default.fileExists(atPath: complete.path))
    }

    @Test func rejectsLinksAndTraversalWithoutRemovingTargets() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Cache"), external = root.appendingPathComponent("Outside")
        let target = try file(external, "scribe-\(UUID().uuidString).multipart")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent(String(repeating: "a", count: 64)), withDestinationURL: external)
        let entry = cache.appendingPathComponent(String(repeating: "b", count: 64))
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        let link = entry.appendingPathComponent("scribe-\(UUID().uuidString).multipart")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let registry = root.appendingPathComponent("Scratch")
        let malformed = try file(registry, UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: ["schema": "voxclip-export-scratch/1", "directory": external.absoluteString,
            "workName": "voxclip-export-\(UUID().uuidString).partial", "partialNames": ["../Outside/" + target.lastPathComponent]]).write(to: malformed)
        _ = ScratchCleanup.sweep(registry: registry, cache: cache, temporary: root, before: Date().addingTimeInterval(10))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect((try FileManager.default.attributesOfItem(atPath: link.path)[.type]) as? FileAttributeType == .typeSymbolicLink)
        #expect(!FileManager.default.fileExists(atPath: malformed.path))
    }
}
