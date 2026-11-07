import Foundation
import Testing
import VoxClipCore
import VoxClipMedia

/// ADR-R48: `voxclip-cli analyze-frames` prints a clip's analysis, the decisions and the timings, caches the analysis
/// in the data folder's cache and leaves the project as it was.
@Suite("Analyze-frames CLI", .offlineFixtures)
struct CLIAnalyzeFramesTests {
    @Test(.timeLimit(.minutes(1)))
    func printsTheAnalysisAndUsesTheCacheTheSecondTime() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures/media/counter-1080p.mp4")
        let probe = try await AVMediaProbe().probe(source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let transcript = Transcript(words: [
            TimedWord(id: "w1", text: "One", start: 0.8, end: 1.0), TimedWord(id: "w2", text: "two.", start: 1.1, end: 1.4),
            TimedWord(id: "w3", text: "Three", start: 2.0, end: 2.3), TimedWord(id: "w4", text: "four.", start: 2.4, end: 2.8)],
            durationSeconds: 4, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
            rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        let contentKey = try JSONProjectStore.contentKey(for: source)
        let project = Project(id: UUID().uuidString.lowercased(), createdAt: Date(), modifiedAt: Date(), savedBy: ProjectWriter(version: "9.8.7"),
            media: ProjectMedia(source: MediaReference(absolutePath: source.path, sizeBytes: try #require((attributes[.size] as? NSNumber)?.int64Value),
                durationSeconds: probe.durationSeconds, contentKey: contentKey, video: probe.video, audio: probe.audio)),
            transcript: transcript, edits: ProjectEdits(clips: [ClipRange(id: "c", startWordId: "w1", endWordId: "w4")]))
        let input = directory.appendingPathComponent("frames.voxclip")
        let original = try ProjectJSON.encode(project)
        try original.write(to: input)

        let first = try runCLI(["analyze-frames", "--open", input.path, "--clip", "c", "--json"], directory: directory)
        #expect(first.status == 0)
        let output = try first.json
        #expect(output["ok"] as? Bool == true && output["command"] as? String == "analyze-frames")
        let analysis = try #require(output["analysis"] as? [String: Any])
        #expect((analysis["sentences"] as? [Any])?.count == 2)
        #expect((analysis["opening"] as? [Any])?.count == 13)
        let timings = try #require(analysis["timings"] as? [String: Any])
        #expect(timings["analyzedFrames"] as? Int == 15 && timings["cachedFrames"] as? Int == 0)
        let decisions = try #require(output["decisions"] as? [String: Any])
        #expect(Set(decisions.keys) == ["opening", "cover", "blurSpans", "blurCandidates", "coverCandidates", "crop9x16", "crop1x1"])
        let sheet = try #require(output["sheet"] as? [String: Any])
        #expect(sheet["frames"] as? Int == 2 && sheet["estimatedImageTokens"] as? Int == 2 * 77)
        let frames = directory.appendingPathComponent("data/Cache/\(contentKey)/frames/analysis-v1.json")
        #expect(FileManager.default.fileExists(atPath: frames.path))

        let second = try runCLI(["analyze-frames", "--open", input.path, "--clip", "c", "--json"], directory: directory)
        let cached = try #require((try second.json["analysis"] as? [String: Any])?["timings"] as? [String: Any])
        #expect(cached["analyzedFrames"] as? Int == 0 && cached["cachedFrames"] as? Int == 15)
        #expect(try Data(contentsOf: input) == original)

        let missing = try runCLI(["analyze-frames", "--open", input.path, "--clip", "nope", "--json"], directory: directory)
        #expect(missing.status != 0)
    }

    /// `--video-pass` (ADR-R48 part 2) times the whole video's sentence pass, the clip's frames from it and its opening; a media
    /// file opens with fixture words and a word range, without a project.
    @Test(.timeLimit(.minutes(1)))
    func timesTheVideoPassOnAMediaFileWithFixtureWords() async throws {
        let directory = try cliDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try FixtureLoader.sharedRoot().appendingPathComponent("fixtures/media/counter-1080p.mp4")
        let transcript = Transcript(words: [
            TimedWord(id: "w1", text: "One", start: 0.8, end: 1.0), TimedWord(id: "w2", text: "two.", start: 1.1, end: 1.4),
            TimedWord(id: "w3", text: "Three", start: 2.0, end: 2.3), TimedWord(id: "w4", text: "four.", start: 2.4, end: 2.8)],
            durationSeconds: 4, engine: EngineRef(id: .elevenlabs, engineVersion: "synthetic-fixture"),
            rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
        let words = directory.appendingPathComponent("words.json")
        try ProjectJSON.encoder().encode(transcript).write(to: words)
        let result = try runCLI(["analyze-frames", "--open", source.path, "--transcript", words.path, "--words", "2:3", "--video-pass", "--json"],
                                directory: directory)
        #expect(result.status == 0, "\(result.stderr)")
        let output = try result.json
        let pass = try #require(output["videoPass"] as? [String: Any])
        #expect(pass["read"] as? Bool == true && pass["frames"] as? Int == 2 && pass["analyzed"] as? Int == 2)
        #expect(pass["clipFrames"] as? Int == 1 && pass["openingFrames"] as? Int == 13)
        #expect((pass["seconds"] as? Double ?? -1) >= 0 && (pass["openingSeconds"] as? Double ?? -1) >= 0)
        // The clip's own analysis then reads the pass's frames from the cache.
        let timings = try #require((output["analysis"] as? [String: Any])?["timings"] as? [String: Any])
        #expect(timings["cachedFrames"] as? Int == 14 && timings["analyzedFrames"] as? Int == 0)
        #expect(output["clipStart"] as? Double ?? 0 > 1.4)
        let refused = try runCLI(["analyze-frames", "--open", source.path, "--transcript", words.path, "--json"], directory: directory)
        #expect(refused.status != 0)
    }
}
