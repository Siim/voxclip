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
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(projectID).path).sorted()
            == ["\(result.asset.id).mp4", "lipsync-attempts"])
        // The attempt's record stays as the window's imported index: the same inputs find this asset again, for free.
        let index = try #require(LipsyncAttemptStore.load(videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256,
                                                          projectID: projectID, paidRoot: root))
        #expect(index.importedAsset == result.asset && !index.keptResult && index.requestID == job.remoteID)
        let again = try #require(LipsyncAttemptStore.importedResult(index, projectID: projectID, paidRoot: root))
        #expect(again.asset == result.asset && again.url == result.url && again.recovered)
        #expect(again.provenance.outputSHA256 == result.provenance.outputSHA256 && again.provenance.requestID == job.remoteID)
        #expect(await http.deletions == 1)
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .completed)
    }

    /// The index checks the file: a changed or missing asset is never handed back, and pruning drops only the record.
    @Test func theImportedIndexChecksItsFileAndPrunesWhenItIsGone() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncImportHTTP(bytes: try FixtureLoader.data("fixtures/media/counter-1080p.mp4"))
        let (provider, quote, job) = try await prepare(root: root, http: http)
        let result = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                                   paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        func index() -> LipsyncAttempt? {
            LipsyncAttemptStore.load(videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256, projectID: projectID, paidRoot: root)
        }
        let entry = try #require(index())
        let bytes = try Data(contentsOf: result.url)
        try (bytes.prefix(bytes.count - 1) + Data([bytes.last! ^ 0xff])).write(to: result.url)
        #expect(LipsyncAttemptStore.importedResult(entry, projectID: projectID, paidRoot: root) == nil, "a changed file never comes back")
        LipsyncAttemptStore.prune(projectID: projectID, paidRoot: root, now: Date())
        #expect(index() != nil, "a present asset keeps its entry")
        LipsyncAttemptStore.prune(projectID: projectID, paidRoot: root, now: Date().addingTimeInterval(31 * 86_400))
        #expect(index() == nil, "30 days after its import the entry goes")
        #expect(FileManager.default.fileExists(atPath: result.url.path), "the asset itself stays")
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

    /// fal.ai finished (and billed) and the result is downloading when the run is cancelled, its task and its job alike:
    /// the download and store run to the end, the result is kept in the index, and fal.ai's copy goes only once it is safe
    /// here. Before: the cancel deleted fal.ai's copy (DELETE payloads) and the downloaded file, and Try Again paid again.
    @Test func aCancelAfterFalFinishedKeepsTheResult() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let barrier = LipsyncImportBarrier()
        let http = LipsyncImportHTTP(bytes: try FixtureLoader.data("fixtures/media/counter-1080p.mp4"), barrier: barrier)
        let (provider, quote, job) = try await prepare(root: root, http: http)
        let task = Task {
            try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                          paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        }
        await barrier.waitUntilEntered()
        task.cancel()
        await provider.cancel(job)
        #expect(await http.deletions == 0, "nothing is deleted while the result isn't safe here")
        #expect(await http.cancels == 0)
        await barrier.release()
        let result = try await task.value
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(LipsyncAttemptStore.load(videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256, projectID: projectID,
                                         paidRoot: root)?.importedAsset == result.asset)
        #expect(await http.deletions == 1)
        #expect(await http.cancels == 0)
        #expect(await provider.status(quoteID: quote.id)?.billing.mayBill == true)
    }

    /// A local failure after fal.ai finished and before the download (the project's paid folder can't be written: a full
    /// disk, a permissions fault) leaves fal.ai's copy for a free re-fetch. Before: LipsyncRun's catch deleted it, and Try
    /// Again was priced.
    @Test func anUnwritableProjectAfterFalFinishedKeepsFalsCopyForAFreeRetry() async throws {
        let root = try directory()
        let project = root.appendingPathComponent(projectID)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
            try? FileManager.default.removeItem(at: root)
        }
        let http = LipsyncImportHTTP(bytes: try FixtureLoader.data("fixtures/media/counter-1080p.mp4"))
        let (provider, quote, job) = try await prepare(root: root, http: http)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: project.path)
        var thrown: LipsyncAttemptFailure?
        do {
            _ = try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, projectID: projectID,
                                                               paidRoot: root, sourceWidth: 1_920, sourceHeight: 1_080)
        } catch let failure as LipsyncAttemptFailure { thrown = failure }
        let failure = try #require(thrown)
        #expect(failure.freeRetry && failure.error as? LipsyncError == .unsafeFile)
        #expect(await http.deletions == 0)
        #expect(await http.downloads == 0)
        #expect(await provider.isDone(job))
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .pending)
    }
}
