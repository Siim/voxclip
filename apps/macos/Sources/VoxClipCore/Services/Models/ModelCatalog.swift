import Foundation

/// Pinned download asset; transcription §12.1.
public struct ModelFile: Codable, Sendable, Equatable {
    /// role; Pinned download asset; transcription §12.1.
    public var role: String
    /// name; Pinned download asset; transcription §12.1.
    public var name: String
    /// url; Pinned download asset; transcription §12.1.
    public var url: URL
    /// bytes; Pinned download asset; transcription §12.1.
    public var bytes: Int64
    /// sha256; Pinned download asset; transcription §12.1.
    public var sha256: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(role: String, name: String, url: URL, bytes: Int64, sha256: String) {
        self.role = role
        self.name = name
        self.url = url
        self.bytes = bytes
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case name
        case url
        case bytes
        case sha256
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try values.decode(String.self, forKey: .role)
        self.name = try values.decode(String.self, forKey: .name)
        self.url = try values.decode(URL.self, forKey: .url)
        self.bytes = try values.decode(Int64.self, forKey: .bytes)
        self.sha256 = try values.decode(String.self, forKey: .sha256)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.role, forKey: .role)
        try values.encode(self.name, forKey: .name)
        try values.encode(self.url, forKey: .url)
        try values.encode(self.bytes, forKey: .bytes)
        try values.encode(self.sha256, forKey: .sha256)
    }

}

/// Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
public struct ModelDescriptor: Codable, Sendable, Equatable {
    /// id; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var id: String
    /// displayName; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var displayName: String
    /// engine; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var engine: TranscriptEngine
    /// files; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var files: [ModelFile]
    /// totalBytes; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var totalBytes: Int64
    /// languages; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var languages: [String]
    /// requires; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var requires: [String]
    /// license; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var license: String
    /// attribution; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var attribution: String
    /// sourcePage; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var sourcePage: URL
    /// publisher; Shared catalog entry projection; transcription §12.1. Additional catalog metadata remains in its document.
    public var publisher: String

    /// Creates an explicit value without I/O or generated identifiers.
    public init(id: String, displayName: String, engine: TranscriptEngine, files: [ModelFile], totalBytes: Int64, languages: [String], requires: [String] = [], license: String, attribution: String, sourcePage: URL, publisher: String) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.files = files
        self.totalBytes = totalBytes
        self.languages = languages
        self.requires = requires
        self.license = license
        self.attribution = attribution
        self.sourcePage = sourcePage
        self.publisher = publisher
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case engine
        case files
        case totalBytes
        case languages
        case requires
        case license
        case attribution
        case sourcePage
        case publisher
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.displayName = try values.decode(String.self, forKey: .displayName)
        self.engine = try values.decode(TranscriptEngine.self, forKey: .engine)
        self.files = try values.decode([ModelFile].self, forKey: .files)
        self.totalBytes = try values.decode(Int64.self, forKey: .totalBytes)
        self.languages = try values.decode([String].self, forKey: .languages)
        self.requires = try values.decodeIfPresent([String].self, forKey: .requires) ?? []
        self.license = try values.decode(String.self, forKey: .license)
        self.attribution = try values.decode(String.self, forKey: .attribution)
        self.sourcePage = try values.decode(URL.self, forKey: .sourcePage)
        self.publisher = try values.decode(String.self, forKey: .publisher)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.id, forKey: .id)
        try values.encode(self.displayName, forKey: .displayName)
        try values.encode(self.engine, forKey: .engine)
        try values.encode(self.files, forKey: .files)
        try values.encode(self.totalBytes, forKey: .totalBytes)
        try values.encode(self.languages, forKey: .languages)
        try values.encode(self.requires, forKey: .requires)
        try values.encode(self.license, forKey: .license)
        try values.encode(self.attribution, forKey: .attribution)
        try values.encode(self.sourcePage, forKey: .sourcePage)
        try values.encode(self.publisher, forKey: .publisher)
    }

}

/// Download and checksum progress; transcription §12.3.
public struct ModelDownloadProgress: Sendable, Equatable {
    public var modelID: String
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var verifying: Bool
    public init(modelID: String, receivedBytes: Int64, totalBytes: Int64, verifying: Bool = false) {
        self.modelID = modelID
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.verifying = verifying
    }
}

/// Bundled trusted catalog, never remotely replaced; transcription §12.1.
public protocol ModelCatalog: Sendable {
    func models() async throws -> [ModelDescriptor]
    func model(id: String) async throws -> ModelDescriptor
}
/// Verified resumable installs; transcription §12.2–12.3. Consent belongs to the caller.
public protocol ModelDownloader: Sendable {
    func installedModels() async throws -> [String]
    func install(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    func verify(id: String) async throws -> Bool
    func remove(id: String) async throws
}
/// mac-speech owns parsing and validation against shared/catalog.
public actor BundledModelCatalog: ModelCatalog {
    public init(shared: SharedResources) {}
    public func models() async throws -> [ModelDescriptor] { throw VoxClipError.notImplemented("mac-speech") }
    public func model(id: String) async throws -> ModelDescriptor { throw VoxClipError.notImplemented("mac-speech") }
}
/// Serial model manager, never evicted as cache; architecture §7.1 and transcription §12.
public actor ModelStore: ModelDownloader {
    public init(catalog: any ModelCatalog, locations: DataLocations) {}
    public func installedModels() async throws -> [String] { throw VoxClipError.notImplemented("mac-speech") }
    public func install(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws { throw VoxClipError.notImplemented("mac-speech") }
    public func verify(id: String) async throws -> Bool { throw VoxClipError.notImplemented("mac-speech") }
    public func remove(id: String) async throws { throw VoxClipError.notImplemented("mac-speech") }
}
