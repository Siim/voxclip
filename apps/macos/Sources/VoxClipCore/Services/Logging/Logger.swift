import Foundation

/// Log severities; architecture §11.1.
public enum LogLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case error
    case warn
    case info
    case debug
}

/// Diagnostic event; architecture §11.1. Never include transcript, prompts or provider bodies.
public struct LogEntry: Codable, Sendable, Equatable {
    /// level; Diagnostic event; architecture §11.1. Never include transcript, prompts or provider bodies.
    public var level: LogLevel
    /// category; Diagnostic event; architecture §11.1. Never include transcript, prompts or provider bodies.
    public var category: String
    /// message; Diagnostic event; architecture §11.1. Never include transcript, prompts or provider bodies.
    public var message: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(level: LogLevel, category: String, message: String) {
        self.level = level
        self.category = category
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case category
        case message
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.level = try values.decode(LogLevel.self, forKey: .level)
        self.category = try values.decode(String.self, forKey: .category)
        self.message = try values.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.level, forKey: .level)
        try values.encode(self.category, forKey: .category)
        try values.encode(self.message, forKey: .message)
    }

}

/// Nonblocking diagnostic seam; architecture §11.1. The sink must redact every line and swallow sink failures.
public protocol Logger: Sendable { func write(_ entry: LogEntry) async }
/// Secret registration and redaction seam used by connectors; AI §3.1, architecture §11.2.
public protocol Redacting: Logger {
    func register(secret: String) async
    func redact(_ message: String) async -> String
}
/// Logging facade; architecture §11.1.
public struct Log: Sendable {
    public var logger: any Logger
    public init(logger: any Logger) { self.logger = logger }
    public func write(_ level: LogLevel, category: String, message: String) async { await logger.write(LogEntry(level: level, category: category, message: message)) }
}
public actor RedactingLogger: Redacting {
    private var redactor: Redactor
    private let directory: URL?
    private let systemSink: @Sendable (LogEntry) -> Void
    private var sinkFailed = false
    public init(homeDirectory: String) {
        redactor = Redactor(homeDirectory: homeDirectory)
        directory = nil
        systemSink = { _ in }
    }
    public init(homeDirectory: String, directory: URL, systemSink: @escaping @Sendable (LogEntry) -> Void = { _ in }) {
        redactor = Redactor(homeDirectory: homeDirectory)
        self.directory = directory
        self.systemSink = systemSink
    }
    public func register(secret: String) { redactor.register(secret: secret) }
    public func redact(_ message: String) -> String { redactor.redact(message) }
    public func write(_ entry: LogEntry) async {
        let safe = LogEntry(level: entry.level, category: redactor.redact(entry.category), message: redactor.redact(entry.message))
        systemSink(safe)
        guard let directory else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("voxclip.log")
            let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size >= 5 * 1_024 * 1_024 {
                for index in stride(from: 4, through: 1, by: -1) {
                    let destination = directory.appendingPathComponent("voxclip.\(index).log")
                    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                    let source = index == 1 ? file : directory.appendingPathComponent("voxclip.\(index - 1).log")
                    if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: destination) }
                }
            }
            let line = "\(Date().ISO8601Format()) [\(safe.level.rawValue)] \(safe.category): \(safe.message.replacingOccurrences(of: "\n", with: " "))\n"
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            if !sinkFailed {
                sinkFailed = true
                systemSink(LogEntry(level: .warn, category: "logging", message: "File logging is unavailable."))
            }
        }
    }
}
