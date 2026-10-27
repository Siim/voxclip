import Testing
@testable import VoxClipCore

/// The app-wide speech job queue on private gates; transcription §13.4. Each step waits for a
/// queue state, never for a clock.
@Suite("Speech job queue", .timeLimit(.minutes(1)))
struct SpeechJobGateTests {
    @Test func releasedSlotGoesToTheOldestWaiterBeforeALaterCaller() async throws {
        let gate = SpeechJobGate()
        try await gate.acquire(local: true, key: "running")
        let first = Task { try await gate.acquire(local: true, key: "first") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["first"] }
        let second = Task { try await gate.acquire(local: true, key: "second") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["first", "second"] }
        await gate.release(local: true, key: "running")
        try await SpeechTestWait.value(first)
        // Asking right after a release does not overtake the jobs that were already waiting.
        let later = Task { try await gate.acquire(local: true, key: "later") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["second", "later"] }
        await gate.release(local: true, key: "first")
        try await SpeechTestWait.value(second)
        await gate.release(local: true, key: "second")
        try await SpeechTestWait.value(later)
        await gate.release(local: true, key: "later")
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
    }

    @Test func waitersNeverHoldBackTheOtherKindOrOtherContent() async throws {
        let gate = SpeechJobGate()
        try await gate.acquire(local: true, key: "local")
        let localWaiter = Task { try await gate.acquire(local: true, key: "local-next") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["local-next"] }
        // Cloud room is used at once although a local job queued first.
        try await gate.acquire(local: false, key: "content")
        let sameContent = Task { try await gate.acquire(local: false, key: "content") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["local-next", "content"] }
        // The last cloud slot goes to other content although the same content queued first.
        try await gate.acquire(local: false, key: "other")
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 1, cloud: 2, waiting: ["local-next", "content"]))
        await gate.release(local: false, key: "content")
        try await SpeechTestWait.value(sameContent)
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 1, cloud: 2, waiting: ["local-next"]))
        await gate.release(local: true, key: "local")
        try await SpeechTestWait.value(localWaiter)
        for (local, key) in [(true, "local-next"), (false, "content"), (false, "other")] { await gate.release(local: local, key: key) }
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
    }

    @Test func releaseSkipsAWaiterWhoseIdenticalJobRunsButKeepsTheOrderOfTheRest() async throws {
        let gate = SpeechJobGate()
        try await gate.acquire(local: false, key: "a")
        try await gate.acquire(local: false, key: "b")
        let duplicate = Task { try await gate.acquire(local: false, key: "a") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["a"] }
        let first = Task { try await gate.acquire(local: false, key: "c") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["a", "c"] }
        let second = Task { try await gate.acquire(local: false, key: "d") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["a", "c", "d"] }
        // "b" ends while "a" still runs: its place passes over the duplicate to the oldest job that can start.
        await gate.release(local: false, key: "b")
        try await SpeechTestWait.value(first)
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 2, waiting: ["a", "d"]))
        let later = Task { try await gate.acquire(local: false, key: "e") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["a", "d", "e"] }
        // Once "a" ends, its duplicate is the oldest job that can start, and a later caller never goes first.
        await gate.release(local: false, key: "a")
        try await SpeechTestWait.value(duplicate)
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 2, waiting: ["d", "e"]))
        await gate.release(local: false, key: "c")
        try await SpeechTestWait.value(second)
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 2, waiting: ["e"]))
        await gate.release(local: false, key: "a")
        try await SpeechTestWait.value(later)
        for key in ["d", "e"] { await gate.release(local: false, key: key) }
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
    }

    @Test func cancelledCallersLeaveTheQueueHoldingNothing() async throws {
        let gate = SpeechJobGate()
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquire(local: false, key: "early")
        }
        await #expect(throws: CancellationError.self) { try await SpeechTestWait.value(early) }
        try await gate.acquire(local: false, key: "a")
        try await gate.acquire(local: false, key: "b")
        let cancelled = Task { try await gate.acquire(local: false, key: "cancelled") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["cancelled"] }
        let next = Task { try await gate.acquire(local: false, key: "next") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["cancelled", "next"] }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await SpeechTestWait.value(cancelled) }
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 2, waiting: ["next"]))
        await gate.release(local: false, key: "a")
        try await SpeechTestWait.value(next)
        await gate.release(local: false, key: "b")
        await gate.release(local: false, key: "next")
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
    }

    @Test func slotHandedOverBeforeACancellationStaysWithItsJob() async throws {
        let gate = SpeechJobGate()
        try await gate.acquire(local: true, key: "running")
        let waiter = Task { try await gate.acquire(local: true, key: "waiter") }
        try await SpeechTestWait.until { await gate.snapshot().waiting == ["waiter"] }
        // The release resumes the waiter before returning, so the cancellation arrives too late to
        // undo the hand-off; the job owns the slot and releases it like any other.
        await gate.release(local: true, key: "running")
        waiter.cancel()
        try await SpeechTestWait.value(waiter)
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 1, cloud: 0, waiting: []))
        await gate.release(local: true, key: "waiter")
        #expect(await gate.snapshot() == SpeechJobGate.Snapshot(local: 0, cloud: 0, waiting: []))
    }
}
