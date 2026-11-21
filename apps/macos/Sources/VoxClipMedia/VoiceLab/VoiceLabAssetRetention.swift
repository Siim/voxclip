import Darwin
import Foundation
import VoxClipCore

public enum VoiceLabAssetRetention {
    public struct Observation: Sendable {
        public let session: String
        public let monotonicSeconds: Double
        public init(session: String, monotonicSeconds: Double) {
            self.session = session; self.monotonicSeconds = monotonicSeconds
        }
        private static let session = UUID().uuidString
        public static func now() -> Observation { Observation(session: session, monotonicSeconds: ProcessInfo.processInfo.systemUptime) }
    }
    public static func discoverUnlisted(paidRoot: URL, now: Date = Date()) throws {
        let root = try VoiceLabPaidRoot.open(paidRoot)
        defer { close(root) }
        let projects = try VoiceLabAssetRecovery.names(root)
        for project in projects where (try? VoiceLabAssetNaming.file(projectId: project, assetId: "probe", extension: "wav")) != nil {
            try closeProject(projectId: project, paidRoot: paidRoot, references: [], now: now, allowDeletion: false, preserveUnlisted: true)
        }
    }
    private struct Entry: Codable {
        var discovered: Date
        var lastObservedAt: Date
        var observation: String
        var monotonicSeconds: Double
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let birthSeconds: Int
        let birthNanos: Int
        func matches(_ info: stat) -> Bool {
            device == info.st_dev && inode == info.st_ino && size == info.st_size &&
                modifiedSeconds == info.st_mtimespec.tv_sec && modifiedNanos == info.st_mtimespec.tv_nsec &&
                birthSeconds == info.st_birthtimespec.tv_sec && birthNanos == info.st_birthtimespec.tv_nsec
        }
    }
    private struct Ledger: Codable {
        var protected: Set<String> = []
        var unreferenced: [String: Entry] = [:]
    }
    public static func references(in project: Project) -> Set<String> {
        Set((project.voiceLab.assets ?? []).map(\.file) + (project.voiceLab.videoAssets ?? []).map(\.file))
    }
    /// The imported lip-sync results the attempt index points at (`LipsyncAttempt.importedAsset`, voice-lab §9.4), which
    /// would otherwise be paid for again: paid work no project uses yet, so never a deletion candidate.
    private static func importedLipsyncAssets(project directory: Int32, projectId: String) -> Set<String> {
        let attempts = openat(directory, "lipsync-attempts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard attempts >= 0 else { return [] }
        defer { close(attempts) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var files = Set<String>()
        for name in (try? VoiceLabAssetRecovery.names(attempts)) ?? [] where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let descriptor = openat(attempts, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), (1...65_536).contains(info.st_size),
                  let data = try? readData(descriptor, count: Int(info.st_size)) else { close(descriptor); continue }
            close(descriptor)
            guard let asset = (try? decoder.decode(LipsyncAttempt.self, from: data))?.importedAsset,
                  (try? VoiceLabAssetNaming.videoFile(projectId: projectId, assetId: asset.id)) == asset.file else { continue }
            files.insert(asset.file)
        }
        return files
    }
    /// Drops the take journal's entries that are done: the project as it closes uses the asset (`inUse`: after Use, and not
    /// undone), the asset is gone, or, when deletion is allowed, the entry is older than `VoiceLabTakeJournal.unusedLifetime`,
    /// after which its asset follows the ordinary rules. Returns the asset files of the entries that stay (voice-lab §3 "Paid
    /// takes are kept"): paid takes no project uses yet, so never deletion candidates. A take Use put in and Undo took out
    /// again is only in the session's history, so its entry stays and a later Rewrite adopts it for its word check.
    private static func settleTakeJournal(project directory: Int32, projectId: String, inUse: Set<String>, present: Set<String>,
                                          now: Date, allowDeletion: Bool) -> Set<String> {
        let entries = VoiceLabTakeJournal.entries(inProject: directory, projectID: projectId)
        let done = entries.filter { entry in
            inUse.contains(entry.assetFile) || !present.contains(entry.assetFile)
                || (allowDeletion && now.timeIntervalSince(entry.createdAt) >= VoiceLabTakeJournal.unusedLifetime)
        }
        VoiceLabTakeJournal.remove(done.map(\.assetID), inProject: directory)
        return Set(entries.map(\.assetFile)).subtracting(done.map(\.assetFile))
    }
    /// `references` are the files the project used at any point of its session (its undo history), which are never deletion
    /// candidates; `inUse`, the files the project as it closes uses, which alone end a take's journal entry (nil: all of
    /// `references`).
    @discardableResult
    public static func closeProject(projectId: String, paidRoot: URL, references: Set<String>, inUse: Set<String>? = nil,
                                    now: Date = Date(), allowDeletion: Bool = true,
                                    preserveUnlisted: Bool = false, observation: Observation = .now(),
                                    recheckReferences: (() throws -> Set<String>)? = nil) throws -> [String] {
        guard now.timeIntervalSince1970.isFinite,
              observation.monotonicSeconds.isFinite, observation.monotonicSeconds >= 0,
              (try? VoiceLabAssetNaming.file(projectId: projectId, assetId: "probe", extension: "wav")) != nil else { throw VoiceLabError.invalidInput }
        let root = try VoiceLabPaidRoot.open(paidRoot)
        defer { close(root) }
        let lock = try VoiceLabAssetRecovery.lock(root)
        defer { close(lock) }
        let exclusive = allowDeletion ? try VoiceLabAssetActivity.exclusive(root) : nil
        defer { if let exclusive { close(exclusive) } }
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
        let names = try VoiceLabAssetRecovery.names(directory)
        // Only what this project uses now ends an entry: `protected` also holds every file kept at a launch, and
        // `references` every file of the session's undo history.
        // The paid work no project uses yet, read once: deletion needs the exclusive activity lock, which no open project
        // (so no take run or lip-sync import) holds beside it, and only new files can gain such a reference meanwhile.
        let paid = settleTakeJournal(project: directory, projectId: projectId, inUse: inUse ?? references,
                                     present: Set(names.map { "\(projectId)/\($0)" }), now: now, allowDeletion: allowDeletion)
            .union(importedLipsyncAssets(project: directory, projectId: projectId))
        let backward = ledger.unreferenced.values.contains { now < $0.discovered || now < $0.lastObservedAt }
        var eligible: [String] = []
        for name in names {
            let url = URL(fileURLWithPath: name)
            let ext = url.pathExtension, id = url.deletingPathExtension().lastPathComponent
            guard ["wav", "flac", "mp4"].contains(ext),
                  (try? VoiceLabAssetNaming.file(projectId: projectId, assetId: id, extension: "wav")) != nil else { continue }
            let relative = "\(projectId)/\(name)"
            if preserveUnlisted { ledger.protected.insert(relative) }
            if ledger.protected.contains(relative) || paid.contains(relative) { ledger.unreferenced.removeValue(forKey: name); continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            guard VoiceLabAssetRecovery.ownsComplete(directory, name: name, info: info) else {
                ledger.protected.insert(relative); ledger.unreferenced.removeValue(forKey: name); continue
            }
            if var entry = ledger.unreferenced[name], entry.matches(info) {
                let elapsed = observation.monotonicSeconds - entry.monotonicSeconds
                let jumped = now.timeIntervalSince(entry.lastObservedAt) - elapsed > 24 * 60 * 60
                if backward || entry.observation != observation.session || elapsed < 0 || jumped { entry.discovered = now }
                entry.lastObservedAt = now; entry.observation = observation.session; entry.monotonicSeconds = observation.monotonicSeconds
                ledger.unreferenced[name] = entry
                if exclusive != nil && now.timeIntervalSince(entry.discovered) >= 7 * 24 * 60 * 60 { eligible.append(name) }
            } else {
                ledger.unreferenced[name] = Entry(discovered: now, lastObservedAt: now,
                    observation: observation.session, monotonicSeconds: observation.monotonicSeconds, device: info.st_dev, inode: info.st_ino,
                    size: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                    birthSeconds: info.st_birthtimespec.tv_sec, birthNanos: info.st_birthtimespec.tv_nsec)
            }
        }
        try persist(ledger, name: ledgerName, directory: directory)
        var removed: [String] = []
        for name in eligible {
            ledger.protected.formUnion(try recheckReferences?() ?? references)
            var info = stat()
            guard let entry = ledger.unreferenced[name], !ledger.protected.contains("\(projectId)/\(name)"),
                  !paid.contains("\(projectId)/\(name)"),
                  fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, entry.matches(info),
                  VoiceLabAssetRecovery.ownsComplete(directory, name: name, info: info) else { continue }
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
        let operation = try VoiceLabAssetRecovery.Operation(parent: directory)
        defer { operation.discard() }
        let temporary = ".asset-retention.\(UUID().uuidString.lowercased()).partial"
        let descriptor = openat(operation.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
        defer { close(descriptor) }
        _ = try VoiceLabAssetRecovery.recordPartial(operation.descriptor, name: temporary, descriptor: descriptor)
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
        guard VoiceLabPaidRoot.fullSync(descriptor), renameat(operation.descriptor, temporary, directory, name) == 0,
              VoiceLabPaidRoot.fullSync(directory) else { throw VoiceLabAssetStoreError.unwritable(name) }
    }
}
