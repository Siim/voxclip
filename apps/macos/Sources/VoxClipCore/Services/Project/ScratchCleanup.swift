import Foundation
import Darwin

public enum ScratchCleanup {
    public struct ProcessOwner: Codable, Equatable, Sendable {
        var pid: Int32
        var startSeconds: Int64
        var startMicroseconds: Int64
    }
    fileprivate struct Identity: Codable, Equatable, Sendable {
        var device: Int32
        var inode: UInt64
        var birthSeconds: Int64
        var birthNanoseconds: Int64
    }
    fileprivate struct Lease: Codable, Sendable {
        var schema = "voxclip-export-scratch/4"
        var owner: ProcessOwner
        var directory: URL
        var identity: Identity
        var recovery = false
    }
    public struct ExportDirectory: Sendable {
        public let url: URL
        fileprivate let lease: Lease
        fileprivate let journal: Lease?
        fileprivate init(url: URL, lease: Lease, journal: Lease?) {
            self.url = url; self.lease = lease; self.journal = journal
        }
    }
    private static let leaseName = ".voxclip-owner.json"

    public static let processStart: Date = {
        guard let owner = try? processOwner(of: getpid()) else { return .distantPast }
        let seconds = Double(owner.startSeconds)
        let microseconds = Double(owner.startMicroseconds)
        let microsecondsPerSecond: Double = 1_000_000.0
        let fraction = microseconds / microsecondsPerSecond
        return Date(timeIntervalSince1970: seconds + fraction)
    }()

