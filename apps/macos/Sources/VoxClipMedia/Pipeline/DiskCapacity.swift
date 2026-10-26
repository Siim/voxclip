import Darwin
import Foundation
import VoxClipCore

/// Planned additional bytes, grouped by the volume on which each file will be made.
enum DiskCapacity {
    struct Need {
        let directory: URL
        let bytes: Int64
    }
    struct Volume {
        let id: UInt64
        let freeBytes: Int64
    }
    typealias Provider = (URL) throws -> Volume

    static func checkedAdd(_ left: Int64, _ right: Int64, at url: URL) throws -> Int64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard left >= 0, right >= 0, !overflow else { throw VoxClipError.diskFull(url.path) }
        return sum
    }

    static func checkedMultiply(_ left: Int64, _ right: Int64, at url: URL) throws -> Int64 {
        let (product, overflow) = left.multipliedReportingOverflow(by: right)
        guard left >= 0, right >= 0, !overflow else { throw VoxClipError.diskFull(url.path) }
        return product
    }

    static func fileBytes(_ url: URL) throws -> Int64 {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw VoxClipError.exportFailed("Output is not a regular file") }
            return info.st_size
        }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return 0
    }

    static func systemVolume(_ directory: URL) throws -> Volume {
        var disk = statfs(), entry = stat()
        guard statfs(directory.path, &disk) == 0, stat(directory.path, &entry) == 0 else {
            throw VoxClipError.diskFull(directory.path)
        }
        guard let availableBlocks = Int64(exactly: disk.f_bavail), disk.f_bsize > 0 else {
            throw VoxClipError.diskFull(directory.path)
        }
        let free = try checkedMultiply(availableBlocks, Int64(disk.f_bsize), at: directory)
        return Volume(id: UInt64(entry.st_dev), freeBytes: free)
    }

    static func check(_ needs: [Need], provider: Provider = systemVolume) throws {
        var totals: [UInt64: (required: Int64, free: Int64, path: String)] = [:]
        for need in needs {
            guard need.bytes >= 0 else { throw VoxClipError.diskFull(need.directory.path) }
            let volume = try provider(need.directory)
            let previous = totals[volume.id]?.required ?? 0
            let required = try checkedAdd(previous, need.bytes, at: need.directory)
            totals[volume.id] = (required, min(totals[volume.id]?.free ?? volume.freeBytes, volume.freeBytes), need.directory.path)
        }
        for item in totals.values where item.required > item.free {
            throw VoxClipError.diskFull(item.path)
        }
    }
}
