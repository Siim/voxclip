import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

@Suite struct VoiceLabAssetRetentionTests {
    @Test(arguments: ["replacement", "live-instance", "late-reference"])
    func deletionRequiresOwnedIdentityAndNoActiveDocuments(scenario: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project,
            assetId: "candidate", paidRoot: root, createdAt: now)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: now,
            observation: .init(session: "test", monotonicSeconds: 0))
        let activity = scenario == "live-instance" ? try VoiceLabAssetActivity(paidRoot: root) : nil
        var rechecked = false
        let result = try withExtendedLifetime(activity) {
            try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [],
                now: now.addingTimeInterval(7 * 86400), observation: .init(session: "test", monotonicSeconds: 7 * 86400),
                recheckReferences: {
                    rechecked = true
                    if scenario == "replacement" {
                        try Data("replacement user file".utf8).write(to: root.appendingPathComponent(asset.file), options: .atomic)
                    }
                    return scenario == "late-reference" ? [asset.file] : []
                })
        }
        #expect(result.isEmpty && FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
        #expect(rechecked == (scenario != "live-instance"))
        if scenario == "replacement" { #expect(try Data(contentsOf: root.appendingPathComponent(asset.file)) == Data("replacement user file".utf8)) }
    }
    @Test func observedCandidatesRespectSevenDaysAndReferencesNeverExpire() throws {
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
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.file).path))
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [historical.file], now: date,
            observation: .init(session: "test", monotonicSeconds: 0)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(7 * 86400 - 1),
            observation: .init(session: "test", monotonicSeconds: 7 * 86400 - 1)).isEmpty)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(7 * 86400),
            observation: .init(session: "test", monotonicSeconds: 7 * 86400)) == [orphan.file])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(video).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(historical.file).path))
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(100 * 86400)).isEmpty)
    }
    @Test(arguments: ["forward", "backward", "restart", "reference"])
    func clockDiscontinuitiesRestartGraceAndReferencesAreCheckedAtDeletion(_ change: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project,
            assetId: "candidate", paidRoot: root, createdAt: date)
        try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date,
            observation: .init(session: "first", monotonicSeconds: 0))
        let elapsed: Double = change == "backward" ? -1 : 8 * 86400
        var observations = 0
        let removed = try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [],
            now: date.addingTimeInterval(elapsed), observation: .init(session: change == "restart" ? "next" : "first",
                monotonicSeconds: change == "reference" ? elapsed : 1), recheckReferences: {
                    observations += 1; return [asset.file]
                })
        #expect(removed.isEmpty && FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
        #expect(observations == (change == "reference" ? 1 : 0))
        let ledger = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(project + "/.asset-retention.json"))) as? [String: Any]
        let entries = try #require(ledger?["unreferenced"] as? [String: [String: Any]])
        #expect(entries["candidate.wav"]?["lastObservedAt"] != nil)
        if change != "reference" {
            #expect(entries["candidate.wav"]?["discovered"] as? Double == date.addingTimeInterval(elapsed).timeIntervalSinceReferenceDate)
        }
    }
    @Test func startupCompleteUnlistedPaidAssetsArePermanentlyPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID().uuidString.lowercased(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24000, projectId: project,
            assetId: "complete", paidRoot: root, createdAt: date)
        try VoiceLabAssetRetention.discoverUnlisted(paidRoot: root, now: date)
        #expect(try VoiceLabAssetRetention.closeProject(projectId: project, paidRoot: root, references: [], now: date.addingTimeInterval(100 * 86400)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(asset.file).path))
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
