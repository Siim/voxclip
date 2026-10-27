import Foundation
import Testing
@testable import VoxClipCore

/// Writes what AVAudioExtractor writes into the request's directory, with bytes that name the source.
private struct RecordingExtractor: AudioExtractor {
    var wavBytes = 4000
    func extract(_ request: AudioExtractionRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioExtractionResult {
        try FileManager.default.createDirectory(at: request.cacheDirectory, withIntermediateDirectories: true)
        let wav = request.cacheDirectory.appendingPathComponent("audio-16k.wav")
        try Data(repeating: request.contentKey.utf8.first!, count: wavBytes).write(to: wav)
        try Data(request.contentKey.utf8).write(to: request.cacheDirectory.appendingPathComponent("envelope-10ms.f32"))
        progress(1)
        return AudioExtractionResult(audio: ExtractedAudio(wav16k: wav, sampleCount: 16, durationSeconds: 0.001),
                                     envelope: AudioEnvelope(sampleRate: 44100, levels: Array(repeating: 0.5, count: 16)))
    }
}

@Suite struct CacheEnvelopeTests {
    func locations() throws -> DataLocations {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../.build/cache-envelope-tests/\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        return DataLocations(environment: ["VOXCLIP_DATA_DIR": directory.path])
    }
    func file(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    @Test func twoTranscriptionsNoLongerOverwriteEachOther() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = CacheStore(locations: locations)
        for name in ["audio-16k.wav", "envelope-10ms.f32", "meta.json"] { try Data("stray".utf8).write(to: locations.cache.appendingPathComponent(name)) }
        let first = String(repeating: "a", count: 64), second = String(repeating: "b", count: 64)
        let source = locations.root.appendingPathComponent("take.mov")
        _ = try await store.extractAudio(sourceURL: source, contentKey: first, durationSeconds: 1, using: RecordingExtractor()) { _ in }
        _ = try await store.extractAudio(sourceURL: source, contentKey: second, durationSeconds: 1, using: RecordingExtractor()) { _ in }
        for key in [first, second] {
            let entry = locations.cache.appendingPathComponent(key)
            #expect(file(entry.appendingPathComponent("envelope-10ms.f32")) == Data(key.utf8))
            #expect(file(entry.appendingPathComponent("audio-16k.wav")) == Data(repeating: key.utf8.first!, count: 4000))
            let meta = try #require(try await store.entry(contentKey: key))
            #expect(meta.envelope == CacheEnvelope(sampleRate: 44100, frameSeconds: 0.01, count: 16))
            #expect(meta.bytes == 4064)
        }
        for name in ["audio-16k.wav", "envelope-10ms.f32", "meta.json"] {
            #expect(!FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(name).path), "\(name)")
        }
        // A whole-second createdAt survives ProjectJSON exactly; re-encoding a decoded fractional date can move it by under 1 ms.
        var older = try #require(try await store.entry(contentKey: first))
        older.createdAt = Date(timeIntervalSince1970: 1_792_400_000)
        try await store.record(older)
        _ = try await store.extractAudio(sourceURL: source, contentKey: first, durationSeconds: 1, using: RecordingExtractor(wavBytes: 10)) { _ in }
        #expect(try await store.entry(contentKey: first)?.createdAt == older.createdAt)
        await #expect(throws: (any Error).self) {
            _ = try await store.extractAudio(sourceURL: source, contentKey: "../Models", durationSeconds: 1, using: RecordingExtractor()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: locations.root.appendingPathComponent("Models").path))
    }

