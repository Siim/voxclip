import CryptoKit
import Darwin
import Foundation
import VoxClipCore

/// Errors from the immutable paid-asset writer. No case overwrites, truncates or removes a published paid file.
///
/// `publishedUnverified` and `altered` both mean the file is at its final name and was kept. The caller must re-hash
/// that existing file, for example through `VoiceLabAssets.prepare`, rather than write it again: a second write with the
/// same asset ID is `alreadyExists`.
public enum VoiceLabAssetStoreError: Error, LocalizedError, Sendable, Equatable {
    case alreadyExists(String), unsafePath(String), invalidAudio(String), tooLarge(String)
    case unwritable(String), altered(String)
    /// Published, but syncing its directory or reading it back failed.
    case publishedUnverified(String)
    /// The paid root's parent, the data folder, does not exist; only the root's last component is ever created.
    case rootMissing(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists: "This generated Voice Lab audio is already saved. The paid file was not replaced."
        case .rootMissing: "The VoxClip data folder is missing, so the generated Voice Lab audio was not saved. Check the data location."
        case .unsafePath: "The Voice Lab storage folder is not a folder or contains a link. Check the storage location."
        case .invalidAudio: "The generated Voice Lab audio is empty or malformed, so it was not saved."
        case .tooLarge: "The generated Voice Lab audio exceeds this build's supported length, so it was not saved."
        case .unwritable: "The generated Voice Lab audio could not be saved. Check the free space and the storage folder's permissions."
        case .altered: "The saved Voice Lab audio did not read back as written. The file was kept; check the disk before using it."
        case .publishedUnverified: "The generated Voice Lab audio was saved but could not be confirmed; the file was kept."
        }
    }
}

/// Publishes paid audio into the caller's paid Voice Lab root exactly once (voice-lab.md §10.1, §10.4). Every asset is
/// a canonical mono PCM16 WAV named by `VoiceLabAssetNaming`. Unsafe IDs throw Core's `invalidAsset`.
///
/// The root resolves as `VoiceLabAssets.prepare` resolves it. When only its last component is missing, it is created with
/// mode 0700 inside the existing data folder; a missing data folder is `rootMissing`. `<projectId>` is created the same
/// way, and neither it nor the file is followed through a link. Anything already at the file's name is `alreadyExists`
/// before a byte is written. Each write goes to an exclusive 0600 temporary file in the same directory, is flushed with
/// `F_FULLFSYNC`, and moves into place with `RENAME_EXCL`, so an existing file is never overwritten or truncated; the
/// directory is then flushed the same way. Cancellation or failure before that move removes only the temporary file.
/// After it the file is kept: a failure to confirm it is `publishedUnverified`, and different bytes at the name are
/// `altered`.
public enum VoiceLabAssetStore {
    /// The RIFF size field is 32 bits and counts 36 header bytes plus 2 bytes per frame. That is tighter than §10.4's
    /// 8 GiB and 24 h × 192 kHz bounds, so `VoiceLabAssets.prepare` accepts every length written here.
    static let maxFrames = (Int(UInt32.max) - 36) / 2
    private static let block = 65_536

    /// Mono PCM16LE exactly as the provider returns it (`pcm_24000`).
    public static func write(pcm16: Data, sampleRate: Int, projectId: String, assetId: String,
                             paidRoot: URL, createdAt: Date) throws -> VoiceLabAsset {
        try write(pcm16: pcm16, sampleRate: sampleRate, projectId: projectId, assetId: assetId, paidRoot: paidRoot,
                  createdAt: createdAt, afterPublish: nil)
    }

