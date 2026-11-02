import Testing

@Suite("Test wait deadlines")
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
}
