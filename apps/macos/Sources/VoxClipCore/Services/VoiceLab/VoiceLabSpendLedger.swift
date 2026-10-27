import Darwin
import Foundation

extension VoiceLabPriceCatalog {
    /// Reads `catalog/voice-lab.json` beneath the shared root; voice-lab §3.2.
    public static func load(shared: SharedResources) throws -> VoiceLabPriceCatalog {
        guard let data = try? Data(contentsOf: shared.root.appendingPathComponent("catalog/voice-lab.json")) else {
            throw VoxClipError.sharedResourcesMissing
        }
        return try VoiceLabPriceCatalog(data: data)
    }
}

/// Why a spend record was not applied as asked. The provider already accepted the action, so the ledger never throws.
public enum VoiceLabSpendWarning: Sendable, Equatable {
    /// The previous file was unreadable. It now has this name in the same directory; a fresh ledger holds the record.
    case replacedCorruptLedger(backupFileName: String)
    /// Another writer held `spend.json.lock` for `lockTimeout`; nothing was recorded.
    case lockTimedOut
    /// The task was cancelled while it waited for the lock; nothing was recorded.
    case cancelled
    /// The ledger could not be read or written, for example on a read-only or full volume or without its data folder;
    /// nothing was recorded.
    case writeFailed
    /// The estimate has no valid provider id or a negative amount; nothing was recorded.
    case invalidEstimate
}

/// `<data>/VoiceLab/spend.json`, the estimate of what Voice Lab actions cost per provider and local month; voice-lab
/// §3.1. The App and CLI can record at the same time. A writer holds an exclusive `flock` on `spend.json.lock`, which is
/// never deleted, while it reads, adds and replaces the file; a reader holds a shared one. The lock is polled with
/// `Task.sleep`, so a busy ledger never blocks a thread, and these nonisolated async methods never run on the caller's
/// actor. Only `EWOULDBLOCK` means another holder: any other failure is `writeFailed` at once.
///
/// The paid root is opened as the asset store opens it (`VoiceLabPaidRoot`): only `VoiceLab` itself is ever created,
/// with mode 0700, never the data folder. Each write goes to a 0600 temporary file in the root, is flushed with
/// `F_FULLFSYNC` and renamed over the ledger, and the root is flushed after the rename.
public struct VoiceLabSpendLedger: Sendable {
    public let url: URL
    /// The zone that buckets months. The default follows the system zone as the user changes it, so an action counts in
    /// the local month current when it is recorded, right after it ran; tests inject a fixed zone.
    public let timeZone: TimeZone
    /// How long a writer waits for another holder of the lock before it gives up with `lockTimedOut`.
    public let lockTimeout: Duration

    public init(locations: DataLocations, timeZone: TimeZone = .autoupdatingCurrent, lockTimeout: Duration = .seconds(5)) {
        self.init(url: locations.root.appendingPathComponent("VoiceLab", isDirectory: true).appendingPathComponent("spend.json"),
                  timeZone: timeZone, lockTimeout: lockTimeout)
    }

    public init(url: URL, timeZone: TimeZone = .autoupdatingCurrent, lockTimeout: Duration = .seconds(5)) {
        self.url = url; self.timeZone = timeZone; self.lockTimeout = lockTimeout
    }

    /// Readers wait at most this long for a writer, so a cap check never stalls the interface.
    public var readTimeout: Duration { min(lockTimeout, .milliseconds(500)) }

    public func month(of date: Date) -> String { VoiceLabSpendDocument.month(of: date, in: timeZone) }

    /// The ledger, read under the shared lock. A missing ledger or root reads as empty, and so does a corrupt file, which
    /// the next record moves aside. Nil when the ledger cannot be read now, such as a writer holding the lock past
    /// `readTimeout`.
    public func read() async -> VoiceLabSpendDocument? {
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return errno == ENOENT ? VoiceLabSpendDocument() : nil }
        defer { Darwin.close(root) }
        let lock = Darwin.openat(root, lockName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        // Without a lock file no writer has run here; a rename is atomic, so the file is read whole or not at all.
        guard lock >= 0 else { return errno == ENOENT ? document(in: root) : nil }
        defer { Darwin.close(lock) }
        guard await acquire(lock, LOCK_SH, waiting: readTimeout) == nil else { return nil }
        return document(in: root)
    }

    /// The provider's spend in the local month of `start`, or nil when the ledger cannot be read now.
    public func total(provider: String, at start: Date) async -> VoiceLabSpendTotal? {
        await read()?.total(provider: provider, month: month(of: start))
    }

