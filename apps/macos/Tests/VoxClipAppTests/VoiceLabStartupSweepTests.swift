#if DEBUG
import Darwin
import Foundation
import Testing
@testable import VoxClip
@testable import VoxClipCore
@testable import VoxClipMedia

private actor SweepSettingsStore: SettingsStore {
    let values: [String: JSONValue]
    init(exports: URL) { values = ["update.autoCheck": .bool(false), "export.folder": .string(exports.path)] }
    func load() async throws -> SettingsDocument { SettingsDocument(values: values) }
    func save(_ settings: SettingsDocument) async throws {}
    func flush() async throws {}
}

/// Launch sweeps the Voice Lab scratch a quit, crash or relaunch left behind: take mixes and asset copies whose owner
/// process is gone. It used to sweep only Scratch, the cache, tmp and exports, so these stayed forever.
@Suite(.serialized, .timeLimit(.minutes(1)), .offlineFixtures)
@MainActor struct VoiceLabStartupSweepTests {
    @Test func launchRemovesScratchLeftByAProcessThatIsGone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-startup-sweep-\(UUID().uuidString)", isDirectory: true)
        let scratch = root.appendingPathComponent("VoiceLabScratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("calibration-timing"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .running(let me) = VoiceLabAssetRecovery.ownerStatus(getpid()) else { Issue.record("no owner for this process"); return }
        let parent = Darwin.open(scratch.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(parent >= 0)
        defer { Darwin.close(parent) }
        // Another VoxClip's scratch from before its relaunch: the same pid number, an earlier start.
        let left = try VoiceLabAssetRecovery.Operation(parent: parent, owner: .init(pid: me.pid, seconds: me.seconds - 3_600, microseconds: me.microseconds))
        let live = try VoiceLabAssetRecovery.Operation(parent: parent)
        for operation in [left, live] {
            try Data([0, 1]).write(to: scratch.appendingPathComponent(operation.name).appendingPathComponent("mixed.wav"))
        }
        let app = AppModel(settingsStore: SweepSettingsStore(exports: root.appendingPathComponent("Exports")),
                           locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.voiceRecoveryForTests = {}
        await app.start()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: scratch.path))
        #expect(!names.contains(left.name) && !names.contains(VoiceLabAssetRecovery.intentName(left.name)), "\(names)")
        #expect(names.contains(live.name) && names.contains("calibration-timing"), "\(names)")
        withExtendedLifetime((left, live)) {}
    }

    /// Launch sweeps saved Rewrite proposals 60 days unused, beside the scratch: they used to go only when one was read, so
    /// a project never opened again kept its records forever. Records still in their 60 days stay, and so does a
    /// temporary file a write may still be making; one left by a crash an hour ago or more goes.
    @Test func launchSweepsSavedRewritesSixtyDaysUnused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-startup-rewrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paidRoot = root.appendingPathComponent("VoiceLab", isDirectory: true)
        func record(_ project: String, savedAt: Date, under store: URL) throws -> URL {
            let url = try #require(RewriteSavedProposalStore.url(paidRoot: store, projectId: project, scope: "full"))
            let saved = RewriteSavedProposal(projectId: project, scope: "full", inputs: "x", instruction: "", changes: [], kept: [], pricedAnyway: [],
                                             voiceRecordID: nil, patchTakes: 1, patchUSD: 0.04, patchRequests: [], wholeClip: nil, savedAt: savedAt)
            try RewriteSavedProposalStore.write(RewriteSavedProposalStore.encode(saved), to: url)
            return url
        }
        let expired = Date().addingTimeInterval(-61 * 86_400)
        let old = try record("p-old", savedAt: expired, under: paidRoot)
        let fresh = try record("p-fresh", savedAt: Date().addingTimeInterval(-59 * 86_400), under: paidRoot)
        let external = root.appendingPathComponent("Elsewhere")
        let outside = try record("p-outside", savedAt: expired, under: external)
        try FileManager.default.createSymbolicLink(at: paidRoot.appendingPathComponent("p-link"),
                                                  withDestinationURL: external.appendingPathComponent("p-outside"))
        let corrupt = try #require(RewriteSavedProposalStore.url(paidRoot: paidRoot, projectId: "p-fresh", scope: "clip:never-opened"))
        try Data("corrupt".utf8).write(to: corrupt)
        let folder = fresh.deletingLastPathComponent()
        let crashed = folder.appendingPathComponent(".x.json.crashed.partial"), writing = folder.appendingPathComponent(".x.json.writing.partial")
        try Data([1]).write(to: crashed); try Data([1]).write(to: writing)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3_600)], ofItemAtPath: crashed.path)
        let app = AppModel(settingsStore: SweepSettingsStore(exports: root.appendingPathComponent("Exports")),
                           locations: DataLocations(environment: ["VOXCLIP_DATA_DIR": root.path]))
        app.voiceRecoveryForTests = {}
        await app.start()
        #expect(!FileManager.default.fileExists(atPath: old.path), "a record 60 days unused goes at launch")
        #expect(FileManager.default.fileExists(atPath: fresh.path), "one still in its 60 days stays")
        #expect(!FileManager.default.fileExists(atPath: corrupt.path), "a broken record for a never-reopened scope goes")
        #expect(FileManager.default.fileExists(atPath: outside.path), "launch never sweeps a project outside its paid store")
        #expect(!FileManager.default.fileExists(atPath: crashed.path) && FileManager.default.fileExists(atPath: writing.path))
    }
}
#endif
