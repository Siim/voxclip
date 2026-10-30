import Foundation
import Darwin

public enum ScratchCleanup {
    public struct ProcessOwner: Codable, Equatable, Sendable {
        var pid: Int32
        var startSeconds: Int64
        var startMicroseconds: Int64
    }
    private struct Identity: Codable, Equatable {
        var device: Int32
        var inode: UInt64
        var birthSeconds: Int64
        var birthNanoseconds: Int64
    }
    private struct Item: Codable {
        var name: String
        var identity: Identity
    }
    private struct ExportRecord: Codable {
        var schema = "voxclip-export-scratch/3"
        var owner: ProcessOwner
        var directory: URL
        var work: Item
        var partials: [Item]
    }

    public static let processStart: Date = {
        guard let owner = try? processOwner(of: getpid()) else { return .distantPast }
        let seconds = Double(owner.startSeconds)
        let fraction = Double(owner.startMicroseconds) / 1_000_000.0
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

    public static func registerExport(workDirectory: URL, partials: [URL], registry: URL, owner: ProcessOwner? = nil) throws -> URL {
        let manager = FileManager.default
        let directory = workDirectory.deletingLastPathComponent().standardizedFileURL
        guard ownedUUID(workDirectory.lastPathComponent, prefix: "voxclip-export-", suffix: ".partial"),
              partials.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory && validPartialName($0.lastPathComponent) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if manager.fileExists(atPath: registry.path), !isDirectory(registry) { throw CocoaError(.fileWriteNoPermission) }
        try manager.createDirectory(at: registry, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let owner = try owner ?? processOwner(of: getpid()) else { throw CocoaError(.fileWriteUnknown) }
        let record = ExportRecord(owner: owner, directory: directory, work: try item(workDirectory, type: S_IFDIR),
                                  partials: try partials.map { try item($0, type: S_IFREG) })
        let file = registry.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public static func recordExportPartial(_ partial: URL, record file: URL) throws {
        var record = try JSONDecoder().decode(ExportRecord.self, from: Data(contentsOf: file))
        guard partial.deletingLastPathComponent().standardizedFileURL == record.directory,
              validPartialName(partial.lastPathComponent) else { throw CocoaError(.fileWriteInvalidFileName) }
        let owned = try item(partial, type: S_IFREG)
        record.partials.removeAll { $0.name == owned.name }
        record.partials.append(owned)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }

    public static func finishExport(_ record: URL) { try? FileManager.default.removeItem(at: record) }

    @discardableResult public static func sweep(registry: URL, cache: URL, temporary: URL,
                                               exportDirectories: [URL] = [], before cutoff: Date = processStart) -> [URL] {
        var removed: [URL] = []
        for file in children(registry) where ownedUUID(file.lastPathComponent, suffix: ".json") && identity(file, type: S_IFREG) != nil {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 65536,
                  let data = try? Data(contentsOf: file) else { continue }
            guard let record = try? JSONDecoder().decode(ExportRecord.self, from: data), record.schema == "voxclip-export-scratch/3" else {
                finishExport(file)
                continue
            }
            guard let abandoned = try? isAbandoned(record.owner), abandoned else { continue }
            defer { finishExport(file) }
            guard record.directory.isFileURL, isDirectory(record.directory),
                  record.directory.standardizedFileURL.path == record.directory.path,
                  record.directory.resolvingSymlinksInPath().path == record.directory.path,
                  ownedUUID(record.work.name, prefix: "voxclip-export-", suffix: ".partial"),
                  record.partials.allSatisfy({ validPartialName($0.name) }) else { continue }
            for partial in record.partials {
                let path = record.directory.appendingPathComponent(partial.name)
                if identity(path, type: S_IFREG) == partial.identity { remove(path, into: &removed) }
            }
            let work = record.directory.appendingPathComponent(record.work.name)
            if identity(work, type: S_IFDIR) == record.work.identity && safeContents(work) { remove(work, into: &removed) }
        }
        return removed
    }

    private static func validPartialName(_ name: String) -> Bool {
        name.hasSuffix(".partial") && name.count > ".partial".count && !name.contains("/") && !name.contains("\0") && name != ".."
    }
    private static func isAbandoned(_ owner: ProcessOwner) throws -> Bool {
        try processOwner(of: owner.pid) != owner
    }
    private static func item(_ url: URL, type: mode_t) throws -> Item {
        guard let identity = identity(url, type: type) else { throw CocoaError(.fileReadInvalidFileName) }
        return Item(name: url.lastPathComponent, identity: identity)
    }
    private static func identity(_ url: URL, type: mode_t) -> Identity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == type else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino,
                        birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
    private static func ownedUUID(_ name: String, prefix: String = "", suffix: String = "") -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count == prefix.count + 36 + suffix.count else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }
    private static func isDirectory(_ directory: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory
    }
    private static func children(_ directory: URL) -> [URL] {
        guard isDirectory(directory) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
    private static func safeContents(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        return contents.allSatisfy { child in
            if identity(child, type: S_IFREG) != nil { return true }
            return identity(child, type: S_IFDIR) != nil && safeContents(child)
        }
    }
    private static func remove(_ file: URL, into removed: inout [URL]) {
        do { try FileManager.default.removeItem(at: file); removed.append(file) } catch {}
    }
}
