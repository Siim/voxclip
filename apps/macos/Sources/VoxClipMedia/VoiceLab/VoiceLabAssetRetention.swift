import Darwin
import Foundation
import VoxClipCore

public enum VoiceLabAssetRetention {
    public static func discoverUnlisted(paidRoot: URL, now: Date = Date()) throws {
        let root = try VoiceLabPaidRoot.open(paidRoot)
        defer { close(root) }
        let projects = try VoiceLabAssetRecovery.names(root)
        for project in projects where (try? VoiceLabAssetNaming.file(projectId: project, assetId: "probe", extension: "wav")) != nil {
            try closeProject(projectId: project, paidRoot: paidRoot, references: [], now: now, allowDeletion: false)
        }
    }
    private struct Entry: Codable {
        let discovered: Date
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        func matches(_ info: stat) -> Bool {
            device == info.st_dev && inode == info.st_ino && size == info.st_size &&
                modifiedSeconds == info.st_mtimespec.tv_sec && modifiedNanos == info.st_mtimespec.tv_nsec
        }
    }
    private struct Ledger: Codable {
        var protected: Set<String> = []
        var unreferenced: [String: Entry] = [:]
    }
    public static func references(in project: Project) -> Set<String> {
        Set((project.voiceLab.assets ?? []).map(\.file) + (project.voiceLab.videoAssets ?? []).map(\.file))
    }
    @discardableResult
    public static func closeProject(projectId: String, paidRoot: URL, references: Set<String>,
                                    now: Date = Date(), allowDeletion: Bool = true) throws -> [String] {
        guard now.timeIntervalSince1970.isFinite,
              (try? VoiceLabAssetNaming.file(projectId: projectId, assetId: "probe", extension: "wav")) != nil else { throw VoiceLabError.invalidInput }
        let root = try VoiceLabPaidRoot.open(paidRoot)
        defer { close(root) }
        let lock = try VoiceLabAssetRecovery.lock(root)
        defer { close(lock) }
        let directory = openat(root, projectId, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT { return [] }
        guard directory >= 0 else { throw VoiceLabAssetStoreError.unsafePath(projectId) }
        defer { close(directory) }
        let ledgerName = ".asset-retention.json"
        var ledger = Ledger()
        let descriptor = openat(directory, ledgerName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_size <= 4 * 1_024 * 1_024 else { throw VoiceLabAssetStoreError.unsafePath(ledgerName) }
            let data = try readData(descriptor, count: Int(info.st_size))
            ledger = try JSONDecoder().decode(Ledger.self, from: data)
        } else if errno != ENOENT { throw VoiceLabAssetStoreError.unsafePath(ledgerName) }
        ledger.protected.formUnion(references)
        var eligible: [String] = []
        for name in try VoiceLabAssetRecovery.names(directory) {
            let url = URL(fileURLWithPath: name)
            let ext = url.pathExtension, id = url.deletingPathExtension().lastPathComponent
            guard ["wav", "flac", "mp4"].contains(ext),
                  (try? VoiceLabAssetNaming.file(projectId: projectId, assetId: id, extension: "wav")) != nil else { continue }
            let relative = "\(projectId)/\(name)"
            if ledger.protected.contains(relative) { ledger.unreferenced.removeValue(forKey: name); continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            if let entry = ledger.unreferenced[name], entry.matches(info), now >= entry.discovered {
                if allowDeletion && now.timeIntervalSince(entry.discovered) >= 7 * 24 * 60 * 60 { eligible.append(name) }
            } else {
                ledger.unreferenced[name] = Entry(discovered: now, device: info.st_dev, inode: info.st_ino,
                    size: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec)
            }
        }
        try persist(ledger, name: ledgerName, directory: directory)
        var removed: [String] = []
        for name in eligible {
            var info = stat()
            guard let entry = ledger.unreferenced[name], !ledger.protected.contains("\(projectId)/\(name)"),
                  fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, entry.matches(info) else { continue }
            guard unlinkat(directory, name, 0) == 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
            removed.append("\(projectId)/\(name)"); ledger.unreferenced.removeValue(forKey: name)
        }
        guard VoiceLabPaidRoot.fullSync(directory) else { throw VoiceLabAssetStoreError.unwritable(projectId) }
        try persist(ledger, name: ledgerName, directory: directory)
        return removed.sorted()
    }
    private static func readData(_ descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let read = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw VoiceLabAssetStoreError.unwritable("retention") }
                offset += read
            }
        }
        return data
    }
    private static func persist(_ ledger: Ledger, name: String, directory: Int32) throws {
        let temporary = ".asset-retention.\(UUID().uuidString.lowercased()).partial"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        let data = try JSONEncoder().encode(ledger)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
                offset += written
            }
        }
        guard VoiceLabPaidRoot.fullSync(descriptor), renameat(directory, temporary, directory, name) == 0,
              VoiceLabPaidRoot.fullSync(directory) else { throw VoiceLabAssetStoreError.unwritable(name) }
    }
}
