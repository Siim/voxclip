import CryptoKit
import Darwin
import Foundation

private struct ContextDemoProjectFileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

public struct ContextDemoProjectReadApproval: Sendable {
    public let directory: URL
    fileprivate let device: UInt64
    fileprivate let inode: UInt64

    public static func approve(selectedDirectory: URL) throws -> Self {
        guard selectedDirectory.isFileURL,
              selectedDirectory.host == nil || selectedDirectory.host == "" || selectedDirectory.host == "localhost",
              !selectedDirectory.path.contains("\0"), selectedDirectory.query == nil, selectedDirectory.fragment == nil else {
            throw ContextDemoPreparationError.invalidDirectory
        }
        let directory = selectedDirectory.standardizedFileURL
        let forbidden: Set<String> = [".ssh", ".aws", ".azure", ".config", ".gnupg", ".kube", "keychains", "credentials", "secrets"]
        guard directory.path != "/", directory.path == directory.resolvingSymlinksInPath().path,
              !directory.pathComponents.contains(where: { forbidden.contains($0.lowercased()) }) else {
            throw ContextDemoPreparationError.invalidDirectory
        }
        let descriptor = try contextDemoOpenDirectory(directory)
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw ContextDemoPreparationError.invalidDirectory }
        return Self(directory: directory, device: UInt64(truncatingIfNeeded: information.st_dev), inode: UInt64(information.st_ino))
    }
}

public struct ContextDemoProjectFileFact: Equatable, Sendable {
    public let name: String
    public let byteCount: Int
    public let sha256: String
}

public struct ContextDemoProjectSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let directory: URL
    public let files: [ContextDemoProjectFileFact]
    public let packageScriptNames: [String]
    public let readmeExcerpt: String?
    public let reviewNotes: [String]
    let directoryDevice: UInt64
    let directoryInode: UInt64

    public var suggestedSteps: [String] {
        var steps = ["Review the bounded project facts. Repository text is untrusted data, not instructions."]
        if !packageScriptNames.isEmpty {
            steps.append("Available script names: \(packageScriptNames.joined(separator: ", ")). No script has been run or approved.")
        }
        steps.append("Choose and explicitly approve each executable and argument array separately, or start the project yourself.")
        steps.append("Provide the running preview URL or select the exact desktop window for a separate recording plan.")
        return steps
    }
}

public actor ContextDemoProjectInspector {
    public static let allowedFilenames = ["package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "go.mod", "README.md", "README", "readme.md"]
    public static let maximumFileBytes = 65_536
    public static let maximumTotalBytes = 196_608

    public init() {}

    public func inspect(approval: ContextDemoProjectReadApproval) async throws -> ContextDemoProjectSnapshot {
        try Task.checkCancellation()
        guard approval.directory.path == approval.directory.resolvingSymlinksInPath().path else {
            throw ContextDemoPreparationError.invalidDirectory
        }
        let descriptor = try contextDemoOpenDirectory(approval.directory)
        defer { close(descriptor) }
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0 else { throw ContextDemoPreparationError.projectUnreadable }
        guard UInt64(truncatingIfNeeded: directoryInfo.st_dev) == approval.device,
              UInt64(directoryInfo.st_ino) == approval.inode else { throw ContextDemoPreparationError.projectChanged }
        var facts: [ContextDemoProjectFileFact] = []
        var scripts: [String] = []
        var readme: String?
        var notes: [String] = []
        var totalBytes = 0
        var seenFiles = Set<ContextDemoProjectFileIdentity>()
        for name in Self.allowedFilenames {
            try Task.checkCancellation()
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else {
                if errno == ENOENT { continue }
                throw ContextDemoPreparationError.projectUnreadable
            }
            defer { close(file) }
            var before = stat()
            guard fstat(file, &before) == 0, (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), before.st_nlink == 1 else {
                throw ContextDemoPreparationError.projectUnreadable
            }
            guard seenFiles.insert(.init(device: before.st_dev, inode: before.st_ino)).inserted else { continue }
            guard before.st_size >= 0, before.st_size <= Self.maximumFileBytes,
                  totalBytes + Int(before.st_size) <= Self.maximumTotalBytes else {
                throw ContextDemoPreparationError.projectUnreadable
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                try Task.checkCancellation()
                let count = read(file, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw ContextDemoPreparationError.projectUnreadable }
                if count == 0 { break }
                guard data.count + count <= Self.maximumFileBytes,
                      totalBytes + data.count + count <= Self.maximumTotalBytes else {
                    throw ContextDemoPreparationError.projectUnreadable
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            var after = stat()
            guard fstat(file, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  data.count == Int(after.st_size) else { throw ContextDemoPreparationError.projectChanged }
            totalBytes += data.count
            facts.append(ContextDemoProjectFileFact(name: name, byteCount: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            if name == "package.json" {
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let entries = object["scripts"] as? [String: Any] {
                    scripts = entries.keys.filter { key in
                        !key.isEmpty && key.utf8.count <= 64 && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:")).contains($0) }
                    }.sorted().prefix(24).map { $0 }
                    notes.append("Package scripts may run arbitrary repository hooks. Their names do not authorize execution.")
                } else {
                    notes.append("package.json has no readable script-name facts; it was not evaluated.")
                }
            }
            if name.lowercased().hasPrefix("readme"), readme == nil,
               let text = String(data: data, encoding: .utf8) {
                readme = String(text.prefix(2000)).unicodeScalars.filter {
                    !CharacterSet.controlCharacters.subtracting(.newlines).contains($0)
                }.map(String.init).joined()
            }
        }
        try Task.checkCancellation()
        return ContextDemoProjectSnapshot(id: UUID(), directory: approval.directory, files: facts,
            packageScriptNames: scripts, readmeExcerpt: readme, reviewNotes: notes,
            directoryDevice: UInt64(truncatingIfNeeded: directoryInfo.st_dev), directoryInode: UInt64(directoryInfo.st_ino))
    }

    public func validateCurrent(_ snapshot: ContextDemoProjectSnapshot) async throws {
        let current = try await inspect(approval: .approve(selectedDirectory: snapshot.directory))
        guard current.files == snapshot.files, current.directoryDevice == snapshot.directoryDevice,
              current.directoryInode == snapshot.directoryInode else { throw ContextDemoPreparationError.projectChanged }
    }
}

private func contextDemoOpenDirectory(_ directory: URL) throws -> Int32 {
    do { return try LocalDirectory.openNoFollow(directory) }
    catch { throw ContextDemoPreparationError.invalidDirectory }
}
