import CryptoKit
import Darwin
import Foundation
import VoxClipCore

struct ContextDemoCaptureFile: Sendable {
    let id: UUID
    let projectId: String
    let directory: URL
    let device: dev_t
    let inode: ino_t
    var assetID: String { id.uuidString.lowercased() }
    var partialURL: URL { directory.appendingPathComponent("recording.partial.mp4") }
    var finalURL: URL { directory.deletingLastPathComponent().appendingPathComponent("\(assetID).mp4") }
    var relativePath: String { "context-demo/\(projectId)/\(assetID).mp4" }
}

struct ContextDemoFileDigest: Sendable, Equatable {
    let byteCount: Int
    let sha256: String
}

public struct ContextDemoAssetStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxClip", isDirectory: true)
    }

    func create(projectId: String) throws -> ContextDemoCaptureFile {
        guard rootURL.isFileURL, rootURL.path == rootURL.standardizedFileURL.path else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        let id = UUID()
        let relativePath = try ContextDemoAsset.relativePath(projectId: projectId, assetId: id.uuidString.lowercased())
        let projectDirectory = rootURL.appendingPathComponent(relativePath).deletingLastPathComponent()
        try Self.prepareDirectory(projectDirectory)
        var information = stat()
        guard lstat(projectDirectory.path, &information) == 0, information.st_uid == getuid(),
              information.st_mode & 0o077 == 0 else { throw ContextDemoCaptureError.unsafeStorage }
        let directory = projectDirectory.appendingPathComponent(".capture-\(id.uuidString)", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        guard lstat(directory.path, &information) == 0 else { throw ContextDemoCaptureError.unsafeStorage }
        return ContextDemoCaptureFile(id: id, projectId: projectId, directory: directory,
                                      device: information.st_dev, inode: information.st_ino)
    }

    private static func prepareDirectory(_ url: URL) throws {
        if url.path == "/" { return }
        var information = stat()
        if lstat(LocalDirectory.nativePath(url), &information) == 0 {
            guard information.st_mode & S_IFMT == S_IFDIR else { throw ContextDemoCaptureError.unsafeStorage }
            try validateAncestors(url.deletingLastPathComponent())
            return
        }
        guard errno == ENOENT else { throw ContextDemoCaptureError.unsafeStorage }
        try prepareDirectory(url.deletingLastPathComponent())
        guard mkdir(url.path, 0o700) == 0 else { throw ContextDemoCaptureError.unsafeStorage }
    }

    private static func validateAncestors(_ url: URL) throws {
        if url.path == "/" { return }
        var information = stat()
        guard lstat(LocalDirectory.nativePath(url), &information) == 0, information.st_mode & S_IFMT == S_IFDIR else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        try validateAncestors(url.deletingLastPathComponent())
    }

    private func validate(_ file: ContextDemoCaptureFile) throws {
        let relativePath = try ContextDemoAsset.relativePath(projectId: file.projectId, assetId: file.assetID)
        guard file.finalURL == rootURL.appendingPathComponent(relativePath),
              file.directory.lastPathComponent == ".capture-\(file.id.uuidString)" else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        try Self.validateAncestors(file.directory.deletingLastPathComponent())
        var information = stat()
        guard lstat(file.directory.deletingLastPathComponent().path, &information) == 0,
              information.st_uid == getuid(), information.st_mode & 0o077 == 0 else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        if lstat(file.directory.path, &information) < 0, errno == ENOENT { return }
        guard lstat(file.directory.path, &information) == 0,
              information.st_uid == getuid(), information.st_mode & 0o077 == 0,
              information.st_dev == file.device, information.st_ino == file.inode else {
            throw ContextDemoCaptureError.unsafeStorage
        }
    }

    func bytes(_ file: ContextDemoCaptureFile) throws -> Int {
        try validate(file)
        let descriptor = open(file.partialURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return 0 }
        guard descriptor >= 0 else { throw ContextDemoCaptureError.unsafeStorage }
        defer { close(descriptor) }
        let information = try Self.inspect(descriptor)
        guard fchmod(descriptor, 0o600) == 0 else { throw ContextDemoCaptureError.unsafeStorage }
        return Int(information.st_size)
    }

    func publish(_ file: ContextDemoCaptureFile) throws -> ContextDemoFileDigest {
        try validate(file)
        let digest = try Self.digest(file.partialURL)
        guard renamex_np(file.partialURL.path, file.finalURL.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        do {
            guard try Self.digest(file.finalURL) == digest else { throw ContextDemoCaptureError.invalidRecording }
        } catch {
            try? remove(file, published: true)
            throw error
        }
        return digest
    }

    func verify(relativePath: String, expected: ContextDemoFileDigest, checkingCancellation: Bool = true) throws -> URL {
        let file = try resolve(relativePath)
        try validate(file)
        guard try Self.digest(file.finalURL, checkingCancellation: checkingCancellation) == expected else { throw ContextDemoCaptureError.invalidRecording }
        return file.finalURL
    }

    func remove(relativePath: String) throws {
        try remove(resolve(relativePath), published: true)
    }

    private func resolve(_ relativePath: String) throws -> ContextDemoCaptureFile {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "context-demo", parts[2].hasSuffix(".mp4"),
              let id = UUID(uuidString: String(parts[2].dropLast(4))),
              try ContextDemoAsset.relativePath(projectId: String(parts[1]), assetId: id.uuidString.lowercased()) == relativePath else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        let directory = rootURL.appendingPathComponent(relativePath).deletingLastPathComponent()
            .appendingPathComponent(".capture-\(id.uuidString)", isDirectory: true)
        var information = stat()
        if lstat(directory.path, &information) < 0, errno != ENOENT { throw ContextDemoCaptureError.unsafeStorage }
        return ContextDemoCaptureFile(id: id, projectId: String(parts[1]), directory: directory,
                                      device: information.st_dev, inode: information.st_ino)
    }

    func remove(_ file: ContextDemoCaptureFile, published: Bool = false) throws {
        try validate(file)
        let descriptor = open(file.directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ContextDemoCaptureError.unsafeStorage }
        defer { close(descriptor) }
        let partialDirectory = openat(descriptor, file.directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if partialDirectory >= 0 {
            defer { close(partialDirectory) }
            guard unlinkat(partialDirectory, "recording.partial.mp4", 0) == 0 || errno == ENOENT else {
                throw ContextDemoCaptureError.unsafeStorage
            }
            guard unlinkat(descriptor, file.directory.lastPathComponent, AT_REMOVEDIR) == 0 else {
                throw ContextDemoCaptureError.unsafeStorage
            }
        } else if errno != ENOENT { throw ContextDemoCaptureError.unsafeStorage }
        for name in published ? [file.finalURL.lastPathComponent] : [] {
            guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else {
                throw ContextDemoCaptureError.unsafeStorage
            }
        }
    }

    func complete(_ file: ContextDemoCaptureFile) throws {
        try validate(file)
        guard rmdir(file.directory.path) == 0 else { throw ContextDemoCaptureError.unsafeStorage }
    }

    private static func inspect(_ descriptor: Int32) throws -> stat {
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1, information.st_uid == getuid(), information.st_size >= 0 else {
            throw ContextDemoCaptureError.unsafeStorage
        }
        guard information.st_size <= ContextDemoCaptureLimits.maximumBytes else {
            throw ContextDemoCaptureError.fileBudgetExceeded
        }
        return information
    }

    private static func digest(_ url: URL, checkingCancellation: Bool = true) throws -> ContextDemoFileDigest {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ContextDemoCaptureError.unsafeStorage }
        defer { close(descriptor) }
        let permissions = try inspect(descriptor).st_mode & 0o777
        if permissions != 0o600 {
            guard fchmod(descriptor, 0o600) == 0 else { throw ContextDemoCaptureError.unsafeStorage }
        }
        let before = try inspect(descriptor)
        guard before.st_size > 0 else { throw ContextDemoCaptureError.invalidRecording }
        var signature = [UInt8](repeating: 0, count: 12)
        guard Darwin.pread(descriptor, &signature, signature.count, 0) == signature.count,
              signature[4..<8].elementsEqual(Array("ftyp".utf8)) else {
            throw ContextDemoCaptureError.invalidRecording
        }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var count = 0
        while true {
            if checkingCancellation { try Task.checkCancellation() }
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else { throw ContextDemoCaptureError.invalidRecording }
            if readCount == 0 { break }
            count += readCount
            guard count <= ContextDemoCaptureLimits.maximumBytes else { throw ContextDemoCaptureError.fileBudgetExceeded }
            digest.update(data: Data(buffer.prefix(readCount)))
        }
        let after = try inspect(descriptor)
        guard count == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ContextDemoCaptureError.invalidRecording
        }
        return ContextDemoFileDigest(byteCount: count, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
