import AVFoundation
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// MVP46 (2026-11-08): the first two real fal.ai sync-3 jobs were billed and thrown away. fal.ai's own example comes back
/// 5 frames short at the end (135 → 130 frames at 24 fps) with a separate 24 kHz AAC track, and the importer refused it.
@Suite("Lip-sync result length", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
struct LipsyncResultLengthTests {
    private let projectID = LipsyncImportFixture.projectID

    /// The phrase path (sync-3, cut_off) and the whole-clip path (lipsync-2, remap) both import the example's shape.
    @Test(arguments: [(3, SyncMode.cutOff), (1, SyncMode.remap)])
    func anExampleShapedResultImports(model index: Int, mode: SyncMode) async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = root.appendingPathComponent("fal-shaped.mp4")
        try await FalShapedResult.write(to: result, frames: 130, fps: 24, audioSeconds: 5.248)
        let http = LipsyncImportHTTP(bytes: try Data(contentsOf: result), app: "fal-ai/sync-lipsync")
        let provider = try LipsyncImportFixture.provider(http: http)
        let (quote, job) = try await LipsyncImportFixture.submit(root: root, provider: provider, model: provider.models[index],
                                                                 seconds: 135.0 / 24, fps: 24, syncMode: mode)
        let imported = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                                     paidRoot: root, sourceWidth: 320, sourceHeight: 180)
        #expect(abs(imported.asset.durationSeconds - 135.0 / 24) <= 1.0 / 24)
    }
}
