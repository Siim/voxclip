import Darwin
import Foundation
import VoxClipCore

enum VoiceLabAssetRecovery {
    static let processStartedAt: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000)
    }()
    static func lock(_ root: Int32) throws -> Int32 {
        let descriptor = openat(root, ".asset-write.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VoiceLabAssetStoreError.unwritable("VoiceLab") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor); throw VoiceLabAssetStoreError.unsafePath("VoiceLab")
        }
        return descriptor
    }
    static func names(_ descriptor: Int32) throws -> [String] {
        guard let directory = fdopendir(dup(descriptor)) else { throw VoiceLabAssetStoreError.unwritable("VoiceLab") }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw VoiceLabAssetStoreError.unwritable("VoiceLab") }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
    static func recover(_ root: Int32, before deadline: Date) throws -> Int {
        var removed = 0
        for project in try names(root) {
            guard (try? VoiceLabAssetNaming.file(projectId: project, assetId: "probe", extension: "wav")) != nil else { continue }
            let directory = openat(root, project, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            for name in try names(directory) {
                guard name.hasPrefix("."), name.hasSuffix(".partial") else { continue }
                let stem = String(name.dropFirst().dropLast(8))
                guard let separator = stem.range(of: ".wav.", options: .backwards) else { continue }
                let asset = String(stem[..<separator.lowerBound]), identity = String(stem[separator.upperBound...])
                guard let uuid = UUID(uuidString: identity), uuid.uuidString.lowercased() == identity,
                      (try? VoiceLabAssetNaming.file(projectId: project, assetId: asset, extension: "wav")) == "\(project)/\(asset).wav" else { continue }
                var info = stat()
                guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
                let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                guard modified < deadline else { continue }
                guard unlinkat(directory, name, 0) == 0 else { throw VoiceLabAssetStoreError.unwritable(name) }
                removed += 1
            }
            guard VoiceLabPaidRoot.fullSync(directory) else { throw VoiceLabAssetStoreError.unwritable(project) }
        }
        return removed
    }
}
