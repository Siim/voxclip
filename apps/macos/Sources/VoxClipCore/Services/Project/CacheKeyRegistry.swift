import Foundation
import Synchronization

/// The content keys in use in one cache folder (architecture §8.2). Everything that reads or writes a cache entry holds
/// a lease on its key while it works: each open project, extraction, transcription, waveform read and thumbnail.
/// Eviction never strips or removes a leased entry. Every `CacheStore` of a folder shares its registry, so eviction
/// also runs one pass at a time there, whether it is a background pass or Clear cache.
public final class CacheKeyRegistry: Sendable {
    private struct State {
        var leases: [String: Int] = [:]
        /// The entry eviction is stripping or removing now. A lease on it waits until that is done.
        var evicting: String?
        var leaseWaiters: [CheckedContinuation<Void, Never>] = []
        var evictionRunning = false
        var evictionWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private static let folders = Mutex<[String: CacheKeyRegistry]>([:])
    private let state = Mutex(State())

    /// The registry of a cache folder, the same for every caller in this process.
    public static func shared(cache: URL) -> CacheKeyRegistry {
        folders.withLock { folders in
            let path = cache.standardizedFileURL.path
            if let existing = folders[path] { return existing }
            let registry = CacheKeyRegistry()
            folders[path] = registry
            return registry
        }
    }

    /// Marks `key` in use until the lease is released. If eviction is stripping or removing that entry right now, this
    /// waits until it has finished, so the holder finds the entry whole or gone, and a missing entry is recomputed.
    public func lease(_ key: String) async -> CacheKeyLease {
        let lease = leaseNow(key)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiting = state.withLock { state in
                guard state.evicting == key else { return false }
                state.leaseWaiters.append(continuation)
                return true
            }
            if !waiting { continuation.resume() }
        }
        return lease
    }

    /// Marks `key` in use at once, for a holder that cannot wait, such as a project as it opens. An eviction that is
    /// already working on that entry finishes it.
    public func leaseNow(_ key: String) -> CacheKeyLease {
        state.withLock { $0.leases[key, default: 0] += 1 }
        return CacheKeyLease(registry: self, key: key)
    }

    public func isLeased(_ key: String) -> Bool { state.withLock { $0.leases[key] != nil } }
    public var leasedKeys: Set<String> { state.withLock { Set($0.leases.keys) } }

    func release(_ key: String) {
        state.withLock { state in
            guard let count = state.leases[key] else { return }
            state.leases[key] = count > 1 ? count - 1 : nil
        }
    }

    /// Takes the folder's eviction turn, waiting in arrival order while another pass has it.
    func beginEviction() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state in
                guard state.evictionRunning else { state.evictionRunning = true; return true }
                state.evictionWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Hands the eviction turn to the next waiting pass, if any.
    func endEviction() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.evictionWaiters.isEmpty else { state.evictionRunning = false; return nil }
            return state.evictionWaiters.removeFirst()
        }
        next?.resume()
    }

    /// Passes waiting for the eviction turn.
    var waitingEvictions: Int { state.withLock { $0.evictionWaiters.count } }

    /// Claims an entry for eviction unless it is leased or in `protected`. Until `endClaim`, a new lease on it waits.
    func claim(_ key: String, unless protected: Set<String>) -> Bool {
        state.withLock { state in
            guard state.leases[key] == nil, !protected.contains(key) else { return false }
            state.evicting = key
            return true
        }
    }

    func endClaim() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.evicting = nil
            defer { state.leaseWaiters.removeAll() }
            return state.leaseWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// One holder's use of a cache key. Release it when the work ends; dropping the last reference releases it too.
public final class CacheKeyLease: Sendable {
    public let key: String
    private let registry: CacheKeyRegistry
    private let released = Mutex(false)

    init(registry: CacheKeyRegistry, key: String) { self.registry = registry; self.key = key }

    public func release() {
        let first = released.withLock { released in
            defer { released = true }
            return !released
        }
        if first { registry.release(key) }
    }

    deinit { release() }
}
