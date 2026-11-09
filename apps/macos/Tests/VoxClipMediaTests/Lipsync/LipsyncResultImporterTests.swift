import AVFoundation
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

@Suite("Lip-sync result import transaction", .timeLimit(.minutes(1)), .offlineFixtures)
struct LipsyncResultImporterTests {
    private let projectID = LipsyncImportFixture.projectID
    private func directory() throws -> URL { try LipsyncImportFixture.directory() }

    private func prepare(root: URL, http: LipsyncImportHTTP) async throws -> (FalLipsyncProvider, LipsyncQuote, LipsyncJob) {
        let provider = try LipsyncImportFixture.provider(http: http)
        let (quote, job) = try await LipsyncImportFixture.submit(root: root, provider: provider, model: provider.models[0], seconds: 4, fps: 30)
        return (provider, quote, job)
    }

    @Test func existingSyntheticVideoIsValidatedHashedAndImportedWithoutProjectMutation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try FixtureLoader.data("fixtures/media/counter-1080p.mp4")
        let http = LipsyncImportHTTP(bytes: bytes), (provider, quote, job) = try await prepare(root: root, http: http)
        let result = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                                   paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        // The fixture carries an audio track: the stored picture is re-encoded without it (fal.ai's audio is never used).
        let stored = try Data(contentsOf: result.url)
        #expect(stored != bytes)
        #expect(try await AVURLAsset(url: result.url).load(.tracks).allSatisfy { $0.mediaType == .video })
        #expect(abs(result.asset.durationSeconds - 4) <= 1.0 / 30)
        #expect(result.asset.sha256 == SpeechSHA256.hex(stored)); #expect(result.provenance.outputSHA256 == result.asset.sha256)
        #expect(result.provenance.requestID == job.remoteID); #expect(result.provenance.quoteID == quote.id)
        #expect(result.asset.file == "\(projectID)/\(result.asset.id).mp4")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectID).path) == ["\(result.asset.id).mp4"])
        #expect(await http.deletions == 1)
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .completed)
    }

    /// A paid result that isn't an MP4 fails its named container check; nothing is published and no scratch stays, and
    /// the paid file is kept beside its attempt (never lost) before fal.ai's copy is deleted.
    @Test func invalidDownloadedMediaRemovesScratchAndUnpublishedResult() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncImportHTTP(bytes: Data("this is not an MP4".utf8))
        let (provider, quote, job) = try await prepare(root: root, http: http)
        var thrown: LipsyncAttemptFailure?
        do {
            _ = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                               paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        } catch let failure as LipsyncAttemptFailure { thrown = failure }
        #expect((thrown?.error as? LipsyncResultCheck)?.logLine == "lipsync result check=container bytes=18")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectID).path) == ["lipsync-attempts"])
        #expect(await http.deletions == 1)
    }

    @Test func cancelDuringDownloadSuppressesLateFileAndImportedRecipe() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let barrier = LipsyncImportBarrier()
        let http = LipsyncImportHTTP(bytes: try FixtureLoader.data("fixtures/media/counter-1080p.mp4"), barrier: barrier)
        let (provider, quote, job) = try await prepare(root: root, http: http)
        let task = Task {
            try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                          paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        }
        await barrier.waitUntilEntered()
        await provider.cancel(job)
        await barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectID).path).isEmpty)
        #expect(await provider.status(quoteID: quote.id)?.billing.mayBill == true)
    }
}
