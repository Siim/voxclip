import Foundation
import Synchronization

/// Keeps one data folder's cache under the "Cache size limit" setting (architecture §8.2). A background pass runs
/// `launchDelay` after launch, after each import and when the user lowers the limit; Clear cache runs here too.
///
/// Passes never overlap: every pass takes the cache folder's eviction turn in `CacheKeyRegistry`, so a background pass
/// and Clear cache wait for each other, and a request made while a pass is queued is answered by that pass. Leased keys
/// (open projects, extractions, transcriptions, waveform reads, thumbnails) are never touched. Every pass, Clear cache
/// included, spares an entry without readable metadata while anything in it was written in the last `unindexedGrace`:
/// it may be an extraction under way in the CLI. A failed pass is logged and never shown: a missing entry is
/// recomputed.
public final class CacheEvictionScheduler: Sendable {
    /// How long after launch the first pass waits, so it never competes with opening the app.
    public static let launchDelay: Duration = .seconds(30)
    /// How long an entry without readable metadata is left alone after its last write.
    public static let unindexedGrace: TimeInterval = 3_600
    /// The setting is in decimal gigabytes, as Finder counts them.
    public static let bytesPerGB: Int64 = 1_000_000_000
    public static let defaultLimitBytes: Int64 = 5 * bytesPerGB

    /// `cache.limitGB` in bytes; an unusable value falls back to the 5 GB default.
    public static func limitBytes(gigabytes: Double) -> Int64 {
        guard gigabytes.isFinite, gigabytes > 0, gigabytes <= 1_000 else { return defaultLimitBytes }
        return Int64((gigabytes * Double(bytesPerGB)).rounded())
    }

    private struct State {
        var launch: Task<Void, Never>?
        var tail: Task<Void, Never>?
        var queued = false
        var completedRuns = 0
    }
    private let store: CacheStore
    private let log: any Logger
    private let currentLimit: @Sendable () async -> Int64
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    /// `limitBytes` is read when each pass starts. `sleep` and `now` are injectable for tests.
    public init(store: CacheStore, log: any Logger, limitBytes: @escaping @Sendable () async -> Int64,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.log = log; currentLimit = limitBytes; self.sleep = sleep; self.now = now
    }

    /// Schedules the launch pass `launchDelay` from now. Later calls return the same task.
    @discardableResult public func scheduleAfterLaunch() -> Task<Void, Never> {
        state.withLock { state in
            if let launch = state.launch { return launch }
            let task = Task { [self] in
                do { try await self.sleep(Self.launchDelay) } catch { return }
                self.requestRun()
            }
            state.launch = task
            return task
        }
    }

    /// Asks for a background pass now: after an import, or when the limit is lowered. A pass that is queued and has not
    /// started answers the request; one that has started is followed by another.
    public func requestRun() {
        state.withLock { state in
            guard !state.queued else { return }
            state.queued = true
            let previous = state.tail
            state.tail = Task { [self] in
                await previous?.value
                await self.run()
            }
        }
    }

    /// Clear cache (architecture §8.2): the first pass with a limit of 0, so every entry not in use keeps its envelope
    /// and raw transcripts. It waits for a background pass that is running. A failure is only logged.
    public func clearCache() async {
        await pass(limit: 0, keepingEnvelopes: true, name: "clear")
    }

    /// Whether the launch pass has been scheduled.
    public var launchScheduled: Bool { state.withLock { $0.launch != nil } }
    /// Background passes that have finished.
    public var completedRuns: Int { state.withLock { $0.completedRuns } }

    /// Waits until no background pass is queued or running; the launch pass counts once its delay is over.
    public func waitUntilIdle() async {
        while true {
            let tail = state.withLock { $0.tail }
            await tail?.value
            if state.withLock({ $0.tail }) == tail { return }
        }
    }

    private func run() async {
        state.withLock { $0.queued = false }
        await pass(limit: await currentLimit(), keepingEnvelopes: false, name: "background")
        state.withLock { $0.completedRuns += 1 }
    }

    private func pass(limit: Int64, keepingEnvelopes: Bool, name: String) async {
        do {
            try await store.evict(limitBytes: limit, protectedKeys: [], keepingEnvelopes: keepingEnvelopes,
                                  sparingUnindexedSince: now().addingTimeInterval(-Self.unindexedGrace))
        } catch {
            await log.write(LogEntry(level: .warn, category: "cache", message: "eviction=failed pass=\(name)"))
        }
    }
}
