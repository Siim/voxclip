import Darwin
import Foundation
import Testing
import VoxClipCore
@testable import VoxClipMedia

/// The launch sweep of VoiceLabScratch: operation folders whose owner process is gone go, with their intents; what a
/// running process owns and every other scratch folder stays.
@Suite(.offlineFixtures) struct VoiceLabScratchSweepTests {
    private func operation(in scratch: URL, owner: VoiceLabAssetRecovery.Owner?) throws -> VoiceLabAssetRecovery.Operation {
        let parent = Darwin.open(scratch.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(parent >= 0)
        defer { Darwin.close(parent) }
        let operation = try VoiceLabAssetRecovery.Operation(parent: parent, owner: owner)
        // A take's scratch: its mix and fitted audio, and a copy of its paid asset.
        for name in ["mixed.wav", "fitted.wav", "0f6a1c2e-1111-4a00-8000-000000000001.wav"] {
            try Data([0, 1, 2, 3]).write(to: scratch.appendingPathComponent(operation.name).appendingPathComponent(name))
        }
        return operation
    }
    /// The pid of a process that has exited and been reaped.
    private func exitedPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test(arguments: ["pid", "start time"]) func deadOwnersScratchGoesAndTheRestStays(_ dead: String) throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("voxclip-scratch-sweep-\(UUID().uuidString)")
        let scratch = data.appendingPathComponent("VoiceLabScratch"), paid = data.appendingPathComponent("VoiceLab")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        guard case .running(let me) = VoiceLabAssetRecovery.ownerStatus(getpid()) else { Issue.record("no owner for this process"); return }
        let gone = dead == "pid" ? VoiceLabAssetRecovery.Owner(pid: try exitedPID(), seconds: me.seconds, microseconds: me.microseconds)
            : VoiceLabAssetRecovery.Owner(pid: me.pid, seconds: me.seconds - 3_600, microseconds: me.microseconds)
        let live = try operation(in: scratch, owner: nil)
        let left = try operation(in: scratch, owner: gone)
        // Other owners' scratch at the top level, which only they clean.
        let others = ["calibration-timing", "timing", "heard", "lipsync-window-\(UUID().uuidString.lowercased())"]
        for name in others {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data([1]).write(to: scratch.appendingPathComponent(name).appendingPathComponent("keep.wav"))
        }
        // An operation folder with no intent, which nothing can prove is abandoned.
        let orphan = "op-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent(orphan), withIntermediateDirectories: true)
        // The paid root beside it is never read.
        let asset = try VoiceLabAssetStore.write(pcm16: Data([0, 1]), sampleRate: 24_000, projectId: UUID().uuidString.lowercased(),
            assetId: "paid", paidRoot: paid, createdAt: Date())

        let removed = try withExtendedLifetime((live, left)) { try VoiceLabAssetStore.sweepVoiceLabScratch(root: scratch) }
        #expect(removed == 1)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: scratch.path))
        #expect(!names.contains(left.name) && !names.contains(VoiceLabAssetRecovery.intentName(left.name)))
        #expect(names.contains(live.name) && names.contains(VoiceLabAssetRecovery.intentName(live.name)))
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(live.name).appendingPathComponent("mixed.wav").path))
        for name in others { #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(name).appendingPathComponent("keep.wav").path)) }
        #expect(names.contains(orphan))
        #expect(FileManager.default.fileExists(atPath: paid.appendingPathComponent(asset.file).path))
        // A second launch finds nothing more to do; a missing scratch root is nothing to do.
        #expect(try withExtendedLifetime(live) { try VoiceLabAssetStore.sweepVoiceLabScratch(root: scratch) } == 0)
        #expect(try VoiceLabAssetStore.sweepVoiceLabScratch(root: data.appendingPathComponent("missing")) == 0)
    }
}
