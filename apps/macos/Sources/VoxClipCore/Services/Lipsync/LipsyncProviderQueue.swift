import Foundation

actor LipsyncProviderQueue {
    struct Lease: Sendable, Equatable { let account: String; let id: UUID }
    private struct Waiter {
        let lease: Lease
        let continuation: CheckedContinuation<Lease, any Error>
    }
    static let shared = LipsyncProviderQueue()
    private var active: [String: Lease] = [:]
    private var waiting: [String: [Waiter]] = [:]

    func acquire(account: String) async throws -> Lease {
        let lease = Lease(account: account, id: UUID())
        do {
            return try await withThrowingTaskGroup(of: Lease.self) { group in
                group.addTask { try await self.reserve(lease) }
                group.addTask {
                    try await Task.sleep(for: .seconds(LipsyncLimits.quoteLifetimeSeconds))
                    throw LipsyncError.expiredQuote
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        } catch { cancel(lease); throw error }
    }

    private func reserve(_ lease: Lease) async throws -> Lease {
        let account = lease.account
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    if active[account] == nil {
                        active[account] = lease; continuation.resume(returning: lease)
                    } else if (waiting[account]?.count ?? 0) < 16 {
                        waiting[account, default: []].append(Waiter(lease: lease, continuation: continuation))
                    } else { continuation.resume(throwing: LipsyncError.busy) }
                }
            } onCancel: { Task { await self.cancel(lease) } }
            try Task.checkCancellation()
            return result
        } catch { cancel(lease); throw error }
    }

    func release(_ lease: Lease) {
        guard active[lease.account] == lease else { return }
        active.removeValue(forKey: lease.account)
        if var queue = waiting[lease.account], !queue.isEmpty {
            let next = queue.removeFirst(); waiting[lease.account] = queue
            active[lease.account] = next.lease
            next.continuation.resume(returning: next.lease)
        }
    }

    private func cancel(_ lease: Lease) {
        if let index = waiting[lease.account]?.firstIndex(where: { $0.lease == lease }),
           let waiter = waiting[lease.account]?.remove(at: index) { waiter.continuation.resume(throwing: CancellationError()) }
        else { release(lease) }
    }
}