    /// `afterPublish` runs once the file is at its final name, so tests can disturb the confirmation that follows.
    static func write(pcm16: Data, sampleRate: Int, projectId: String, assetId: String, paidRoot: URL, createdAt: Date,
                      afterPublish: (() -> Void)?) throws -> VoiceLabAsset {
        let file = try VoiceLabAssetNaming.file(projectId: projectId, assetId: assetId, extension: "wav")
        guard pcm16.count.isMultiple(of: 2) else { throw VoiceLabAssetStoreError.invalidAudio(file) }
        return try pcm16.withUnsafeBytes { bytes in
            try publish(file: file, assetId: assetId, frames: bytes.count / 2, sampleRate: sampleRate,
                        paidRoot: paidRoot, createdAt: createdAt, afterPublish: afterPublish) { start, destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[(start * 2)..<(start * 2 + destination.count)]))
            }
        }
    }

    /// Conformed or assembled mono audio at the source rate, converted sample by sample with `pcm16(_:)`.
    public static func writeDerived(samples: [Float], sampleRate: Int, projectId: String, assetId: String,
                                    paidRoot: URL, createdAt: Date) throws -> VoiceLabAsset {
        let file = try VoiceLabAssetNaming.file(projectId: projectId, assetId: assetId, extension: "wav")
        guard samples.allSatisfy(\.isFinite) else { throw VoiceLabAssetStoreError.invalidAudio(file) }
        return try samples.withUnsafeBufferPointer { values in
            try publish(file: file, assetId: assetId, frames: values.count, sampleRate: sampleRate,
                        paidRoot: paidRoot, createdAt: createdAt, afterPublish: nil) { start, destination in
                for index in 0..<(destination.count / 2) {
                    destination.storeBytes(of: pcm16(values[start + index]).littleEndian, toByteOffset: index * 2, as: Int16.self)
                }
            }
        }
    }

    /// The float rule: round half to even of x × 32767, clamped to ±32767. The product is exact in binary64 (24 + 15
    /// significant bits), so 0.50006103515625 gives 16385 where a float32 multiply would give 16386. Callers refuse
    /// nonfinite samples.
    static func pcm16(_ sample: Float) -> Int16 {
        Int16(max(-32_767, min(32_767, (Double(sample) * 32_767).rounded(.toNearestOrEven))))
    }

    /// The canonical 44-byte little-endian header: RIFF size, one 16-byte `fmt ` chunk for mono PCM16, then `data`.
    static func wavHeader(frames: Int, sampleRate: Int) -> Data {
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + frames * 2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(frames * 2))
        return header
    }

    /// Checked before any file or directory is created.
    static func validate(frames: Int, sampleRate: Int, file: String) throws {
        guard (8_000...192_000).contains(sampleRate), frames >= 1 else { throw VoiceLabAssetStoreError.invalidAudio(file) }
        guard frames <= maxFrames else { throw VoiceLabAssetStoreError.tooLarge(file) }
    }

    private static func publish(file: String, assetId: String, frames: Int, sampleRate: Int, paidRoot: URL, createdAt: Date,
                                afterPublish: (() -> Void)?,
                                pcm: (_ start: Int, _ destination: UnsafeMutableRawBufferPointer) -> Void) throws -> VoiceLabAsset {
        try validate(frames: frames, sampleRate: sampleRate, file: file)
        let parts = file.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw VoiceLabAssetStoreError.unsafePath(file) }
        let rootFD = try openRoot(paidRoot, file: file)
        defer { Darwin.close(rootFD) }
        let projectFD = try directory(parts[0], in: rootFD, file: file)
        defer { Darwin.close(projectFD) }
        let name = parts[1]
        // Anything already at the name, a link or directory included, is refused before a byte is written.
        // RENAME_EXCL below still settles a race with another writer.
        var existing = stat()
        if Darwin.fstatat(projectFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 { throw VoiceLabAssetStoreError.alreadyExists(file) }
        guard errno == ENOENT else { throw VoiceLabAssetStoreError.unwritable(file) }
        let temporary = ".\(name).\(UUID().uuidString.lowercased()).partial"
        let fd = Darwin.openat(projectFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VoiceLabAssetStoreError.unwritable(file) }
        var published = false
        defer { if !published { _ = Darwin.unlinkat(projectFD, temporary, 0) } }
        var hash = SHA256()
        do {
            defer { Darwin.close(fd) }
            let header = wavHeader(frames: frames, sampleRate: sampleRate)
            hash.update(data: header)
            try header.withUnsafeBytes { try writeAll(fd, $0, file) }
            var chunk = [UInt8](repeating: 0, count: 2 * min(block, frames))
            var start = 0
            while start < frames {
                try Task.checkCancellation()
                let count = min(block, frames - start)
                try chunk.withUnsafeMutableBytes { raw in
                    let destination = UnsafeMutableRawBufferPointer(rebasing: raw[0..<(2 * count)])
                    pcm(start, destination)
                    hash.update(bufferPointer: UnsafeRawBufferPointer(destination))
                    try writeAll(fd, UnsafeRawBufferPointer(destination), file)
                }
                start += count
            }
            guard fullSync(fd) else { throw VoiceLabAssetStoreError.unwritable(file) }
        }
        try Task.checkCancellation()
        guard renameatx_np(projectFD, temporary, projectFD, name, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? VoiceLabAssetStoreError.alreadyExists(file) : VoiceLabAssetStoreError.unwritable(file)
        }
        // From here the paid file exists under its final name and is kept, whatever happens next.
        published = true
        afterPublish?()
        guard fullSync(projectFD) else { throw VoiceLabAssetStoreError.publishedUnverified(file) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard try readBack(projectFD, name, bytes: 44 + 2 * frames, file: file) == digest else {
            throw VoiceLabAssetStoreError.altered(file)
        }
        return VoiceLabAsset(id: assetId, file: file, sha256: digest, durationSeconds: Double(frames) / Double(sampleRate),
                             sampleRate: sampleRate, createdAt: createdAt)
    }

    /// The paid root as a directory descriptor, resolved as `VoiceLabAssets.prepare` resolves it. When only its last
    /// component is missing, that component is created inside the existing parent, which is opened without following
    /// a link. Intermediate components are never created: a missing parent is `rootMissing`.
    private static func openRoot(_ paidRoot: URL, file: String) throws -> Int32 {
        let root = paidRoot.standardizedFileURL
        let fd = Darwin.open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { return fd }
        guard errno == ENOENT else {
            throw errno == ENOTDIR ? VoiceLabAssetStoreError.unsafePath(file) : VoiceLabAssetStoreError.unwritable(file)
        }
        let parent = Darwin.open(root.deletingLastPathComponent().resolvingSymlinksInPath().path,
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            switch errno {
            case ENOENT: throw VoiceLabAssetStoreError.rootMissing(file)
            case ENOTDIR, ELOOP: throw VoiceLabAssetStoreError.unsafePath(file)
            default: throw VoiceLabAssetStoreError.unwritable(file)
            }
        }
        defer { Darwin.close(parent) }
        return try directory(root.lastPathComponent, in: parent, file: file)
    }

    /// Creates `name` in `parent` with mode 0700 when it is missing, flushing the parent, then opens it as a directory
    /// without following a link.
    private static func directory(_ name: String, in parent: Int32, file: String) throws -> Int32 {
        if Darwin.mkdirat(parent, name, 0o700) == 0 {
            guard fullSync(parent) else { throw VoiceLabAssetStoreError.unwritable(file) }
        } else if errno != EEXIST {
            throw VoiceLabAssetStoreError.unwritable(file)
        }
        let fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ELOOP || errno == ENOTDIR ? VoiceLabAssetStoreError.unsafePath(file) : VoiceLabAssetStoreError.unwritable(file)
        }
        return fd
    }

    /// Flushes through the drive's own write cache, which `fsync` alone does not (`man 2 fsync`). A volume that refuses
    /// `F_FULLFSYNC` with ENOTSUP or EINVAL falls back to `fsync`.
    static func fullSync(_ fd: Int32) -> Bool {
        while Darwin.fcntl(fd, F_FULLFSYNC) == -1 {
            if errno == EINTR { continue }
            return (errno == ENOTSUP || errno == EINVAL) && Darwin.fsync(fd) == 0
        }
        return true
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, _ file: String) throws {
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw VoiceLabAssetStoreError.unwritable(file)
            }
            offset += written
        }
    }

    /// The SHA-256 of the published file, reopened through its directory and never through a link. A link, a missing
    /// name, another type or another size there is `altered`; any other failure to read it is `publishedUnverified`.
    private static func readBack(_ directory: Int32, _ name: String, bytes: Int, file: String) throws -> String {
        let fd = Darwin.openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ELOOP || errno == ENOENT ? VoiceLabAssetStoreError.altered(file) : VoiceLabAssetStoreError.publishedUnverified(file)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw VoiceLabAssetStoreError.publishedUnverified(file) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size == off_t(bytes) else {
            throw VoiceLabAssetStoreError.altered(file)
        }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw VoiceLabAssetStoreError.publishedUnverified(file)
            }
            if count == 0 { break }
            total += count
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        guard total == bytes else { throw VoiceLabAssetStoreError.altered(file) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
