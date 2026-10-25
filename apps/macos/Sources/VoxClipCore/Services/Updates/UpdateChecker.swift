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
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    public init() {}
    public func check(currentVersion: String) async throws -> UpdateRelease? {
        let endpoint = URL(string: "https://api.github.com/repos/Siim/voxclip/releases/latest")!
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("VoxClip/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw VoxClipError.offline }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200, data.count < 2_000_000 else { throw VoxClipError.providerError("Update check failed (\(response.statusCode)).") }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return Self.available(version: release.tag_name, htmlURL: release.html_url, downloadURL: release.assets.first { $0.name == "VoxClip-macOS.dmg" }?.browser_download_url, currentVersion: currentVersion, prerelease: release.prerelease || release.draft)
    }
    public static func available(version: String, htmlURL: URL, downloadURL: URL?, currentVersion: String, prerelease: Bool = false) -> UpdateRelease? {
        guard !prerelease, htmlURL.scheme == "https", htmlURL.host == "github.com", compareVersions(version, currentVersion) == .orderedDescending else { return nil }
        let version = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let safeDownload = downloadURL.flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil }
        return UpdateRelease(version: version, htmlURL: htmlURL, downloadURL: safeDownload)
    }
}
