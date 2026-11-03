import Darwin
import Foundation

public struct LipsyncDiagnosticEvent: Codable, Sendable {
    public enum Stage: String, Codable, Sendable { case upload, submit, queued, running, completed, cancel, cleanup, failure }
    public let stage: Stage
    public let requestID: String?
    public let status: Int?
    public let seconds: Double
    public let bytes: Int?
    public let error: String?

    init(stage: Stage, requestID: String? = nil, status: Int? = nil, seconds: Double = 0, bytes: Int? = nil, error: LipsyncError? = nil) {
        self.stage = stage; self.requestID = requestID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        self.status = status; self.seconds = seconds; self.bytes = bytes
        self.error = error.map { String(describing: $0) }
    }
}

public protocol LipsyncDiagnosticSink: Sendable {
    func record(_ event: LipsyncDiagnosticEvent) async
}

#if DEBUG
public actor LipsyncDiagnostic: LipsyncDiagnosticSink {
    public let url: URL

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let root = environment["VOXCLIP_DATA_DIR"], root.hasPrefix("/"),
              !root.contains("/Library/"), !root.contains("..") else { return nil }
        url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("Diagnostics/lipsync.jsonl")
    }

    public func record(_ event: LipsyncDiagnosticEvent) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let directory = try LipsyncLocalPath.openDirectory(url.deletingLastPathComponent())
            defer { Darwin.close(directory) }
            let descriptor = openat(directory, url.lastPathComponent, O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return }
            var data = try JSONEncoder().encode(event); data.append(10)
            try handle.write(contentsOf: data)
        } catch { }
    }
}
#endif
