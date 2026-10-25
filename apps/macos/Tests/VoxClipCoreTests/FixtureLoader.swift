import Foundation
import VoxClipCore

/// Repository fixtures, never SwiftPM resources; architecture §2.4.
enum FixtureLoader {
    static func sharedRoot(environment: [String: String] = ProcessInfo.processInfo.environment, sourcePath: String = #filePath) throws -> URL {
        let manager = FileManager.default
        if let path = environment["VOXCLIP_SHARED_DIR"], !path.isEmpty {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard manager.fileExists(atPath: root.appendingPathComponent("fixtures").path) else { throw VoxClipError.sharedResourcesMissing }
            return root
        }
        var directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent("shared", isDirectory: true)
            if manager.fileExists(atPath: candidate.appendingPathComponent("fixtures").path), manager.fileExists(atPath: directory.appendingPathComponent("apps").path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        throw VoxClipError.sharedResourcesMissing
    }
    static func data(_ relativePath: String) throws -> Data { try Data(contentsOf: sharedRoot().appendingPathComponent(relativePath)) }
    static func decode<Value: Decodable>(_ type: Value.Type, at relativePath: String) throws -> Value { try ProjectJSON.decoder().decode(type, from: data(relativePath)) }
}
