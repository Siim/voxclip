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
    private let url: URL
    private let logger: any Logger
    private var current: SettingsDocument?
    private var pending: SettingsDocument?
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0
    public private(set) var lastWriteError: String?
    public private(set) var lastLoadError: VoxClipError?

    public init() {
        url = DataLocations().settings
        logger = RedactingLogger(homeDirectory: NSHomeDirectory())
    }
    public init(logger: any Logger) {
        url = DataLocations().settings
        self.logger = logger
    }
    public init(locations: DataLocations) {
        url = locations.settings
        logger = RedactingLogger(homeDirectory: NSHomeDirectory())
    }
    public init(locations: DataLocations, logger: any Logger) {
        url = locations.settings
        self.logger = logger
    }

    public func load() async throws -> SettingsDocument {
        if let current { return current }
        let document: SettingsDocument
        if FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw VoxClipError.projectUnreadable("Could not read settings") }
            do {
                let decoded = try JSONDecoder().decode(SettingsDocument.self, from: data)
                try decoded.validate()
                document = decoded
            } catch {
                document = Self.recoverValues(data)
                do { try data.write(to: damagedURL(), options: .withoutOverwriting) }
                catch { throw VoxClipError.projectUnreadable("Could not preserve damaged settings") }
                do { try AtomicJSON.write(AtomicJSON.encoded(document), to: url) }
                catch {
                    let failure = VoxClipError.projectUnreadable("Could not persist recovered settings")
                    current = document
                    pending = document
                    lastWriteError = "Settings could not be saved"
                    lastLoadError = failure
                    throw failure
                }
                current = document
                lastWriteError = nil
                lastLoadError = .projectUnreadable("Damaged settings were set aside; valid preferences were recovered")
                await logger.write(LogEntry(level: .warn, category: "settings", message: "Damaged settings were set aside; valid preferences were recovered"))
                return document
            }
        } else { document = SettingsDocument() }
        current = document
        return document
    }

    private static func recoverValues(_ data: Data) -> SettingsDocument {
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let object) = raw else { return SettingsDocument() }
        var recovered = SettingsDocument()
        for (key, value) in object where key != "schema" {
            if (try? SettingsDocument(values: [key: value]).validate()) != nil { recovered.values[key] = value }
        }
        return recovered
    }

    private func damagedURL() -> URL {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let base = url.path + ".damaged-" + timestamp
        var destination = URL(fileURLWithPath: base)
        var suffix = 0
        while FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = URL(fileURLWithPath: base + "-\(suffix)")
        }
        return destination
    }

    public func save(_ settings: SettingsDocument) async throws {
        try settings.validate()
        let existing = try await load()
        var merged = existing.values.filter { !SettingsDocument.isKnownKey($0.key) }
        merged.merge(settings.values) { _, new in new }
        let snapshot = SettingsDocument(values: merged)
        try snapshot.validate()
        current = snapshot
        pending = snapshot
        task?.cancel()
        revision &+= 1
        let scheduledRevision = revision
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.scheduledFlush(scheduledRevision)
        }
    }

    private func scheduledFlush(_ scheduledRevision: UInt64) {
        guard revision == scheduledRevision else { return }
        do { try writePending() } catch { lastWriteError = "Settings could not be saved" }
    }

    private func writePending() throws {
        guard let pending else { return }
        do { try AtomicJSON.write(AtomicJSON.encoded(pending), to: url) }
        catch {
            lastWriteError = "Settings could not be saved"
            throw VoxClipError.projectUnreadable("Settings could not be saved")
        }
        self.pending = nil
        lastWriteError = nil
    }

    public func flush() async throws {
        task?.cancel()
        task = nil
        try writePending()
    }
}