    @Test func legacyRootFilesGoButNothingElse() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let cache = locations.cache, store = CacheStore(locations: locations)
        let stray = ["audio-16k.wav", "envelope-10ms.f32", "meta.json", "apple-16000-1.caf", "apple-\(UUID().uuidString).caf",
                     "audio-16k-\(UUID().uuidString).partial", "audio-16k.wav.0123abcd.partial", "envelope-10ms.f32.0123abcd.partial",
                     "meta.json.0123abcd.partial"]
        let kept = ["encoders.json", "llm-models.json", "notes.caf", "audio-16k.wav.bak", "apple-.caf"]
        for name in stray + kept { try Data("x".utf8).write(to: cache.appendingPathComponent(name)) }
        let entry = cache.appendingPathComponent(String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: entry.appendingPathComponent("audio-16k.wav"))
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("apple-folder.caf"), withIntermediateDirectories: true)
        let outside = locations.root.appendingPathComponent("outside.caf")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("apple-link.caf"), withDestinationURL: outside)
        await store.removeLegacyRootFiles()
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted() == (kept + ["apple-folder.caf", "apple-link.caf", entry.lastPathComponent]).sorted())
        #expect(FileManager.default.fileExists(atPath: entry.appendingPathComponent("audio-16k.wav").path) && FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func extractionNeverWritesThroughALinkedEntry() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = CacheStore(locations: locations)
        let outside = locations.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = String(repeating: "a", count: 64), file = String(repeating: "b", count: 64), dangling = String(repeating: "c", count: 64)
        try FileManager.default.createSymbolicLink(at: locations.cache.appendingPathComponent(linked), withDestinationURL: outside)
        try Data("x".utf8).write(to: locations.cache.appendingPathComponent(file))
        try FileManager.default.createSymbolicLink(at: locations.cache.appendingPathComponent(dangling), withDestinationURL: locations.root.appendingPathComponent("gone"))
        for key in [linked, file, dangling] {
            await #expect(throws: CocoaError.self) {
                _ = try await store.extractAudio(sourceURL: locations.root, contentKey: key, durationSeconds: 1, using: RecordingExtractor()) { _ in }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: locations.root.appendingPathComponent("gone").path))
    }

    @Test func evictionDropsAudioBeforeEnvelopes() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = CacheStore(locations: locations)
        let keys = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        for key in keys {
            _ = try await store.extractAudio(sourceURL: locations.root, contentKey: key, durationSeconds: 1, using: RecordingExtractor()) { _ in }
            try await Task.sleep(for: .milliseconds(20))
        }
        var total: Int64 = 0
        for key in keys { total += await store.size(locations.cache.appendingPathComponent(key)) }
        try await store.evict(limitBytes: total - 1000, protectedKeys: [])
        let oldest = locations.cache.appendingPathComponent(keys[0])
        #expect(!FileManager.default.fileExists(atPath: oldest.appendingPathComponent("audio-16k.wav").path))
        #expect(file(oldest.appendingPathComponent("envelope-10ms.f32")) == Data(keys[0].utf8))
        #expect(try await store.entry(contentKey: keys[0])?.bytes == 64)
        #expect(FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(keys[1]).appendingPathComponent("audio-16k.wav").path))
        try await store.evict(limitBytes: 1, protectedKeys: [keys[2]])
        #expect(!FileManager.default.fileExists(atPath: oldest.path) && !FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(keys[1]).path))
        #expect(FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent(keys[2]).appendingPathComponent("audio-16k.wav").path))
    }

    /// Metadata whose instant rounds past 9999-12-31T23:59:59.999Z is corrupt: a cache miss that extraction replaces and
    /// eviction removes, never an error (editing.md §10.1).
    @Test(arguments: [("createdAt", "9999-12-31T23:59:59.9995Z"), ("lastAccessAt", "9999-12-31T23:59:59.9999999+00:00")])
    func metadataPastTheLastMillisecondIsAMiss(_ field: String, _ text: String) async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = CacheStore(locations: locations)
        let key = String(repeating: "d", count: 64), entry = locations.cache.appendingPathComponent(key)
        let other = field == "createdAt" ? "lastAccessAt" : "createdAt"
        let meta = Data(#"{"schema": "voxclip-cache/1", "contentKey": "\#(key)", "\#(field)": "\#(text)", "\#(other)": "2026-10-26T21:13:05.123Z", "bytes": 4}"#.utf8)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try meta.write(to: entry.appendingPathComponent("meta.json"))
        #expect(try await store.entry(contentKey: key) == nil)
        _ = try await store.extractAudio(sourceURL: locations.root, contentKey: key, durationSeconds: 1, using: RecordingExtractor()) { _ in }
        let created = try #require(try await store.entry(contentKey: key)).createdAt
        #expect(abs(created.timeIntervalSinceNow) < 60)
        try meta.write(to: entry.appendingPathComponent("meta.json"))
        try await store.evict(limitBytes: 0, protectedKeys: [])
        #expect(!FileManager.default.fileExists(atPath: entry.path))
    }

    @Test func clearCacheKeepsEnvelopesAndTranscriptsUnlessClearingEverything() async throws {
        let locations = try locations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = CacheStore(locations: locations)
        let keys = ["a", "b"].map { String(repeating: $0, count: 64) }
        for key in keys { _ = try await store.extractAudio(sourceURL: locations.root, contentKey: key, durationSeconds: 1, using: RecordingExtractor()) { _ in } }
        let transcripts = locations.cache.appendingPathComponent(keys[0]).appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: transcripts.appendingPathComponent("raw.json"))
        let bare = locations.cache.appendingPathComponent(String(repeating: "c", count: 64))
        try FileManager.default.createDirectory(at: bare.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500).write(to: bare.appendingPathComponent("thumbs/poster.jpg"))
        // An entry from before this fix: paid raw transcripts and a filmstrip, but no envelope and no meta.json.
        let paid = locations.cache.appendingPathComponent(String(repeating: "d", count: 64))
        try FileManager.default.createDirectory(at: paid.appendingPathComponent("transcripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paid.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paid.appendingPathComponent("transcripts/elevenlabs-scribe_v2-auto-00000000.json"))
        try Data(repeating: 1, count: 500).write(to: paid.appendingPathComponent("thumbs/strip-160.jpg"))
        try Data("stray".utf8).write(to: locations.cache.appendingPathComponent("audio-16k.wav"))
        try await store.evict(limitBytes: 0, protectedKeys: [], keepingEnvelopes: true)
        func contents(_ url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
        #expect(try contents(locations.cache.appendingPathComponent(keys[0])) == ["envelope-10ms.f32", "meta.json", "transcripts"])
        #expect(try contents(transcripts) == ["raw.json"])
        #expect(try contents(locations.cache.appendingPathComponent(keys[1])) == ["envelope-10ms.f32", "meta.json"])
        #expect(try await store.entry(contentKey: keys[0])?.bytes == 66)
        #expect(try contents(paid) == ["transcripts"])
        #expect(!FileManager.default.fileExists(atPath: bare.path))
        #expect(!FileManager.default.fileExists(atPath: locations.cache.appendingPathComponent("audio-16k.wav").path))
        try await store.evict(limitBytes: 0, protectedKeys: [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: locations.cache.path).isEmpty)
    }
}
