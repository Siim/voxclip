#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

/// MVP46 (2026-11-08): fal.ai's sync-3 keeps the start and drops frames at the end (its own example: 135 frames in, 130
/// out at 24 fps), so every upload carries a tail margin and the import cuts the result back to the voice's length.
@Suite("Lip-sync tail margin and result length", .offlineFixtures)
struct LipsyncResultLengthRuleTests {
    private typealias Fixtures = LipsyncProviderFixtures

    @Test func theMarginIsTheLargerOfFourTenthsAndTwoPercent() {
        #expect(LipsyncLimits.tailMarginSeconds(5.625) == 0.4)
        #expect(LipsyncLimits.tailMarginSeconds(20) == 0.4)
        #expect(abs(LipsyncLimits.tailMarginSeconds(25.92) - 0.5184) < 1e-12)
        #expect(abs(LipsyncLimits.uploadSeconds(60) - 61.2) < 1e-12)
        #expect(LipsyncLimits.heldFrames == 3)
    }

    @Test func aWindowWhoseUploadPassesFiveMinutesIsRefused() throws {
        let rate = 48_000.0
        let piece = VoiceLabOutputPiece(kind: .source, sourceStartSample: 0, sourceEndSample: Int64(400 * rate), outputStartSample: 0,
            outputEndSample: Int64(400 * rate), segmentId: nil, assetId: nil, audio: nil)
        let plan = VoiceLabOutputPlan(sampleRate: rate, totalSourceSamples: Int64(400 * rate), pieces: [piece], captions: [], scope: .full)
        let fits = LipsyncWindow(startSample: 0, endSample: Int64(294 * rate), phraseIDs: [0])
        #expect(try LipsyncRenderWindow(source: fits, plan: plan).uploadSeconds(sampleRate: rate) <= 300)
        let tooLong = LipsyncWindow(startSample: 0, endSample: Int64(295 * rate), phraseIDs: [0])
        #expect(throws: LipsyncError.invalidInput) { _ = try LipsyncRenderWindow(source: tooLong, plan: plan) }
    }

    /// The needed length is the voice's; what was sent is that and the margin.
    @Test func lengthOutcomes() {
        let needed = 135.0 / 24, uploaded = LipsyncLimits.uploadSeconds(needed)
        func outcome(_ frames: Int, uploaded sent: Double = uploaded) -> LipsyncResultLength.Outcome {
            LipsyncResultLength(got: Double(frames) / 24, needed: needed, uploaded: sent, fps: 24).outcome
        }
        #expect(outcome(140) == .trim)                         // fal.ai's 5-frame drop, absorbed by the margin
        #expect(outcome(135) == .trim)
        #expect(outcome(145) == .trim)                         // the whole upload back (its last frame rounded up)
        #expect(outcome(146) == .long)                         // more than a frame past the 6.025 s sent
        #expect(outcome(134) == .hold(frames: 1))
        #expect(outcome(132) == .hold(frames: 3))
        #expect(outcome(131) == .short(frames: 4))
        #expect(outcome(130, uploaded: needed) == .short(frames: 5))   // MVP46: no margin, 5 frames short
    }

    @Test func theDurationCheckSaysItsNumbersAndWhatHappened() {
        let short = LipsyncResultLength(got: 25.75, needed: 25.92, uploaded: 25.92, fps: 30)
        #expect(short.logLine == "lipsync result check=duration got=25.75 expected=25.92 uploaded=25.92 fps=30 short_frames=5 dropped_frames=5 outcome=short")
        let check = LipsyncResultCheck.duration(short)
        #expect(check.name == .duration && check.logLine == short.logLine)
        #expect(check.copy == "fal.ai's video came back 0.2 s shorter than the voice.")
        let long = LipsyncResultCheck.duration(LipsyncResultLength(got: 28, needed: 25.92, uploaded: 26.44, fps: 30))
        #expect(long.copy == "fal.ai's video came back 1.6 s longer than what was sent.")
        let size = LipsyncResultCheck.size(width: 1280, height: 720, expectedWidth: 1920, expectedHeight: 1080)
        #expect(size.logLine == "lipsync result check=size got=1280x720 expected=1920x1080")
        #expect(!size.logLine.contains("http") && !check.logLine.contains("/"))
    }

    /// cut_off expects min(video, audio) and remap the audio's length: with the margin on both, both are the upload.
    @Test(arguments: [SyncMode.cutOff, .remap]) func bothModesExpectTheWholeUploadBack(mode: SyncMode) async throws {
        let provider = try Fixtures.provider(LipsyncFixtureHTTP([]))
        let upload = LipsyncLimits.uploadSeconds(25.92)
        let quote = try await provider.quote(model: provider.models[3], video: Fixtures.input(seconds: upload),
                                             audio: Fixtures.input(video: false, seconds: upload), options: .init(syncMode: mode), fps: 30)
        #expect(quote.outputDurationSeconds == upload)
        #expect(quote.estimate.units == upload)
    }

    /// fal.ai's documented payload-delete response (Platform API, `DELETE /v1/models/requests/{id}/payloads`) is confirmed.
    @Test func theDocumentedPayloadDeleteIsConfirmed() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let documented = """
            {"cdn_delete_results":[{"link":"https://v3.fal.media/files/abc123/output.png","exception":null},\
            {"link":"https://v3.fal.media/files/def456/output.mp4","exception":null}]}
            """
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .json(200, Fixtures.completed), .json(200, Fixtures.output), .json(200, documented)])
        let provider = try Fixtures.provider(http), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root), job = try await provider.submit(quote, approval: approval)
        _ = try await provider.poll(job)
        await provider.cleanup(job)
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .completed)
        let delete = try #require(await http.requests.first { $0.httpMethod == "DELETE" })
        #expect(delete.url?.absoluteString == "https://api.fal.ai/v1/models/requests/\(job.remoteID)/payloads")
        #expect(delete.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Key ") == true)
    }

    /// An unconfirmed delete says why in the log (the status, never the body, a URL or the key): a key without fal.ai's
    /// `models:requests:write` and `assets:write` permissions gets 403.
    @Test func anUnconfirmedDeleteLogsItsStatus() async throws {
        let root = try Fixtures.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let log = LipsyncFixtureLog()
        let denied = #"{"error":{"type":"authorization_error","message":"private-provider-body-detail"}}"#
        let http = LipsyncFixtureHTTP([.json(200, Fixtures.receipt()), .json(200, Fixtures.completed), .json(200, Fixtures.output), .json(403, denied)])
        let provider = try Fixtures.provider(http, logger: log), quote = try await Fixtures.quote(provider)
        let approval = try await Fixtures.approval(provider, quote: quote, root: root), job = try await provider.submit(quote, approval: approval)
        _ = try await provider.poll(job)
        await provider.cleanup(job)
        #expect(await provider.status(quoteID: quote.id)?.cleanup == .failed)
        let messages = await log.messages
        #expect(messages.contains("lipsync provider=fal event=cleanup-unconfirmed status=403"))
        #expect(!messages.joined().contains("private-provider-body-detail"))
    }
}
#endif
