import Foundation
import Testing
@testable import VoxClipCore

@Suite("Owned stale scratch") struct ScratchCleanupTests {
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

    @Test func removesOnlyOldOwnedFilesAndKeepsCompletedAssets() throws {
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
        #expect(removed.count == 3)
        #expect(removedNames == [staleUpload.lastPathComponent, cli.lastPathComponent, legacyWork.lastPathComponent])
        for stale in [staleUpload, cli, legacyWork] { #expect(!FileManager.default.fileExists(atPath: stale.path)) }
        for kept in [transcript, audio, lookalike, unowned, freshCLI, freshInput, ambiguousPartial, completed] {
            #expect(FileManager.default.fileExists(atPath: kept.path), "Must retain \(kept.lastPathComponent)")
        }
        #expect(ScratchCleanup.processStart > .distantPast && ScratchCleanup.processStart <= Date())
    }

    @Test func exportJournalOwnsExactPartialsAndRetainsNewWork() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("Exports"), registry = root.appendingPathComponent("Scratch")
        let work = exports.appendingPathComponent("voxclip-export-\(UUID().uuidString).partial")
        _ = try file(work, "writer.tmp")
        let partial = try file(exports, "take.mp4.partial"), sidecar = try file(exports, "take.srt.partial")
        let complete = try file(exports, "take.mp4")
        let record = try ScratchCleanup.registerExport(workDirectory: work, partials: [partial, sidecar], registry: registry)
        let cutoff = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(1)], ofItemAtPath: partial.path)
        _ = ScratchCleanup.sweep(registry: registry, cache: root.appendingPathComponent("Cache"), temporary: root, before: cutoff)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path) && !FileManager.default.fileExists(atPath: work.path))
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(-1)], ofItemAtPath: partial.path)
        _ = ScratchCleanup.sweep(registry: registry, cache: root.appendingPathComponent("Cache"), temporary: root, before: cutoff)
        #expect(!FileManager.default.fileExists(atPath: partial.path) && !FileManager.default.fileExists(atPath: record.path))
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
        #expect(FileManager.default.fileExists(atPath: malformed.path))
    }
}
