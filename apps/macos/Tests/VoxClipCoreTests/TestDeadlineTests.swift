import Testing

@Suite("Test wait deadlines", .offlineFixtures)
struct TestDeadlineTests {
    @Test func readyConditionsAndCompletedContinuationsReturnTheirValues() async {
        #expect(await TestDeadline.until { true })
        let value = await withTestDeadline(returning: false) { $0.resume(returning: true) }
        #expect(value)
    }
    @Test func missingConditionFailsAtItsDeadline() async {
        await withKnownIssue("The missing condition must fail instead of hanging") {
            #expect(!((await TestDeadline.until(timeout: .zero) { false })))
        }
    }
    @Test func expiredContinuationCanReceiveALateCompletionSafely() async {
        var held: TestContinuation<Bool>?
        await withKnownIssue("The missing completion must fail instead of hanging") {
            let value = await withTestDeadline(returning: false, timeout: .zero) { held = $0 }
            #expect(!value)
        }
        held?.resume(returning: true)
    }
    @Test func fixtureLaneQueuesIndependentSuitesAndReleasesAfterAnError() async throws {
        let lane = OfflineFixtureLane()
        await lane.enter()
        let entered = FixtureLaneProbe()
        let waiting = Task { try await lane.withPermit { await entered.mark() } }
        try #require(await TestDeadline.until { await lane.waitingCount == 1 })
        #expect(await !entered.value)
        await lane.leave()
        _ = try await TestDeadline.value(waiting, "queued fixture suite")
        #expect(await entered.value)
        do {
            try await lane.withPermit { throw FixtureLaneError.expected }
            Issue.record("The fixture error must propagate")
        } catch FixtureLaneError.expected { }
        try await lane.withPermit { }
    }
    @Test func cancelledQueuedFixtureSuiteReleasesWithoutRunningItsBody() async throws {
        let lane = OfflineFixtureLane()
        await lane.enter()
        let entered = FixtureLaneProbe()
        let waiting = Task { try await lane.withPermit { await entered.mark() } }
        try #require(await TestDeadline.until { await lane.waitingCount == 1 })
        waiting.cancel()
        await lane.leave()
        do {
            _ = try await TestDeadline.value(waiting, "cancelled queued fixture suite")
            Issue.record("The queued cancellation must propagate")
        } catch is CancellationError { }
        #expect(await !entered.value)
        try await lane.withPermit { }
    }

}

private enum FixtureLaneError: Error { case expected }
private actor FixtureLaneProbe {
    private(set) var value = false
    func mark() { value = true }
}
