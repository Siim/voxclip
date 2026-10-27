import Foundation

public struct Sidecar: Codable, Equatable, Sendable {
    public let schema: String
    public let startedAt: Date
    public let startedAtUnixSeconds: Double
    public let startedAtUptimeSeconds: Double
    public let app: String
    public let title: String
    public let windowID: UInt32
    public let width: Int
    public let height: Int
    public let fps: Int
    public let cursorVisible: Bool
    public let codec: String
    public var durationSeconds: Double?

    public init(startedAt: Date, uptime: Double, app: String, title: String, windowID: UInt32,
                width: Int, height: Int, codec: String) {
        schema = "voxclip-window-recording/1"
        self.startedAt = startedAt; startedAtUnixSeconds = startedAt.timeIntervalSince1970
        startedAtUptimeSeconds = uptime
        self.app = app; self.title = title; self.windowID = windowID
        self.width = width; self.height = height; self.codec = codec
        fps = 60; cursorVisible = false; durationSeconds = nil
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public func write(to url: URL) throws {
        try data().write(to: url, options: .atomic)
    }
}
