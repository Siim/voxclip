import AVFoundation
import Darwin
import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// MVP46 (2026-11-08): the first two real fal.ai sync-3 jobs were billed and thrown away. fal.ai's own example comes back
/// 5 frames short at the end (135 → 130 frames at 24 fps) with a separate 24 kHz AAC track, and the importer refused it.
/// Uploads now carry a tail margin; the import cuts the result back to the voice's length from its start.
@Suite("Lip-sync result length", .serialized, .timeLimit(.minutes(2)), .offlineFixtures)
struct LipsyncResultLengthTests {
    private let projectID = LipsyncImportFixture.projectID
    /// fal.ai's example window: 135 frames at 24 fps.
    private let needed = 135.0 / 24

    private func run(_ root: URL, frames: Int, audioSeconds: Double? = 5.248, model index: Int = 3, mode: SyncMode = .cutOff,
                     uploaded: Double? = nil, log: LipsyncImportLog = LipsyncImportLog())
        async throws -> (LipsyncImportHTTP, FalLipsyncProvider, LipsyncQuote, LipsyncJob) {
        let result = root.appendingPathComponent("fal-shaped-\(UUID().uuidString).mp4")
        try await FalShapedResult.write(to: result, frames: frames, fps: 24, audioSeconds: audioSeconds)
        let http = LipsyncImportHTTP(bytes: try Data(contentsOf: result), app: "fal-ai/sync-lipsync")
        try FileManager.default.removeItem(at: result)
        let provider = try LipsyncImportFixture.provider(http: http, logger: log)
        let (quote, job) = try await LipsyncImportFixture.submit(root: root, provider: provider, model: provider.models[index],
            seconds: uploaded ?? LipsyncLimits.uploadSeconds(needed), fps: 24, syncMode: mode)
        return (http, provider, quote, job)
    }

    private func importResult(_ provider: FalLipsyncProvider, _ job: LipsyncJob, _ quote: LipsyncQuote, root: URL) async throws -> ImportedLipsyncResult {
        try await LipsyncResultImporter().importResult(provider: provider, job: job, quote: quote, neededSeconds: needed,
                                                       projectID: projectID, paidRoot: root, sourceWidth: 320, sourceHeight: 180)
    }

