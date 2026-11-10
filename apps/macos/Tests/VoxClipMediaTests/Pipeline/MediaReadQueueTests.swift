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
