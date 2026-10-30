import Darwin
import Foundation
import Synchronization
import VoxClipCore

enum VoiceLabAssetRecovery {
    struct Owner: Codable, Equatable {
        let pid: Int32
        let seconds: Int64
        let microseconds: Int32
    }
    enum OwnerStatus { case running(Owner), gone, unknown }
    struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanos: Int64
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino
            birthSeconds = Int64(info.st_birthtimespec.tv_sec); birthNanos = Int64(info.st_birthtimespec.tv_nsec)
        }
        func matches(_ info: stat, type: mode_t = S_IFREG) -> Bool {
            info.st_mode & S_IFMT == type && info.st_uid == getuid() && self == Identity(info)
        }
    }
    struct DirectoryRecord: Codable {
        let name: String
        let owner: Owner
        let identity: Identity?
    }
    static func intentName(_ operation: String) -> String { ".voxclip-\(operation).intent.json" }
    final class Operation: Sendable {
        let descriptor: Int32
        let name: String
        private let parent: Int32
        private let record: DirectoryRecord
        private let intentIdentity: Identity
        private let removed = Mutex(false)

        init(parent: Int32, owner: Owner? = nil, checkpoint: ((String) throws -> Void)? = nil) throws {
            let current: Owner
            if let owner { current = owner }
            else if case .running(let actual) = ownerStatus(getpid()) { current = actual }
            else { throw VoiceLabAssetStoreError.unwritable("operation owner") }
            name = "op-\(UUID().uuidString.lowercased())"
            let parentCopy = fcntl(parent, F_DUPFD_CLOEXEC, 0)
            guard parentCopy >= 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
            var directory: Int32 = -1
            var created = false
            var identity: Identity?
            var intent: Identity?
            do {
                intent = try writeRecord(DirectoryRecord(name: name, owner: current, identity: nil),
                    directory: parentCopy, filename: intentName(name))
                try checkpoint?("intent")
                guard mkdirat(parentCopy, name, 0o700) == 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
                created = true
                directory = openat(parentCopy, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var info = stat()
                guard directory >= 0, fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                      info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw VoiceLabAssetStoreError.unsafePath(name) }
                identity = Identity(info)
                try checkpoint?("directory")
                _ = try writeRecord(DirectoryRecord(name: name, owner: current, identity: identity), directory: directory)
                guard VoiceLabPaidRoot.fullSync(parentCopy) else { throw VoiceLabAssetStoreError.unwritable(name) }
            } catch {
                if let identity {
                    let record = DirectoryRecord(name: name, owner: current, identity: identity)
                    if (try? clear(directory, parent: parentCopy, record: record)) == true, let intent {
                        removeIntent(parentCopy, name: name, identity: intent)
                    }
                } else if !created, let intent { removeIntent(parentCopy, name: name, identity: intent) }
                if directory >= 0 { close(directory) }
                close(parentCopy); throw error
            }
            self.parent = parentCopy; descriptor = directory
            record = DirectoryRecord(name: name, owner: current, identity: identity)
            intentIdentity = intent!
        }

        static func create(in root: URL) throws -> Operation {
            let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw VoiceLabAssetStoreError.unsafePath(root.lastPathComponent) }
            defer { close(parent) }
            return try Operation(parent: parent)
        }

        func discard() {
            removed.withLock { removed in
                guard !removed else { return }
                removed = true
                if (try? clear(descriptor, parent: parent, record: record)) == true {
                    removeIntent(parent, name: name, identity: intentIdentity)
                }
            }
        }

        deinit { discard(); close(descriptor); close(parent) }
    }

    @discardableResult static func writeRecord(_ record: DirectoryRecord, directory: Int32, filename: String = ".operation.json") throws -> Identity {
        let descriptor = openat(directory, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VoiceLabAssetStoreError.unwritable(record.name) }
        defer { close(descriptor) }
        let bytes = try JSONEncoder().encode(record)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VoiceLabAssetStoreError.unwritable(record.name) }
                offset += count
            }
        }
        guard VoiceLabPaidRoot.fullSync(descriptor), VoiceLabPaidRoot.fullSync(directory) else {
            throw VoiceLabAssetStoreError.unwritable(record.name)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw VoiceLabAssetStoreError.unwritable(record.name) }
        return Identity(info)
    }

    private static func directoryRecord(_ descriptor: Int32, filename: String = ".operation.json") -> DirectoryRecord? {
        let journal = openat(descriptor, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard journal >= 0 else { return nil }
        defer { close(journal) }
        var info = stat()
        guard fstat(journal, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              (1...4096).contains(info.st_size) else { return nil }
        var bytes = Data(count: Int(info.st_size))
        guard bytes.withUnsafeMutableBytes({ Darwin.read(journal, $0.baseAddress, $0.count) }) == bytes.count else { return nil }
        return try? JSONDecoder().decode(DirectoryRecord.self, from: bytes)
    }

    private static func clear(_ descriptor: Int32, parent: Int32, record: DirectoryRecord) throws -> Bool {
        var info = stat()
        guard let identity = record.identity, fstat(descriptor, &info) == 0, identity.matches(info, type: S_IFDIR),
              info.st_mode & 0o777 == 0o700 else { return false }
        let entries = try names(descriptor).filter { $0 != ".operation.json" }
        for name in entries {
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT != S_IFDIR else { return false }
        }
        for name in entries {
            guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else {
                throw VoiceLabAssetStoreError.unwritable(record.name)
            }
        }
        guard unlinkat(descriptor, ".operation.json", 0) == 0 || errno == ENOENT else {
            throw VoiceLabAssetStoreError.unwritable(record.name)
        }
        if fstatat(parent, record.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
           identity.matches(info, type: S_IFDIR) { _ = unlinkat(parent, record.name, AT_REMOVEDIR) }
        guard VoiceLabPaidRoot.fullSync(parent) else { throw VoiceLabAssetStoreError.unwritable(record.name) }
        return true
    }
    private static func removeIntent(_ parent: Int32, name: String, identity: Identity) {
        var info = stat()
        let journal = intentName(name)
        if fstatat(parent, journal, &info, AT_SYMLINK_NOFOLLOW) == 0, identity.matches(info) {
            _ = unlinkat(parent, journal, 0)
            _ = VoiceLabPaidRoot.fullSync(parent)
        }
    }

    private static func recoverIntents(_ parent: Int32, status: (Int32) -> OwnerStatus,
                                       afterOpening: ((String) throws -> Void)?, reportRetained: (LogEntry) -> Void) throws -> Int {
        var removed = 0
        for journal in try names(parent) {
            guard journal.hasPrefix(".voxclip-op-"), journal.hasSuffix(".intent.json"),
                  let intent = directoryRecord(parent, filename: journal), intent.identity == nil,
                  journal == intentName(intent.name), intent.name.hasPrefix("op-"),
                  let uuid = UUID(uuidString: String(intent.name.dropFirst(3))),
                  intent.name == "op-\(uuid.uuidString.lowercased())" else { continue }
            var journalInfo = stat()
            guard fstatat(parent, journal, &journalInfo, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            switch status(intent.owner.pid) {
            case .unknown: continue
            case .running(let actual) where actual == intent.owner: continue
            case .gone, .running: break
            }
            var pathInfo = stat()
            guard fstatat(parent, intent.name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { removeIntent(parent, name: intent.name, identity: Identity(journalInfo)) }
                continue
            }
            guard pathInfo.st_mode & S_IFMT == S_IFDIR, pathInfo.st_uid == getuid(), pathInfo.st_mode & 0o777 == 0o700 else { continue }
            let directory = openat(parent, intent.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            var opened = stat()
            let identity = Identity(pathInfo)
            guard fstat(directory, &opened) == 0, identity.matches(opened, type: S_IFDIR) else { continue }
            let record: DirectoryRecord
            if let receipt = directoryRecord(directory) {
                guard receipt.name == intent.name, receipt.owner == intent.owner,
                      receipt.identity?.matches(opened, type: S_IFDIR) == true else { continue }
                record = receipt
            } else {
                try afterOpening?(intent.name)
                guard fstatat(parent, intent.name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
                      identity.matches(pathInfo, type: S_IFDIR) else { continue }
                if unlinkat(parent, intent.name, AT_REMOVEDIR) == 0 {
                    removeIntent(parent, name: intent.name, identity: Identity(journalInfo)); removed += 1
                } else if errno == ENOTEMPTY || errno == EEXIST {
                    reportRetained(LogEntry(level: .warn, category: "voice-lab",
                        message: "Kept a non-empty Voice Lab operation directory without an ownership receipt."))
                }
                continue
            }
            try afterOpening?(intent.name)
            if try clear(directory, parent: parent, record: record) {
                removeIntent(parent, name: intent.name, identity: Identity(journalInfo)); removed += 1
            }
        }
        return removed
    }
    struct Partial: Codable {
        let name: String
        let owner: Owner
        let identity: Identity
    }
    struct Journal {
        let partial: Partial
        let name: String
        let identity: Identity
    }
    static func ownerStatus(_ pid: Int32) -> OwnerStatus {
        guard pid > 0 else { return .unknown }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0 else {
            return errno == ESRCH ? .gone : .unknown
        }
        guard size > 0 else { return .gone }
        return .running(Owner(pid: pid, seconds: Int64(info.kp_proc.p_starttime.tv_sec), microseconds: Int32(info.kp_proc.p_starttime.tv_usec)))
    }
    static func recordPartial(_ directory: Int32, name: String, descriptor: Int32, owner: Owner? = nil) throws -> Journal {
        let current: Owner
        if let owner { current = owner }
        else if case .running(let value) = ownerStatus(getpid()) { current = value }
        else { throw VoiceLabAssetStoreError.unwritable(name) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw VoiceLabAssetStoreError.unsafePath(name)
        }
        let partial = Partial(name: name, owner: current, identity: Identity(info))
        let journal = name + ".owner.json"
        let fd = openat(directory, journal, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VoiceLabAssetStoreError.unwritable(journal) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0 else { throw VoiceLabAssetStoreError.unwritable(journal) }
        let identity = Identity(info)
        let bytes = try JSONEncoder().encode(partial)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VoiceLabAssetStoreError.unwritable(journal) }
                offset += count
            }
        }
        guard VoiceLabPaidRoot.fullSync(fd), VoiceLabPaidRoot.fullSync(directory) else { throw VoiceLabAssetStoreError.unwritable(journal) }
        return Journal(partial: partial, name: journal, identity: identity)
    }
    static func ownsComplete(_ directory: Int32, name: String, info: stat) -> Bool {
        guard let (partial, _) = readJournal(directory, name: ".\(name).ownership.json"),
              partial.name.hasPrefix(".\(name)."), partial.identity.matches(info) else { return false }
        return true
    }
    private static func readJournal(_ directory: Int32, name: String) -> (Partial, Identity)? {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), (1...4096).contains(info.st_size) else { return nil }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count, let record = try? JSONDecoder().decode(Partial.self, from: bytes) else { return nil }
        return (record, Identity(info))
    }
    static func lock(_ root: Int32) throws -> Int32 {
        let descriptor = openat(root, ".asset-write.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VoiceLabAssetStoreError.unwritable("VoiceLab") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor); throw VoiceLabAssetStoreError.unsafePath("VoiceLab")
        }
        return descriptor
    }
    static func names(_ descriptor: Int32) throws -> [String] {
        guard let directory = fdopendir(dup(descriptor)) else { throw VoiceLabAssetStoreError.unwritable("VoiceLab") }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw VoiceLabAssetStoreError.unwritable("VoiceLab") }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
    static func recover(_ root: Int32, status: (Int32) -> OwnerStatus = ownerStatus,
                        afterOpening: ((String) throws -> Void)? = nil,
                        reportRetained: (LogEntry) -> Void = logRetention) throws -> Int {
        var removed = 0
        for project in try names(root) {
            guard (try? VoiceLabAssetNaming.file(projectId: project, assetId: "probe", extension: "wav")) != nil else { continue }
            let directory = openat(root, project, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            removed += try recoverIntents(directory, status: status, afterOpening: afterOpening, reportRetained: reportRetained)
            for name in try names(directory) {
                guard name.hasPrefix(".voxclip-operation-"),
                      let uuid = UUID(uuidString: String(name.dropFirst(".voxclip-operation-".count))),
                      name == ".voxclip-operation-\(uuid.uuidString.lowercased())" else { continue }
                let operation = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard operation >= 0 else { continue }
                defer { close(operation) }
                var info = stat()
                guard let record = directoryRecord(operation), record.name == name,
                      fstat(operation, &info) == 0, record.identity?.matches(info, type: S_IFDIR) == true,
                      info.st_mode & 0o777 == 0o700 else { continue }
                switch status(record.owner.pid) {
                case .unknown: continue
                case .running(let actual) where actual == record.owner: continue
                case .gone, .running: break
                }
                try afterOpening?(name)
                if try clear(operation, parent: directory, record: record) { removed += 1 }
            }
            guard VoiceLabPaidRoot.fullSync(directory) else { throw VoiceLabAssetStoreError.unwritable(project) }
        }
        return removed
    }
    private static func logRetention(_ entry: LogEntry) {
        let logger = RedactingLogger(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        Task { await logger.write(entry) }
    }
}
