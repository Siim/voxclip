import AVFoundation
import Foundation
import Testing
@testable import VoxClipMedia

/// `MediaReadQueue`: AVAssetReader pulls run off the cooperative pool (CI 42828823833).
@Suite(.offlineFixtures) struct MediaReadQueueTests {
    /// More readers at once than the pool has threads. Pulled on the pool they never finish (locally 14 of 14 cores' worth
    /// hang and 13 finish; CI's 3-core runner stopped at 3); through the queue they do, both ways the app reads.
    @Test func moreReadersThanPoolThreadsAllFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-read-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("movie.mp4")
        try FixtureLoader.data("fixtures/cover-art/moov-first.mp4").write(to: file)
        let one = try await Self.loopSamples(file)
        #expect(one > 3, "three H.264 frames and the AAC chunks")
        #expect(try await Self.providerSamples(file) == one)
        let width = ProcessInfo.processInfo.activeProcessorCount + 1
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<width {
                group.addTask { index.isMultiple(of: 2) ? try await Self.loopSamples(file) : try await Self.providerSamples(file) }
            }
            var counts: [Int] = []
            for try await count in group { counts.append(count) }
            return counts
        }
        #expect(counts == Array(repeating: one, count: width))
    }

    // MARK: The guard

    /// Split so this file's own patterns don't count.
    static let syncPull = "copyNext" + "SampleBuffer", next = ".ne" + "xt()"
    /// Files that may pull without `MediaReadQueue`, and why.
    static let allowed: [String: String] = [
        "Sources/VoxClipMedia/Pipeline/MediaReadQueue.swift": "the helper itself",
        "Sources/VoxClipMedia/Pipeline/ExportSampleReader.swift":
            "the exporter's pumps pull in a Task(executorPreference:) on their own per-pump queue, with their own stop handling",
    ]

    /// Reader pulls in `source` that hold the calling thread: `copyNextSampleBuffer`, or a provider's own `next()`.
    /// Comment lines don't count.
    static func pulls(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//") else { return nil }
            if code.contains(syncPull + "(") { return code }
            if code.range(of: #"[pP]rovider\w*(\([^()]*\))?\s*\.next\(\)"#, options: .regularExpression) != nil { return code }
            return nil
        }
    }

    @Test func thePullMatcherFindsBothKinds() {
        #expect(Self.pulls(in: "while let b = output.\(Self.syncPull)() {}").count == 1)
        #expect(Self.pulls(in: "while let s = try await provider\(Self.next) {}").count == 1)
        #expect(Self.pulls(in: "let s = try await videoProvider\(Self.next)").count == 1)
        #expect(Self.pulls(in: "let s = try await reader.outputProvider(for: output)\(Self.next)").count == 1)
        #expect(Self.pulls(in: "// output.\(Self.syncPull)()\nwhile let r = try await group\(Self.next) {}").isEmpty)
        #expect(Self.pulls(in: "while let s = try await MediaReadQueue.next(provider) {}").isEmpty)
        #expect(Self.pulls(in: "while let s = MediaReadQueue.copyNext(output) {}").isEmpty)
    }

    /// Every AVAssetReader pull under Sources/ and Tests/ goes through `MediaReadQueue` (CI 42828823833): a pull on a
    /// cooperative thread can stop the process once the pool fills.
    @Test func everyReaderPullGoesThroughTheReadQueue() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var scanned = 0
        for folder in ["Sources", "Tests"] {
            let walk = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let file as URL in walk where file.pathExtension == "swift" {
                scanned += 1
                let path = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                guard Self.allowed[path] == nil else { continue }
                let found = Self.pulls(in: try String(contentsOf: file, encoding: .utf8))
                #expect(found.isEmpty, "\(path) pulls an AVAssetReader on the calling thread: \(found). Wrap a synchronous loop in MediaReadQueue.run and pull with MediaReadQueue.copyNext; pull an output provider with MediaReadQueue.next (Sources/VoxClipMedia/Pipeline/MediaReadQueue.swift).")
            }
        }
        #expect(scanned > 500, "scanned \(scanned) files under \(root.path)")
        for path in Self.allowed.keys { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "\(path)") }
    }

    /// Every sample of every track, read by a synchronous loop on the queue.
    static func loopSamples(_ file: URL) async throws -> Int {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.load(.tracks)
        return try await MediaReadQueue.run {
            var count = 0
            for track in tracks {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
                while MediaReadQueue.copyNext(output) != nil { count += 1 }
                guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            }
            return count
        }
    }

    /// Every sample of every track, pulled from async output providers.
    static func providerSamples(_ file: URL) async throws -> Int {
        let asset = AVURLAsset(url: file)
        var count = 0
        for track in try await asset.load(.tracks) {
            let reader = try AVAssetReader(asset: asset)
            let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            while try await MediaReadQueue.next(provider) != nil { count += 1 }
        }
        return count
    }
}
