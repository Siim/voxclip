import Foundation
import Testing
import VoxClipCore
import VoxClipMedia

@Suite struct RecordingFolderTests {
    private struct Probe: MediaProbe {
        func probe(_ source: URL) async throws -> MediaProbeResult {
            .init(durationSeconds: 2, video: .init(width: 16, height: 16, frameRate: 30, rotationDegrees: 0), isPlayable: true)
        }
    }

    @Test func hashesTheWholeFileAndDoesNotReimportRenamedRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let card = root.appendingPathComponent("card/DCIM")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        var bytes = Data(repeating: 0, count: 3_200_001)
        try bytes.write(to: card.appendingPathComponent("A.mov"))
        try bytes.write(to: card.appendingPathComponent("A-copy.mov"))
        bytes[1_600_000] = 1
        try bytes.write(to: card.appendingPathComponent("B.mov"))
        let first = try await RecordingFolder.scan(root.appendingPathComponent("card"), library: library, probe: Probe())
        #expect(first.count == 2)
        let original = try #require(first.first)
        let local = try RecordingFolder.copy(original, to: library)
        #expect(try Data(contentsOf: local) == Data(contentsOf: original.url))
        try Data().write(to: local.deletingPathExtension().appendingPathExtension("voxclip"))
        let next = try await RecordingFolder.scan(root.appendingPathComponent("card"), library: library, probe: Probe())
        #expect(next.filter(\.imported).map(\.id) == [original.id])
    }
}
