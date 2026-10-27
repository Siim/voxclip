import Darwin
import Foundation

/// The paid Voice Lab root, `<data>/VoiceLab` (voice-lab.md §10.1), opened and flushed one way for every writer in it: the
/// Media asset store and the spend ledger.
package enum VoiceLabPaidRoot {
    /// Why the root, or a directory in it, could not be opened.
    package enum Failure: Error, Sendable, Equatable {
        /// The data folder that should hold the root is missing. It is never created here.
        case rootMissing
        /// A link or another file type stands where a directory belongs.
        case unsafePath
        /// Any other failure, such as permissions or a full disk.
        case unwritable
    }

    /// The paid root as a directory descriptor, resolved as `VoiceLabAssets.prepare` resolves it. When only its last
    /// component is missing, that component is created inside the existing parent, which is opened without following
    /// a link. Intermediate components are never created: a missing parent is `rootMissing`.
    package static func open(_ paidRoot: URL) throws -> Int32 {
        let root = paidRoot.standardizedFileURL
        let fd = Darwin.open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 { return fd }
        guard errno == ENOENT else { throw errno == ENOTDIR ? Failure.unsafePath : Failure.unwritable }
        let parent = Darwin.open(root.deletingLastPathComponent().resolvingSymlinksInPath().path,
                                 O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            switch errno {
            case ENOENT: throw Failure.rootMissing
            case ENOTDIR, ELOOP: throw Failure.unsafePath
            default: throw Failure.unwritable
            }
        }
        defer { Darwin.close(parent) }
        return try directory(root.lastPathComponent, in: parent)
    }

    /// Creates `name` in `parent` with mode 0700 when it is missing, flushing the parent, then opens it as a directory
    /// without following a link.
    package static func directory(_ name: String, in parent: Int32) throws -> Int32 {
        if Darwin.mkdirat(parent, name, 0o700) == 0 {
            guard fullSync(parent) else { throw Failure.unwritable }
        } else if errno != EEXIST {
            throw Failure.unwritable
        }
        let fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP || errno == ENOTDIR ? Failure.unsafePath : Failure.unwritable }
        return fd
    }

    /// Flushes through the drive's own write cache, which `fsync` alone does not (`man 2 fsync`). A volume that refuses
    /// `F_FULLFSYNC` with ENOTSUP or EINVAL falls back to `fsync`.
    package static func fullSync(_ fd: Int32) -> Bool {
        while Darwin.fcntl(fd, F_FULLFSYNC) == -1 {
            if errno == EINTR { continue }
            return (errno == ENOTSUP || errno == EINVAL) && Darwin.fsync(fd) == 0
        }
        return true
    }
}