    /// Adds the estimate of one action that ran, once, after the provider accepted it, under the local month of `start`.
    /// A free action (exactly $0) is not recorded and touches nothing.
    @discardableResult
    public func record(_ estimate: CostEstimate, at start: Date) async -> VoiceLabSpendWarning? {
        let month = month(of: start)
        var document = VoiceLabSpendDocument()
        do { try document.record(estimate, month: month) } catch { return .invalidEstimate }
        if estimate.usd == 0 { return nil }
        let root: Int32
        do { root = try VoiceLabPaidRoot.open(directory) } catch { return .writeFailed }
        defer { Darwin.close(root) }
        let lock = Darwin.openat(root, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { return .writeFailed }
        defer { Darwin.close(lock) }
        if let failure = await acquire(lock, LOCK_EX, waiting: lockTimeout) { return failure }
        var warning: VoiceLabSpendWarning?
        document = VoiceLabSpendDocument()
        switch contents(in: root) {
        case .missing: break
        case .failed: return .writeFailed
        case .bytes(let data):
            if let existing = VoiceLabSpendDocument(data: data) {
                document = existing
            } else {
                guard let backup = moveAside(in: root) else { return .writeFailed }
                warning = .replacedCorruptLedger(backupFileName: backup)
            }
        }
        do { try document.record(estimate, month: month) } catch { return .invalidEstimate }
        guard write(document.encoded(), in: root) else { return .writeFailed }
        return warning
    }

    /// True when a known estimate takes the provider's total for the month of `start` from at most `cap` to above it.
    /// The total is read under the lock; a ledger that cannot be read now gives false.
    public func wouldCross(cap: Decimal, provider: String, estimate: CostEstimate, at start: Date) async -> Bool {
        guard estimate.usd != nil, let spent = await total(provider: provider, at: start) else { return false }
        return VoiceLabMonthlyCap(limit: cap, spent: spent.usd).isCrossed(by: estimate)
    }

    private var directory: URL { url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() }
    private var name: String { url.lastPathComponent }
    private var lockName: String { name + ".lock" }

    /// Polls a nonblocking `flock`, sleeping between attempts, so a busy lock costs at most `timeout` and never blocks
    /// a thread. Nil once the lock is held.
    private func acquire(_ lock: Int32, _ operation: Int32, waiting timeout: Duration) async -> VoiceLabSpendWarning? {
        let deadline = ContinuousClock.now + timeout
        // Unqualified: `Darwin.flock` names the fcntl lock struct, not the function.
        while flock(lock, operation | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { return .writeFailed }
            guard ContinuousClock.now < deadline else { return .lockTimedOut }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return .cancelled }
        }
        return nil
    }

    private enum Contents { case missing, failed, bytes(Data) }

    /// The ledger's bytes, opened through the root and never through a link.
    private func contents(in root: Int32) -> Contents {
        let fd = Darwin.openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .failed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // readToEnd gives nil for an empty file, which is corrupt rather than unreadable.
        do { return .bytes(try handle.readToEnd() ?? Data()) } catch { return .failed }
    }

    /// The ledger for a reader: missing or corrupt is empty, an unreadable file is nil.
    private func document(in root: Int32) -> VoiceLabSpendDocument? {
        switch contents(in: root) {
        case .missing: VoiceLabSpendDocument()
        case .failed: nil
        case .bytes(let data): VoiceLabSpendDocument(data: data) ?? VoiceLabSpendDocument()
        }
    }

    /// Replaces the ledger through a 0600 temporary file in the root, flushed with `F_FULLFSYNC` before the rename. The
    /// root is flushed after it; that flush failing keeps the record, because the rename already happened.
    private func write(_ data: Data, in root: Int32) -> Bool {
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let fd = Darwin.openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let flushed = data.withUnsafeBytes { Self.writeAll(fd, $0) } && VoiceLabPaidRoot.fullSync(fd)
        Darwin.close(fd)
        guard flushed, Darwin.renameat(root, temporary, root, name) == 0 else {
            _ = Darwin.unlinkat(root, temporary, 0)
            return false
        }
        _ = VoiceLabPaidRoot.fullSync(root)
        return true
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(fd, base + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// Renames the unreadable file to `<name>.corrupt-<unix milliseconds>.json`, adding `-1`, `-2` … when that name is
    /// taken. `RENAME_EXCL` never replaces another file.
    private func moveAside(in root: Int32) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent + ".corrupt-" + String(Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down)))
        for suffix in 0..<1_000 {
            let backup = stem + (suffix == 0 ? "" : "-\(suffix)") + ".json"
            if renameatx_np(root, name, root, backup, UInt32(RENAME_EXCL)) == 0 { return backup }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }
}
