#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

/// The account's one lip-sync slot (voice-lab §9.6) is shared by every run in the app. A run that stops tracking its job
/// gives it back, whatever stopped it, so one failure never makes every later lip sync wait out 5 minutes and fail
/// "Stopped before submitting" (shared-lipsync-lease-leak). A held slot refuses at once, before any upload.
@Suite("Lip-sync account slot", .timeLimit(.minutes(1)), .offlineFixtures)
struct LipsyncProviderQueueTests {
    private typealias Fixtures = LipsyncProviderFixtures

    /// Provider B over the same slot: submits at once.
    private func submitB(_ queue: LipsyncProviderQueue, clock: LipsyncFixtureClock, root: URL) async throws -> LipsyncJob {
        let own = root.appendingPathComponent("b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: false)
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt())])
        let provider = try Fixtures.provider(http, clock: clock, queue: queue)
        let quote = try await Fixtures.quote(provider), approval = try await Fixtures.approval(provider, quote: quote, root: own)
        return try await provider.submit(quote, approval: approval)
    }

    /// A's polls keep failing until its wait gives up; the job is left to a free check later, and its slot goes back.
    @Test func aWaitThatGivesUpGivesTheSlotBack() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LipsyncFixtureClock(), queue = Fixtures.queue(clock)
        let replies: [LipsyncFixtureHTTP.Reply] = [.json(200, Fixtures.receipt())]
            + Array(repeating: .network, count: FalLipsyncProvider.pollRetries + 1)
        let a = try Fixtures.provider(LipsyncFixtureHTTP(replies), clock: clock, queue: queue)
        let quote = try await Fixtures.quote(a), approval = try await Fixtures.approval(a, quote: quote, root: root)
        let job = try await a.submit(quote, approval: approval)
        #expect(await queue.isHeld(account: "fal"))
        await #expect(throws: LipsyncError.network) { _ = try await a.wait(job) }
        #expect(await a.status(quoteID: quote.id)?.cancelled == false, "the job is not cancelled: a free check can still fetch it")
        #expect(!(await queue.isHeld(account: "fal")))
        #expect(try await submitB(queue, clock: clock, root: root).remoteID == Fixtures.requestID)
    }

    /// A lost submit answer (charge unknown) gives the slot back too: the session's own flag blocks a resubmit.
    @Test func anUncertainSubmitGivesTheSlotBack() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LipsyncFixtureClock(), queue = Fixtures.queue(clock)
        let a = try Fixtures.provider(LipsyncFixtureHTTP([.network]), clock: clock, queue: queue)
        let quote = try await Fixtures.quote(a), approval = try await Fixtures.approval(a, quote: quote, root: root)
        await #expect(throws: LipsyncError.submissionUncertain) { _ = try await a.submit(quote, approval: approval) }
        await #expect(throws: LipsyncError.busy, "this provider still never resubmits") { _ = try await a.submit(quote, approval: approval) }
        #expect(!(await queue.isHeld(account: "fal")))
        _ = try await submitB(queue, clock: clock, root: root)
    }

    /// A cancel fal.ai only queued (202) and a payload delete called from the cancelled task: the delete is still sent (its
    /// own task) and the slot goes back. Before: the delete threw in the cancelled task and the slot stayed held.
    @Test func aCancelledRunsDeleteIsSentAndItsSlotGoesBack() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LipsyncFixtureClock(), queue = Fixtures.queue(clock), barrier = LipsyncFixtureBarrier()
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .held(Fixtures.inProgress, barrier),
                                      .json(202, #"{"status":"CANCELLATION_REQUESTED"}"#), .json(200, Fixtures.cleanup)])
        let a = try Fixtures.provider(http, clock: clock, queue: queue)
        let quote = try await Fixtures.quote(a), approval = try await Fixtures.approval(a, quote: quote, root: root)
        let job = try await a.submit(quote, approval: approval)
        let waiting = Task { try await a.wait(job) }
        try await barrier.waitUntilEntered()
        waiting.cancel()
        await barrier.release()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        await TestDeadline.until { await http.requests.contains { $0.httpMethod == "PUT" } }
        // LipsyncRun's cancel branch: cancel, then clean up, inside the cancelled task.
        let cleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await a.cancel(job); await a.cleanup(job)
        }
        await cleanup.value
        #expect(await http.requests.contains { $0.httpMethod == "DELETE" })
        #expect(await a.status(quoteID: quote.id)?.cleanup == .completed)
        #expect(!(await queue.isHeld(account: "fal")))
        _ = try await submitB(queue, clock: clock, root: root)
    }

    /// A slot no one gave back (a dropped run) ends at its job's deadline.
    @Test func aLostSlotEndsAtTheJobsDeadline() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = LipsyncFixtureClock(), queue = Fixtures.queue(clock)
        let a = try Fixtures.provider(LipsyncFixtureHTTP([.json(200, Fixtures.receipt())]), clock: clock, queue: queue)
        let quote = try await Fixtures.quote(a), approval = try await Fixtures.approval(a, quote: quote, root: root)
        _ = try await a.submit(quote, approval: approval)
        await #expect(throws: LipsyncError.busy) { _ = try await submitB(queue, clock: clock, root: root) }
        clock.advance(LipsyncLimits.deadlineSeconds + 301)
        #expect(!(await queue.isHeld(account: "fal")))
        _ = try await submitB(queue, clock: clock, root: root)
    }
}
#endif
