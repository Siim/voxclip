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

/// Whether this process runs tests. Only DEBUG builds look: `swift test`'s swiftpm-testing-helper, xctest, an XCTest
/// configuration, or a loaded `.xctest` bundle. A test process never reaches the login keychain (`SecretStore`) and never
/// writes the user's log folder (`DataLocations.logs`).
public enum TestProcess {
    public static let isRunning: Bool = {
        #if DEBUG
        detect(environment: ProcessInfo.processInfo.environment, processName: ProcessInfo.processInfo.processName,
               arguments: CommandLine.arguments, bundlePaths: Bundle.allBundles.map(\.bundlePath))
        #else
        false
        #endif
    }()
    /// Where a test process's logs go when no `VOXCLIP_DATA_DIR` is set: this process's own temporary folder.
    public static var logs: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VoxClipTests-\(ProcessInfo.processInfo.processIdentifier)/Logs", isDirectory: true)
    }
    package static func detect(environment: [String: String], processName: String, arguments: [String], bundlePaths: [String] = []) -> Bool {
        processName.contains("swiftpm-testing-helper") || processName == "xctest"
            || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || arguments.contains { $0.contains(".xctest") || $0.contains("swift-testing") || $0.hasSuffix("Tests") || $0.hasSuffix("Tests-product") }
            || bundlePaths.contains { $0.hasSuffix(".xctest") }
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
    /// Without `VOXCLIP_DATA_DIR`, a test process (`testing`) logs to its own temporary folder, never ~/Library/Logs.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                testing: Bool = TestProcess.isRunning) {
        let override = environment["VOXCLIP_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        root = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent("Library/Application Support/VoxClip", isDirectory: true)
        logs = override != nil ? root.appendingPathComponent("Logs", isDirectory: true)
            : testing ? TestProcess.logs : home.appendingPathComponent("Library/Logs/VoxClip", isDirectory: true)
        defaultExport = home.appendingPathComponent("Movies/VoxClip", isDirectory: true)
    }
}