    static func processOwner(of pid: Int32) throws -> ProcessOwner? {
        guard pid > 0 else { throw POSIXError(.EINVAL) }
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        let status = query.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard status == 0 else {
            if errno == ESRCH { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard size == MemoryLayout<kinfo_proc>.size else {
            if size == 0 { return nil }
            throw CocoaError(.fileReadCorruptFile)
        }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return ProcessOwner(pid: pid, startSeconds: Int64(start.tv_sec), startMicroseconds: Int64(start.tv_usec))
    }

    public static func createExportDirectory(in parent: URL, registry: URL? = nil,
                                             owner: ProcessOwner? = nil, recovery: Bool = false) throws -> ExportDirectory {
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let parentDescriptor = try openDirectory(parent)
        defer { close(parentDescriptor) }
        let name = ".voxclip-export-\(UUID().uuidString)"
        guard mkdirat(parentDescriptor, name, 0o700) == 0 else { throw posixError() }
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, fchmod(descriptor, 0o700) == 0 else { throw posixError() }
        guard let owner = try owner ?? processOwner(of: getpid()) else { throw CocoaError(.fileWriteUnknown) }
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        let lease = Lease(owner: owner, directory: directory, identity: identity(attributes), recovery: recovery)
        var journal: Lease?
        do {
            let data = try JSONEncoder().encode(lease)
            try writeLease(data, descriptor: descriptor)
            if let registry {
                try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let record = try createExportDirectory(in: registry, owner: owner)
                journal = record.lease
                let registryDescriptor = try openDirectory(record.url)
                defer { close(registryDescriptor) }
                guard matches(registryDescriptor, record.lease.identity), privateDirectory(registryDescriptor) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try writeLease(data, descriptor: registryDescriptor, name: "reference.json")
            }
            return ExportDirectory(url: directory, lease: lease, journal: journal)
        } catch {
            _ = removeDirectory(lease)
            if let journal { _ = removeDirectory(journal) }
            throw error
        }
    }

    public static func discardExportDirectory(_ directory: ExportDirectory) {
        guard (try? processOwner(of: getpid())) == directory.lease.owner else { return }
        if removeDirectory(directory.lease), let journal = directory.journal { _ = removeDirectory(journal) }
    }

    public static func discardExportDirectory(at directory: URL) {
        guard let lease = readLease(directory), (try? processOwner(of: getpid())) == lease.owner,
              !lease.recovery else { return }
        _ = removeDirectory(lease)
    }

    @discardableResult public static func sweep(registry: URL, cache: URL, temporary: URL,
                                               exportDirectories: [URL] = [], before cutoff: Date = processStart,
                                               afterOpening: ((URL) -> Void)? = nil) -> [URL] {
        var removed: [URL] = []
        for directory in children(registry) where ownedUUID(directory.lastPathComponent, prefix: ".voxclip-export-") {
            guard let journal = readLease(directory), !journal.recovery,
                  let abandoned = try? isAbandoned(journal.owner), abandoned else { continue }
            defer { _ = removeDirectory(journal) }
            guard let lease = readReference(journal), valid(lease), lease.owner == journal.owner,
                  !lease.recovery else { continue }
            if removeDirectory(lease, afterOpening: afterOpening) { removed.append(lease.directory) }
        }
        for parent in exportDirectories {
            for directory in children(parent) where ownedUUID(directory.lastPathComponent, prefix: ".voxclip-export-") {
                guard let lease = readLease(directory), !lease.recovery,
                      let abandoned = try? isAbandoned(lease.owner), abandoned else { continue }
                if removeDirectory(lease, afterOpening: afterOpening) { removed.append(directory) }
            }
        }
        return removed
    }

    private static func valid(_ lease: Lease) -> Bool {
        lease.schema == "voxclip-export-scratch/4" && lease.directory.isFileURL
            && ownedUUID(lease.directory.lastPathComponent, prefix: ".voxclip-export-")
            && lease.directory.standardizedFileURL.path == lease.directory.path
    }

    private static func readLease(_ directory: URL) -> Lease? {
        guard ownedUUID(directory.lastPathComponent, prefix: ".voxclip-export-"),
              let descriptor = try? openDirectory(directory) else { return nil }
        defer { close(descriptor) }
        guard privateDirectory(descriptor) else { return nil }
        guard let data = readMetadata(descriptor, name: leaseName),
              let lease = try? JSONDecoder().decode(Lease.self, from: data), valid(lease),
              lease.directory.standardizedFileURL == directory.standardizedFileURL,
              matches(descriptor, lease.identity) else { return nil }
        return lease
    }

    private static func readReference(_ journal: Lease) -> Lease? {
        guard let descriptor = try? openDirectory(journal.directory) else { return nil }
        defer { close(descriptor) }
        guard privateDirectory(descriptor), matches(descriptor, journal.identity),
              let data = readMetadata(descriptor, name: "reference.json") else { return nil }
        return try? JSONDecoder().decode(Lease.self, from: data)
    }

    private static func readMetadata(_ descriptor: Int32, name: String) -> Data? {
        let leaseDescriptor = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard leaseDescriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: leaseDescriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(leaseDescriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size <= 65536 else { return nil }
        return try? file.readToEnd()
    }

    private static func writeLease(_ data: Data, descriptor: Int32, name: String = leaseName) throws {
        let fileDescriptor = openat(descriptor, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: data)
        try file.synchronize()
    }

    private static func removeDirectory(_ lease: Lease, afterOpening: ((URL) -> Void)? = nil) -> Bool {
        guard valid(lease), let parent = try? openDirectory(lease.directory.deletingLastPathComponent()) else { return false }
        defer { close(parent) }
        let name = lease.directory.lastPathComponent
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT }
        defer { close(descriptor) }
        guard privateDirectory(descriptor), matches(descriptor, lease.identity) else { return false }
        afterOpening?(lease.directory)
        guard safeContents(descriptor, device: lease.identity.device), removeContents(descriptor, device: lease.identity.device) else { return false }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFDIR, identity(current) == lease.identity else { return false }
        return unlinkat(parent, name, AT_REMOVEDIR) == 0
    }

    private static func safeContents(_ descriptor: Int32, device: Int32) -> Bool {
        guard let names = entries(descriptor) else { return false }
        for name in names {
            var attributes = stat()
            guard fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0, attributes.st_dev == device else { return false }
            if attributes.st_mode & S_IFMT == S_IFREG { continue }
            guard attributes.st_mode & S_IFMT == S_IFDIR else { return false }
            let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return false }
            let safe = matches(child, identity(attributes)) && safeContents(child, device: device)
            close(child)
            if !safe { return false }
        }
        return true
    }

    private static func removeContents(_ descriptor: Int32, device: Int32) -> Bool {
        guard let names = entries(descriptor) else { return false }
        for name in names {
            var attributes = stat()
            guard fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0, attributes.st_dev == device else { return false }
            if attributes.st_mode & S_IFMT == S_IFREG {
                if unlinkat(descriptor, name, 0) != 0 { return false }
            } else if attributes.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                let removed = matches(child, identity(attributes)) && removeContents(child, device: device)
                close(child)
                guard removed, unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { return false }
            } else { return false }
        }
        return true
    }

    private static func entries(_ descriptor: Int32) -> [String]? {
        let copy = dup(descriptor)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let nameLength = Int(entry.pointee.d_namlen)
            let capacity = nameLength + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return errno == 0 ? names : nil
    }

    private static func privateDirectory(_ descriptor: Int32) -> Bool {
        var attributes = stat()
        return fstat(descriptor, &attributes) == 0 && attributes.st_mode & S_IFMT == S_IFDIR
            && attributes.st_uid == geteuid() && attributes.st_mode & 0o777 == 0o700
    }
    private static func matches(_ descriptor: Int32, _ expected: Identity) -> Bool {
        var attributes = stat()
        return fstat(descriptor, &attributes) == 0 && identity(attributes) == expected
    }
    private static func identity(_ attributes: stat) -> Identity {
        Identity(device: attributes.st_dev, inode: attributes.st_ino,
                 birthSeconds: Int64(attributes.st_birthtimespec.tv_sec), birthNanoseconds: Int64(attributes.st_birthtimespec.tv_nsec))
    }
    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }
    private static func isAbandoned(_ owner: ProcessOwner) throws -> Bool { try processOwner(of: owner.pid) != owner }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func ownedUUID(_ name: String, prefix: String = "", suffix: String = "") -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count == prefix.count + 36 + suffix.count else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }
    private static func children(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
