import Foundation

/// GitHub release metadata; architecture §13.1.
public struct UpdateRelease: Codable, Sendable, Equatable {
    /// version; GitHub release metadata; architecture §13.1.
    public var version: String
    /// htmlURL; GitHub release metadata; architecture §13.1.
    public var htmlURL: URL
    /// downloadURL; GitHub release metadata; architecture §13.1.
    public var downloadURL: URL?

    /// Creates an explicit value without I/O or generated identifiers.
    public init(version: String, htmlURL: URL, downloadURL: URL? = nil) {
        self.version = version
        self.htmlURL = htmlURL
        self.downloadURL = downloadURL
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case htmlURL
        case downloadURL
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try values.decode(String.self, forKey: .version)
        self.htmlURL = try values.decode(URL.self, forKey: .htmlURL)
        self.downloadURL = try values.decodeIfPresent(URL.self, forKey: .downloadURL) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.version, forKey: .version)
        try values.encode(self.htmlURL, forKey: .htmlURL)
        try values.encode(self.downloadURL, forKey: .downloadURL)
    }

}

/// Update checks never download, quit or interrupt export; architecture §13.1.
public protocol UpdateChecking: Sendable { func check(currentVersion: String) async throws -> UpdateRelease? }
/// mac-ui owns HTTP transport, 24-hour throttle and settings cache.
public actor UpdateChecker: UpdateChecking {
    public init() {}
    public func check(currentVersion: String) async throws -> UpdateRelease? { throw VoxClipError.notImplemented("mac-ui") }
}
