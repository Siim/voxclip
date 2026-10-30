import Foundation
import Darwin

public enum ScratchCleanup {
    private struct ExportRecord: Codable {
        var schema = "voxclip-export-scratch/1"
        var directory: URL
        var workName: String
        var partialNames: [String]
    }

    public static let processStart: Date = {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return .distantPast }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }()

    public static func registerExport(workDirectory: URL, partials: [URL], registry: URL) throws -> URL {
        let manager = FileManager.default
        let directory = workDirectory.deletingLastPathComponent().standardizedFileURL
        guard ownedUUID(workDirectory.lastPathComponent, prefix: "voxclip-export-", suffix: ".partial"),
              partials.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory && validPartialName($0.lastPathComponent) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if manager.fileExists(atPath: registry.path), !isDirectory(registry) { throw CocoaError(.fileWriteNoPermission) }
        try manager.createDirectory(at: registry, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record = ExportRecord(directory: directory, workName: workDirectory.lastPathComponent, partialNames: partials.map(\.lastPathComponent))
        let file = registry.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public static func finishExport(_ record: URL) { try? FileManager.default.removeItem(at: record) }

    @discardableResult public static func sweep(registry: URL, cache: URL, temporary: URL,
                                               exportDirectories: [URL] = [], before cutoff: Date = processStart) -> [URL] {
        var removed: [URL] = []
        for file in children(registry) where ownedUUID(file.lastPathComponent, suffix: ".json") && old(file, type: .typeRegular, before: cutoff) {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 65536,
                  let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(ExportRecord.self, from: data),
                  record.schema == "voxclip-export-scratch/1", record.directory.isFileURL,
                  isDirectory(record.directory), ownedUUID(record.workName, prefix: "voxclip-export-", suffix: ".partial"),
                  record.partialNames.allSatisfy(validPartialName) else { continue }
            for name in record.partialNames { remove(record.directory.appendingPathComponent(name), type: .typeRegular, before: cutoff, into: &removed) }
            let work = record.directory.appendingPathComponent(record.workName)
            remove(work, type: .typeDirectory, before: cutoff, into: &removed)
            if !FileManager.default.fileExists(atPath: work.path), record.partialNames.allSatisfy({ !FileManager.default.fileExists(atPath: record.directory.appendingPathComponent($0).path) }) {
                remove(file, type: .typeRegular, before: cutoff, into: &removed)
            }
        }
        for entry in children(cache) where entry.lastPathComponent.count == 64 && entry.lastPathComponent.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            for file in children(entry) where ownedUUID(file.lastPathComponent, prefix: "scribe-", suffix: ".multipart") {
                remove(file, type: .typeRegular, before: cutoff, into: &removed)
            }
        }
        let appTemporary = temporary.appendingPathComponent("VoxClip", isDirectory: true)
        if isDirectory(appTemporary) {
            for directory in children(appTemporary.appendingPathComponent("cli", isDirectory: true)) where UUID(uuidString: directory.lastPathComponent) != nil {
                remove(directory, type: .typeDirectory, before: cutoff, into: &removed)
            }
        }
        for directory in exportDirectories {
            for work in children(directory) where ownedUUID(work.lastPathComponent, prefix: "voxclip-export-", suffix: ".partial") {
                remove(work, type: .typeDirectory, before: cutoff, into: &removed)
            }
        }
        return removed
    }

    private static func validPartialName(_ name: String) -> Bool {
        name.hasSuffix(".partial") && name.count > ".partial".count && !name.contains("/") && !name.contains("\0")
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
    private static func old(_ file: URL, type: FileAttributeType, before cutoff: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == type,
              let created = attributes[.creationDate] as? Date, let modified = attributes[.modificationDate] as? Date else { return false }
        guard created < cutoff && modified < cutoff else { return false }
        if type == .typeDirectory {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil) else { return false }
            return contents.allSatisfy { child in
                guard let childType = (try? FileManager.default.attributesOfItem(atPath: child.path)[.type]) as? FileAttributeType else { return false }
                return old(child, type: childType, before: cutoff)
            }
        }
        return true
    }
    private static func remove(_ file: URL, type: FileAttributeType, before cutoff: Date, into removed: inout [URL]) {
        guard old(file, type: type, before: cutoff) else { return }
        do { try FileManager.default.removeItem(at: file); removed.append(file) } catch {}
    }
}
