import Dispatch
import Foundation
import Synchronization
import Testing

/// Test-owned waits must finish even when the operation under test never acknowledges cancellation.
/// The three test targets link this source, so their synchronization rules stay identical.
enum TestDeadlineFailure: Error { case timedOut(String) }

final class TestContinuation<Value: Sendable>: Sendable {
    private let pending: Mutex<CheckedContinuation<Result<Value, TestDeadlineFailure>, Never>?>
    init(_ continuation: CheckedContinuation<Result<Value, TestDeadlineFailure>, Never>) {
        pending = Mutex(continuation)
    }
    private func finish(_ result: Result<Value, TestDeadlineFailure>) {
        let continuation = pending.withLock { value in
            let continuation = value
            value = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
    func resume(returning value: Value) { finish(.success(value)) }
    func expire() { finish(.failure(.timedOut("test continuation"))) }
}
extension TestContinuation where Value == Void {
    func resume() { resume(returning: ()) }
}

func withTestDeadline<Value: Sendable>(returning fallback: Value, timeout: Duration = .seconds(10),
    isolation: isolated (any Actor)? = #isolation, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (TestContinuation<Value>) -> Void) async -> Value {
    let result: Result<Value, TestDeadlineFailure> = await withCheckedContinuation { raw in
        let continuation = TestContinuation(raw)
        let parts = timeout.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { continuation.expire() }
        body(continuation)
    }
    switch result {
    case .success(let value): return value
    case .failure:
        Issue.record("Test continuation did not resume within \(timeout)", sourceLocation: sourceLocation)
        return fallback
    }
}
func withTestDeadline(timeout: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (TestContinuation<Void>) -> Void) async {
    await withTestDeadline(returning: (), timeout: timeout, sourceLocation: sourceLocation, body)
}

private final class TestTaskResult<Value: Sendable>: Sendable {
    let value = Mutex<Result<Value, any Error>?>(nil)
}
enum TestDeadline {
    @discardableResult static func until(timeout: Duration = .seconds(10),
        isolation: isolated (any Actor)? = #isolation, sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if await condition() { return true }
            guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
            // Yielding can immediately requeue and starve HTTP/native callbacks while
            // CPU-heavy audio suites run. Suspend between polls without extending the deadline.
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Test condition did not become true within \(timeout)", sourceLocation: sourceLocation)
        return false
    }

    static func value<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>?, _ label: String,
        timeout: Duration = .seconds(10), isolation: isolated (any Actor)? = #isolation,
        sourceLocation: SourceLocation = #_sourceLocation) async throws -> Value? {
        guard let task else { return nil }
        let completion = TestTaskResult<Value>()
        let observer = Task {
            let result = await task.result.mapError { $0 as any Error }
            completion.value.withLock { $0 = result }
        }
        defer { observer.cancel() }
        guard await until(timeout: timeout, sourceLocation: sourceLocation, { completion.value.withLock { $0 != nil } }) else {
            task.cancel()
            throw TestDeadlineFailure.timedOut(label)
        }
        return try completion.value.withLock { try $0!.get() }
    }
}
