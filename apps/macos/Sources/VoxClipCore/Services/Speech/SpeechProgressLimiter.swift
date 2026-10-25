import Foundation
import Synchronization

public final class SpeechProgressLimiter<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var last: ContinuousClock.Instant?
        var pending: Value?
        var task: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let callback: @Sendable (Value) -> Void

    public init(callback: @escaping @Sendable (Value) -> Void) { self.callback = callback }

    public func report(_ value: Value) {
        let now = ContinuousClock.now
        let immediate = state.withLock { state in
            if state.task == nil, state.last == nil || state.last!.duration(to: now) >= .milliseconds(100) {
                state.last = now
                return true
            }
            state.pending = value
            if state.task == nil {
                let deadline = (state.last ?? now).advanced(by: .milliseconds(100))
                state.task = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    self?.deliverPending()
                }
            }
            return false
        }
        if immediate { callback(value) }
    }

    private func deliverPending() {
        let value = state.withLock { state -> Value? in
            let value = state.pending
            state.pending = nil
            state.last = .now
            return value
        }
        if let value { callback(value) }
        state.withLock { state in
            state.task = nil
            if state.pending != nil {
                state.task = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    self?.deliverPending()
                }
            }
        }
    }

    public func finish() async {
        while let task = state.withLock({ $0.task }) { await task.value }
    }

    public func cancel() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            state.pending = nil
        }
    }
}

typealias SpeechProgressThrottle = SpeechProgressLimiter<TranscriptionProgress>
