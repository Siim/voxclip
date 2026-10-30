import Darwin
import Foundation
import VoxClipCore

public final class VoiceLabAssetActivity: Sendable {
    private let descriptor: Int32
    public init(paidRoot: URL) throws {
        let root = try VoiceLabPaidRoot.open(paidRoot)
        defer { close(root) }
        descriptor = try Self.open(root)
        guard flock(descriptor, LOCK_SH) == 0 else {
            close(descriptor); throw VoiceLabAssetStoreError.unwritable("asset activity")
        }
    }
    deinit { close(descriptor) }
    static func exclusive(_ root: Int32) throws -> Int32? {
        let descriptor = try open(root)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            if busy { return nil }
            throw VoiceLabAssetStoreError.unwritable("asset activity")
        }
        return descriptor
    }
    private static func open(_ root: Int32) throws -> Int32 {
        let descriptor = openat(root, ".asset-activity.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VoiceLabAssetStoreError.unwritable("asset activity") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(descriptor); throw VoiceLabAssetStoreError.unsafePath("asset activity")
        }
        return descriptor
    }
}
