import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite struct VoiceLabAssetRetentionTests {
    @Test func persistedOrphansStartAtDiscoveryAndReferencesNeverExpire() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let orphan = try VoiceLabAssetStore.write(pcm16: Data([0, 1, 0, 1]), sampleRate: 24000, projectId: project,
            assetId: "orphan", paidRoot: root, createdAt: date.addingTimeInterval(-30 * 86400))
        let historical = try VoiceLabAssetStore.write(pcm16: Data([0, 1, 0, 1]), sampleRate: 24000, projectId: project,
            assetId: "historical", paidRoot: root, createdAt: date)
        let video = "\(project)/orphan-video.mp4"
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent(video))
        #expect(try VoiceLabAssetStore.recoverStalePartials(paidRoot: root) == 0)
        try VoiceLabAssetRetention.discoverUnlisted(paidRoot: root, now: date)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.file).path))
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [historical.file], now: date).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(7 * 86400 - 1)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(7 * 86400)) == [orphan.file, video].sorted())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(historical.file).path))
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(100 * 86400)).isEmpty)
    }
    @Test func newReferenceBackwardClockAndAnotherWindowPreventDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "candidate", paidRoot: root, createdAt: date)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(-1)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(8 * 86400), allowDeletion: false).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [asset.file], now: date.addingTimeInterval(9 * 86400)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
    }
    @Test func corruptLedgerAndSymlinkNeverAuthorizeDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project, assetId: "keep", paidRoot: root, createdAt: date)
        let directory = root.appendingPathComponent(project), target = root.appendingPathComponent("outside.wav")
        try Data([1, 2, 3]).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.wav"), withDestinationURL: target)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [asset.file], now: date)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(".asset-retention.json"))
        #expect(throws: (any Error).self) {
            try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(100 * 86400))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
        #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
    }
}
