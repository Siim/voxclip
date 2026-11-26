import CryptoKit
import Foundation
import VoxClipCore

public struct FolderRecording: Identifiable, Sendable, Equatable {
    public let id: String
    public let url: URL
    public let duration: Double
    public let bytes: Int64
    public let imported: Bool
    public let media: MediaProbeResult
}

public enum RecordingFolder {
    public static func scan(_ folder: URL, library: URL, probe: any MediaProbe = AVMediaProbe()) async throws -> [FolderRecording] {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = files.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let facts = try url.resourceValues(forKeys: keys)
            if facts.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if facts.isRegularFile == true && ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) { urls.append(url) }
        }
        let known = try importedHashes(library)
        var seen = Set<String>()
        var result: [FolderRecording] = []
        for url in urls.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            try Task.checkCancellation()
            guard let media = try? await probe.probe(url), media.video != nil,
                  let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            let key = try hash(url)
            guard seen.insert(key).inserted else { continue }
            result.append(.init(id: key, url: url, duration: media.durationSeconds, bytes: Int64(bytes), imported: known.contains(key), media: media))
        }
        return result
    }

    public static func copy(_ recording: FolderRecording, to directory: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = String(recording.url.deletingPathExtension().lastPathComponent.prefix(100))
        let destination = directory.appendingPathComponent("\(base)--\(recording.id).\(recording.url.pathExtension.lowercased())")
        if files.fileExists(atPath: destination.path), try hash(destination) == recording.id { return destination }
        let staged = directory.appendingPathComponent(".copy-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staged) }
        try files.copyItem(at: recording.url, to: staged)
        guard try hash(staged) == recording.id else { throw VoxClipError.decodeFailed("Recording changed after it was scanned") }
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.path) { _ = try files.replaceItemAt(destination, withItemAt: staged) }
        else { try files.moveItem(at: staged, to: destination) }
        return destination
    }

    private static func importedHashes(_ root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var known = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard url.pathExtension == "voxclip" else { continue }
            let stem = url.deletingPathExtension()
            let name = stem.lastPathComponent
            let key = String(name.suffix(64))
            if key.count == 64, name.dropLast(64).hasSuffix("--"), key.allSatisfy({ $0.isASCII && $0.isHexDigit }),
               ["mov", "mp4", "m4v"].contains(where: { FileManager.default.fileExists(atPath: stem.appendingPathExtension($0).path) }) {
                known.insert(key)
            }
        }
        return known
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            sha.update(data: data)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
