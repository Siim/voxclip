import Foundation

/// Settings snapshot; architecture §2.5. Values flatten into the JSON root and preserve unknown keys.
public struct SettingsDocument: Codable, Sendable, Equatable {
    /// schema; Settings snapshot; architecture §2.5. Values flatten into the JSON root and preserve unknown keys.
    public var schema: String
    /// values; Settings snapshot; architecture §2.5. Values flatten into the JSON root and preserve unknown keys.
    public var values: [String: JSONValue]

    /// Creates an explicit value without I/O or generated identifiers.
    public init(schema: String = "voxclip-settings/1", values: [String: JSONValue] = [:]) {
        self.schema = schema
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        guard case .object(var object) = try JSONValue(from: decoder), case .string(let schema)? = object.removeValue(forKey: "schema") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected settings object and schema"))
        }
        self.schema = schema
        self.values = object
    }

    public func encode(to encoder: any Encoder) throws {
        var object = values
        object["schema"] = .string(schema)
        try JSONValue.object(object).encode(to: encoder)
    }

}

/// Debounced, atomic settings boundary; architecture §2.5 and §7.1. Never stores credentials.
public protocol SettingsStore: Sendable {
    func load() async throws -> SettingsDocument
    func save(_ settings: SettingsDocument) async throws
    func flush() async throws
}

/// mac-editing owns persistence and the 500 ms debounce.
public actor JSONSettingsStore: SettingsStore {
    public init() {}
    public func load() async throws -> SettingsDocument { throw VoxClipError.notImplemented("mac-editing") }
    public func save(_ settings: SettingsDocument) async throws { throw VoxClipError.notImplemented("mac-editing") }
    public func flush() async throws { throw VoxClipError.notImplemented("mac-editing") }
}
