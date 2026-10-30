import Darwin
import Foundation
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
        func matches(_ info: stat) -> Bool {
            info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && self == Identity(info)
        }
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
    static func removeIfMatching(_ directory: Int32, name: String, identity: Identity) {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, identity.matches(info) { _ = unlinkat(directory, name, 0) }
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
    static func recover(_ root: Int32, status: (Int32) -> OwnerStatus = ownerStatus) throws -> Int {
        var removed = 0
        for project in try names(root) {
            guard (try? VoiceLabAssetNaming.file(projectId: project, assetId: "probe", extension: "wav")) != nil else { continue }
            let directory = openat(root, project, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            for name in try names(directory) {
                guard name.hasPrefix("."), name.hasSuffix(".partial.owner.json"),
                      let (record, journalIdentity) = readJournal(directory, name: name),
                      name == record.name + ".owner.json", !record.name.contains("/") else { continue }
                let stem = String(record.name.dropFirst().dropLast(8))
                let identity: String
                if let separator = stem.range(of: ".wav.", options: .backwards) {
                    let asset = String(stem[..<separator.lowerBound])
                    guard (try? VoiceLabAssetNaming.file(projectId: project, assetId: asset, extension: "wav")) == "\(project)/\(asset).wav" else { continue }
                    identity = String(stem[separator.upperBound...])
                } else if stem.hasPrefix("asset-retention.") {
                    identity = String(stem.dropFirst("asset-retention.".count))
                } else { continue }
                guard let uuid = UUID(uuidString: identity), uuid.uuidString.lowercased() == identity else { continue }
                var info = stat()
                switch status(record.owner.pid) {
                case .unknown: continue
                case .running(let actual) where actual == record.owner: continue
                case .gone, .running: break
                }
                guard fstatat(directory, record.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      record.identity.matches(info) else { continue }
                guard unlinkat(directory, record.name, 0) == 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
                removeIfMatching(directory, name: name, identity: journalIdentity)
                removed += 1
            }
            guard VoiceLabPaidRoot.fullSync(directory) else { throw VoiceLabAssetStoreError.unwritable(project) }
        }
        return removed
    }
}
