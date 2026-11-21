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
}
