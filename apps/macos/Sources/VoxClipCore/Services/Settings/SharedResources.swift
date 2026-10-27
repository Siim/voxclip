import Foundation

/// Runtime shared-data root, never copied into SwiftPM resources; architecture §2.4.
public struct SharedResources: Sendable, Equatable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment, executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]), bundleURL: URL? = Bundle.main.resourceURL) throws -> SharedResources {
        let manager = FileManager.default
        func valid(_ url: URL) -> Bool {
            ["caption-styles", "data/share-text.json"].allSatisfy { manager.fileExists(atPath: url.appendingPathComponent($0).path) }
        }
        if let path = environment["VOXCLIP_SHARED_DIR"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard valid(url) else { throw VoxClipError.sharedResourcesMissing }
            return SharedResources(root: url)
        }
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let bundled = [bundleURL?.appendingPathComponent("shared", isDirectory: true), executable.deletingLastPathComponent().appendingPathComponent("../Resources/shared", isDirectory: true)]
        for case let url? in bundled where valid(url) { return SharedResources(root: url.standardizedFileURL) }
        var directory = executable.deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent("shared", isDirectory: true)
            if valid(candidate), manager.fileExists(atPath: directory.appendingPathComponent("apps").path) { return SharedResources(root: candidate) }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        throw VoxClipError.sharedResourcesMissing
    }
}

/// Per-user locations without creating or deleting data; architecture §2.5.
public struct DataLocations: Sendable, Equatable {
    public let root: URL
    public let logs: URL
    public let defaultExport: URL
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let override = environment["VOXCLIP_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        root = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent("Library/Application Support/VoxClip", isDirectory: true)
        logs = override == nil ? home.appendingPathComponent("Library/Logs/VoxClip", isDirectory: true) : root.appendingPathComponent("Logs", isDirectory: true)
        defaultExport = home.appendingPathComponent("Movies/VoxClip", isDirectory: true)
    }
}