    private func attempts(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("\(projectID)/lipsync-attempts").path).sorted()) ?? []
    }

    /// The phrase path (sync-3, cut_off) and the whole-clip path (lipsync-2, remap) both import the example's shape: sent
    /// with the margin, it comes back 5 frames short of the upload and is cut back to the voice's length from its start.
    @Test(arguments: [(3, SyncMode.cutOff), (1, SyncMode.remap)])
    func anExampleShapedResultImports(model index: Int, mode: SyncMode) async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = LipsyncImportLog()
        let uploadFrames = Int((LipsyncLimits.uploadSeconds(needed) * 24).rounded(.up))
        let (http, provider, quote, job) = try await run(root, frames: uploadFrames - 5, audioSeconds: 5.8, model: index, mode: mode, log: log)
        // Both modes expect the whole upload back: the video and the audio are the same length, margin included.
        #expect(abs(quote.outputDurationSeconds - LipsyncLimits.uploadSeconds(needed)) < 1e-9)
        let imported = try await importResult(provider, job, quote, root: root)
        #expect(abs(imported.asset.durationSeconds - needed) <= 1.0 / 24)
        let (count, levels) = try await FalShapedResult.frames(imported.url)
        #expect(count == 135)
        // Frames are aligned at the start: stored frame k is fal.ai's frame k.
        #expect(abs(Int(levels[0]) - Int(FalShapedResult.level(0))) <= 6)
        #expect(abs(Int(levels[134]) - Int(FalShapedResult.level(134))) <= 6)
        #expect(await http.submits == 1)
        #expect(await http.deletions == 1)
        #expect(attempts(root).isEmpty)
        let line = await log.lines.first { $0.hasPrefix("lipsync result check=duration") }
        #expect(line == "lipsync result check=duration got=5.833 expected=5.625 uploaded=6.025 fps=24 short_frames=0 dropped_frames=5 outcome=trim")
    }

    /// fal.ai's audio is never used: the result's 24 kHz AAC track is dropped and the stored picture has no audio; the take
    /// keeps our own voice (the render takes only the picture from a lip-sync asset).
    @Test func falAudioIsDropped() async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let uploadFrames = Int((LipsyncLimits.uploadSeconds(needed) * 24).rounded(.up))
        let (_, provider, quote, job) = try await run(root, frames: uploadFrames - 5, audioSeconds: 5.248)
        let imported = try await importResult(provider, job, quote, root: root)
        let tracks = try await AVURLAsset(url: imported.url).load(.tracks)
        #expect(tracks.filter { $0.mediaType == .audio }.isEmpty)
        #expect(tracks.filter { $0.mediaType == .video }.count == 1)
        #expect(try await LipsyncResultValidation.inspect(file: imported.url).hasAudio == false)
    }

    /// A result short of the voice by at most `LipsyncLimits.heldFrames` holds its last frame.
    @Test func aFewFramesShortHoldsTheLastFrame() async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, provider, quote, job) = try await run(root, frames: 132, uploaded: needed)
        let imported = try await importResult(provider, job, quote, root: root)
        let (count, levels) = try await FalShapedResult.frames(imported.url)
        #expect(count == 135)
        for frame in 131...134 { #expect(abs(Int(levels[frame]) - Int(FalShapedResult.level(131))) <= 6) }
    }

    /// Shorter than the hold allows: `check=duration` with its numbers, the paid file and its request ID are kept, and Try
    /// Again re-imports the kept file at no cost (no second submit).
    @Test func tooShortFailsNamedKeepsTheResultAndRetriesFree() async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = LipsyncImportLog()
        let (http, provider, quote, job) = try await run(root, frames: 130, uploaded: needed, log: log)
        var thrown: LipsyncAttemptFailure?
        do { _ = try await importResult(provider, job, quote, root: root) } catch let failure as LipsyncAttemptFailure { thrown = failure }
        let failure = try #require(thrown)
        let check = try #require(failure.error as? LipsyncResultCheck)
        #expect(check.name == .duration && failure.freeRetry)
        #expect(check.logLine == "lipsync result check=duration got=5.417 expected=5.625 uploaded=5.625 fps=24 short_frames=5 dropped_frames=5 outcome=short")
        #expect(check.copy == "fal.ai's video came back 0.2 s shorter than the voice.")
        #expect(await log.lines.contains(check.logLine))
        // The paid result and its request ID stay in the project's paid folder, private; never a URL.
        let key = "\(quote.video.sha256)-\(quote.audio.sha256)"
        #expect(attempts(root) == ["\(key).json", "\(key).mp4"])
        let folder = root.appendingPathComponent("\(projectID)/lipsync-attempts")
        for name in attempts(root) {
            let mode = try #require(FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.posixPermissions] as? Int)
            #expect(mode == 0o600)
        }
        let record = try String(contentsOf: folder.appendingPathComponent("\(key).json"), encoding: .utf8)
        #expect(record.contains(job.remoteID))
        #expect(record.contains(#"fal-ai\/sync-lipsync\/v3"#))
        #expect(!record.contains("https"))
        let attempt = try #require(LipsyncAttemptStore.load(videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256,
                                                            projectID: projectID, paidRoot: root))
        #expect(attempt.keptResult && attempt.requestID == job.remoteID && attempt.neededSeconds == needed)
        // fal.ai's copy goes once VoxClip has the file.
        #expect(await http.deletions == 1)
        // Try Again: the kept file again, for free. It is still too short, so it stays kept and the next Try Again is priced.
        let fetches = await http.resultFetches
        await #expect(throws: LipsyncAttemptFailure.self) {
            _ = try await LipsyncResultImporter().importRecovered(attempt, provider: provider, projectID: projectID, paidRoot: root,
                                                                  sourceWidth: 320, sourceHeight: 180)
        }
        #expect(await http.submits == 1)
        #expect(await http.resultFetches == fetches)
        #expect(await http.downloads == 1)
        #expect(attempts(root) == ["\(key).json", "\(key).mp4"])
    }

    /// A restart with a fixed build finds the sidecar: the kept result imports for free and the attempt is finished.
    @Test func aKeptResultFromAnEarlierRunImportsForFree() async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let uploadFrames = Int((LipsyncLimits.uploadSeconds(needed) * 24).rounded(.up))
        let (http, provider, quote, job) = try await run(root, frames: uploadFrames - 5)
        let attempt = LipsyncAttempt(job: job, quote: quote, neededSeconds: needed)
        try LipsyncAttemptStore.record(attempt, projectID: projectID, paidRoot: root)
        let earlier = root.appendingPathComponent("\(projectID)/earlier.mp4")
        try await FalShapedResult.write(to: earlier, frames: uploadFrames - 5, fps: 24, audioSeconds: 5.248)
        try LipsyncAttemptStore.keep(earlier, for: attempt, projectID: projectID, paidRoot: root)
        let kept = try #require(LipsyncAttemptStore.load(videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256,
                                                         projectID: projectID, paidRoot: root))
        let imported = try await LipsyncResultImporter().importRecovered(kept, provider: provider, projectID: projectID, paidRoot: root,
                                                                        sourceWidth: 320, sourceHeight: 180)
        #expect(imported.recovered && imported.provenance.requestID == job.remoteID)
        #expect(abs(imported.asset.durationSeconds - needed) <= 1.0 / 24)
        #expect(await http.submits == 1)
        #expect(await http.downloads == 0)
        #expect(attempts(root).isEmpty)
    }

    /// A download that fails leaves fal.ai's copy (no payload delete), and Try Again fetches the result again by request ID,
    /// for free, then deletes it at fal.ai.
    @Test func aFailedDownloadIsFetchedAgainByRequestID() async throws {
        let root = try LipsyncImportFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let uploadFrames = Int((LipsyncLimits.uploadSeconds(needed) * 24).rounded(.up))
        let (http, provider, quote, job) = try await run(root, frames: uploadFrames - 5)
        try LipsyncAttemptStore.record(LipsyncAttempt(job: job, quote: quote, neededSeconds: needed), projectID: projectID, paidRoot: root)
        await http.failDownloads(true)
        var thrown: LipsyncAttemptFailure?
        do { _ = try await importResult(provider, job, quote, root: root) } catch let failure as LipsyncAttemptFailure { thrown = failure }
        #expect(thrown?.freeRetry == true)
        #expect(thrown?.error as? LipsyncError == .network)
        #expect(await http.deletions == 0)
        await http.failDownloads(false)
        let attempt = try #require(LipsyncAttemptStore.load(videoSHA256: quote.video.sha256, audioSHA256: quote.audio.sha256,
                                                            projectID: projectID, paidRoot: root))
        #expect(!attempt.keptResult)
        let imported = try await LipsyncResultImporter().importRecovered(attempt, provider: provider, projectID: projectID, paidRoot: root,
                                                                        sourceWidth: 320, sourceHeight: 180)
        #expect(imported.recovered)
        let requests = await http.requests
        let refetch = try #require(requests.last { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/status") == false })
        #expect(refetch.url?.absoluteString == "https://queue.fal.run/fal-ai/sync-lipsync/requests/\(job.remoteID)")
        #expect(refetch.value(forHTTPHeaderField: "Authorization") == "Key synthetic-import-fixture-key")
        #expect(await http.submits == 1)
        #expect(await http.deletions == 1)
        #expect(attempts(root).isEmpty)
    }
}
