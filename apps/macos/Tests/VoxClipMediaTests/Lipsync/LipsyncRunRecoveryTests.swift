import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// A finished fal.ai result is never paid for twice (2026-11-21 reliability pass): a later run over the same window gets
/// the imported file again, a cancel after fal.ai finished keeps the result, and a poll that gave up is recovered for free
/// once fal.ai finishes, while a priced click never submits a second job for it.
@Suite("Lip-sync run recovery", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
struct LipsyncRunRecoveryTests {
    private struct Fixture {
        let root: URL
        let request: RenderRequest
        let window: LipsyncRenderWindow
        let recordID: String
        let http: LipsyncImportHTTP
        /// A new run, as after a relaunch: its own provider over the same stood-in fal.ai and the same paid folder.
        func run() throws -> LipsyncRun {
            var run = LipsyncRun(provider: try LipsyncImportFixture.provider(http: http), consentStore: consentStore,
                                 paidRoot: root, scratchRoot: root.appendingPathComponent("scratch"))
            run.detector = { _ in 0.2 }
            return run
        }
        let consentStore: VoiceConsentStore
        func execute(_ run: LipsyncRun, mayPay: Bool = true) async throws -> ImportedLipsyncResult {
            try await run.execute(request: request, window: window, recordID: recordID, model: run.provider.models[3], mayPay: mayPay)
        }
    }

    /// The window of `ContextDemoZoomCoverCompositionTests`' lip-sync runs, over fal.ai stood in by `LipsyncImportHTTP`
    /// answering with a sync-3-shaped result (5 frames short of the upload).
    @MainActor private func fixture(barrier: LipsyncImportBarrier? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lipsync-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        let source = try await NativeMediaFixtures.shared.file("joins-tone.mov")
        let project = try zoomCoverProject(duration: 0.875, source: source, paidRoot: root)
        let request = try zoomCoverRequest(project: project, paidRoot: root)
        let plan = try #require(request.voiceLab).prepared.outputPlan
        let recipe = try #require(project.voiceLab.segments[0].candidates[0].recipe)
        let window = try LipsyncRenderWindow(source: LipsyncWindow.make(seamIn: recipe.video.sourceStartSample,
            seamOut: recipe.video.sourceEndSample, totalSamples: plan.totalSourceSamples, sampleRate: 48_000, phraseID: 0), plan: plan)
        let needed = window.seconds(sampleRate: 48_000)
        let uploadFrames = Int((LipsyncLimits.uploadSeconds(needed) * 30 - 1e-6).rounded(.up))
        let http = LipsyncImportHTTP(app: "fal-ai/sync-lipsync", barrier: barrier, maker: { video, _ in
            try await FalShapedResult.truncate(video, frames: uploadFrames - 5, audioSeconds: needed - 0.2)
        })
        let (store, recordID) = try await LipsyncImportFixture.consent(root: root)
        return Fixture(root: root, request: request, window: window, recordID: recordID, http: http, consentStore: store)
    }

    /// Imported, then the same window again in a new run (a relaunch before Use): the same asset, for free, with no second
    /// upload, submit or fetch. Before: the attempt's record was deleted on import, and the second run paid again.
    @Test @MainActor func anImportedResultIsReusedByALaterRun() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await fixture.execute(try fixture.run())
        #expect(!first.recovered)
        let fetches = await fixture.http.resultFetches
        let again = try await fixture.execute(try fixture.run())
        #expect(again.asset == first.asset && again.url == first.url && again.recovered)
        #expect(again.provenance.requestID == first.provenance.requestID)
        #expect(await fixture.http.submits == 1)
        #expect(await fixture.http.uploads.count == 2)
        #expect(await fixture.http.resultFetches == fetches)
    }

    /// fal.ai finished and the result is downloading when the run is cancelled: it runs to the end and is kept, fal.ai's job
    /// is never cancelled, and the next free Try Again puts it in without paying. Before: the cancel deleted fal.ai's copy
    /// and the downloaded file, and the run threw a plain cancel.
    @Test @MainActor func aCancelAfterFalFinishedKeepsTheResultForAFreeTryAgain() async throws {
        let barrier = LipsyncImportBarrier()
        let fixture = try await fixture(barrier: barrier)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = try fixture.run()
        let task = Task { try await fixture.execute(run) }
        await barrier.waitUntilEntered()
        task.cancel()
        #expect(await fixture.http.deletions == 0)
        await barrier.release()
        let kept = try await task.value
        #expect(await fixture.http.cancels == 0, "a finished job is never cancelled")
        #expect(await fixture.http.deletions == 1, "fal.ai's copy goes once the result is safe here")
        let again = try await fixture.execute(try fixture.run(), mayPay: false)
        #expect(again.asset == kept.asset && again.recovered)
        #expect(await fixture.http.submits == 1)
    }

    /// The wait gives up on a job fal.ai is still running (its polls kept failing): the attempt is kept for a free check.
    /// Try Again · free asks the status, waits out IN_PROGRESS and imports the result: no second submit. A free check that
    /// was cancelled leaves its once-per-run claim open. Before: the free try did one result GET of a running job, failed,
    /// spent the claim, and the next click paid for a second job.
    @Test @MainActor func aPollThatGaveUpIsRecoveredForFreeOnceFalFinishes() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.http.answerStatus(Array(repeating: (502, #"{"detail":"bad gateway"}"#), count: FalLipsyncProvider.pollRetries + 1))
        var thrown: LipsyncAttemptFailure?
        do { _ = try await fixture.execute(try fixture.run()) } catch let failure as LipsyncAttemptFailure { thrown = failure }
        let failure = try #require(thrown)
        #expect(failure.freeRetry && failure.error as? LipsyncError == .http(502))
        #expect(await fixture.http.cancels == 0)
        #expect(await fixture.http.deletions == 0)
        // A free check cancelled while it asks fal.ai.
        let hold = LipsyncImportBarrier()
        await fixture.http.holdNextStatus(hold)
        let cancelled = Task { try await fixture.execute(try fixture.run(), mayPay: false) }
        await hold.waitUntilEntered()
        cancelled.cancel()
        await hold.release()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        // fal.ai is still running it, then finishes.
        await fixture.http.answerStatus([(200, #"{"status":"IN_PROGRESS"}"#), (200, #"{"status":"IN_QUEUE","queue_position":0}"#)])
        let recovered = try await fixture.execute(try fixture.run(), mayPay: false)
        #expect(recovered.recovered && recovered.provenance.requestID == failure.attempt.requestID)
        #expect(await fixture.http.submits == 1)
        #expect(await fixture.http.uploads.count == 2)
    }

    /// A cancel that lands just as fal.ai says the job is done (the wait's own check, before the import starts): the job is
    /// billed and never cancelled, and Try Again is free only when it can find the attempt again, by its record on disk.
    /// With the record unwritable (a file where the attempts folder belongs), the stop says so: no free Try Again that
    /// could only fail. Before: always `freeRetry`, and the free click found nothing.
    @Test(arguments: [true, false]) @MainActor func aCancelAsFalFinishesIsFreeToRetryOnlyWhenItsRecordIsThere(writable: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projectID = try #require(fixture.request.voiceLab?.project.id)
        if !writable {
            let project = fixture.root.appendingPathComponent(projectID, isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("not a folder".utf8).write(to: project.appendingPathComponent(LipsyncAttemptStore.folder))
        }
        let run = try fixture.run()
        let (request, window, recordID) = (fixture.request, fixture.window, fixture.recordID)
        // Cancelled from its own progress callback when fal.ai reports done: the wait's next check throws.
        let task = Task {
            try await run.execute(request: request, window: window, recordID: recordID, model: run.provider.models[3]) { progress in
                if progress == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        var thrown: LipsyncAttemptFailure?
        do {
            _ = try await task.value
            Issue.record("the cancel didn't stop the run")
        } catch let failure as LipsyncAttemptFailure { thrown = failure }
        let failure = try #require(thrown)
        #expect(failure.error is CancellationError)
        #expect(failure.freeRetry == writable)
        #expect(await fixture.http.cancels == 0, "a finished job is never cancelled")
        #expect(await fixture.http.deletions == 0, "fal.ai's copy stays until the result is safe here")
        guard writable else { return }
        let recovered = try await fixture.execute(try fixture.run(), mayPay: false)
        #expect(recovered.recovered && recovered.provenance.requestID == failure.attempt.requestID)
        #expect(await fixture.http.submits == 1)
    }

    /// A priced click over a window whose earlier paid job fal.ai is still running waits for that job, never a new one.
    @Test @MainActor func aPricedClickNeverSubmitsWhileTheEarlierJobStillRuns() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.http.answerStatus(Array(repeating: (503, #"{"detail":"unavailable"}"#), count: FalLipsyncProvider.pollRetries + 1))
        await #expect(throws: LipsyncAttemptFailure.self) { _ = try await fixture.execute(try fixture.run()) }
        await fixture.http.answerStatus(Array(repeating: (200, #"{"status":"IN_PROGRESS"}"#), count: 3))
        let result = try await fixture.execute(try fixture.run(), mayPay: true)
        #expect(result.recovered)
        #expect(await fixture.http.submits == 1)
        #expect(await fixture.http.uploads.count == 2)
    }
}
