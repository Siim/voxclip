import Foundation
import Synchronization

enum StopWatchdogError: Error { case timedOut }

private final class StopCompletion<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = Mutex(continuation) }
    func finish(_ result: Result<Value, any Error>) {
        let pending = continuation.withLock { current in
            let pending = current
            current = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

func awaitStoppedExport<Value: Sendable>(_ task: Task<Value, any Error>,
                                       stoppedAt: @escaping @Sendable () -> ContinuousClock.Instant?) async throws -> Value {
    let watchdog = Mutex<Task<Void, Never>?>(nil)
    let result: Result<Value, any Error>
    do {
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
            let completion = StopCompletion(continuation)
            Task { completion.finish(await task.result) }
            watchdog.withLock { current in
                current = Task {
                    do {
                        while stoppedAt() == nil { try await Task.sleep(for: .milliseconds(1)) }
                        if let stopped = stoppedAt() {
                            try await Task.sleep(until: stopped.advanced(by: .seconds(2)), clock: .continuous)
                        }
                        completion.finish(.failure(StopWatchdogError.timedOut))
                        task.cancel()
                    } catch {}
                }
            }
        }
        result = .success(value)
    } catch { result = .failure(error) }
    let timer = watchdog.withLock { $0 }
    timer?.cancel()
    await timer?.value
    return try result.get()
}
