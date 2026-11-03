#if DEBUG
import Foundation
import Testing
@testable import VoxClipCore

@Suite struct LipsyncRewriteTests {
    struct Vectors: Decodable {
        struct Window: Decodable {
            let id: String
            let seamIn: Int64
            let seamOut: Int64
            let totalSamples: Int64
            let sampleRate: Int
            let phraseID: Int
            let expected: LipsyncWindow
        }
        struct Merge: Decodable {
            let id: String
            let windows: [LipsyncWindow]
            let expected: [LipsyncWindow]
        }
        let schema: String
        let caseCount: Int
        let windows: [Window]
        let merges: [Merge]
    }

    @Test func sharedWindowsMergesAndWindowPricing() async throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/lipsync-window-cases.json"))
        #expect(vectors.schema == "voxclip-lipsync-windows/1")
        #expect(vectors.caseCount == 10 && vectors.caseCount == vectors.windows.count + vectors.merges.count)
        for item in vectors.windows {
            #expect(try LipsyncWindow.make(seamIn: item.seamIn, seamOut: item.seamOut, totalSamples: item.totalSamples,
                sampleRate: item.sampleRate, phraseID: item.phraseID) == item.expected, Comment(rawValue: item.id))
        }
        for item in vectors.merges {
            #expect(try LipsyncWindow.merge(item.windows, sampleRate: 48_000) == item.expected, Comment(rawValue: item.id))
        }
        let provider = try LipsyncProviderFixtures.provider(LipsyncFixtureHTTP([]))
        let overlap = try #require(vectors.merges.first { $0.id == "overlap" })
        let merged = try LipsyncWindow.merge(overlap.windows, sampleRate: 48_000)
        let mergedCost = try await provider.estimate(provider.rewriteModel, seconds: merged[0].seconds(sampleRate: 48_000), fps: 30)
        let single = try await provider.estimate(provider.rewriteModel, seconds: 3, fps: 30)
        #expect(single.usd == Decimal(string: "0.4"))
        #expect(try #require(mergedCost.usd) < #require(single.usd) * 2)
    }

    @Test func faceThresholdAndCrossfadeFrames() {
        #expect(LipsyncFaceCheck.passes(largestFaceHeights: [0.08, 0.2, 0.3, 0.1, 0]))
        #expect(!LipsyncFaceCheck.passes(largestFaceHeights: [0.079, 0.2, 0.3, 0.1, 0]))
        #expect(!LipsyncFaceCheck.passes(largestFaceHeights: []))
        #expect(!LipsyncFaceCheck.passes(largestFaceHeights: [.nan]))
        for frame in 0...3 {
            let weight = LipsyncFrameBlend.weight(time: 1 + Double(frame) / 30, start: 1, end: 3, fps: 30)
            #expect(abs(weight - Double(frame) / 3) < 1e-9)
            let tail = LipsyncFrameBlend.weight(time: 3 - Double(frame) / 30, start: 1, end: 3, fps: 30)
            #expect(abs(tail - Double(frame) / 3) < 1e-9)
        }
        #expect(LipsyncFrameBlend.weight(time: 0.9, start: 1, end: 3, fps: 30) == 0)
        #expect(LipsyncFrameBlend.weight(time: 3.1, start: 1, end: 3, fps: 30) == 0)
    }

    @Test func invalidWindowsFailBeforeAnyTransfer() throws {
        #expect(throws: LipsyncError.invalidInput) {
            try LipsyncWindow.make(seamIn: 0, seamOut: 48_000, totalSamples: 96_000, sampleRate: 48_000, phraseID: 0)
        }
        #expect(throws: LipsyncError.invalidInput) {
            try LipsyncWindow.make(seamIn: 0, seamOut: 48_000 * 301, totalSamples: 48_000 * 305, sampleRate: 48_000, phraseID: 0)
        }
    }
    @Test func renderRouteSupportsLipsync() {
        #expect(VoiceLabRenderInput.supportsVideoMode(.lipsync))
    }

    @Test(arguments: [429, 500, 503]) func explicitRetryableSubmitResponseRetries(status: Int) async throws {
        let root = try LipsyncProviderFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = LipsyncFixtureHTTP([.json(status, "{}"), .json(200, LipsyncProviderFixtures.receipt())])
        let provider = try LipsyncProviderFixtures.provider(http)
        let quote = try await LipsyncProviderFixtures.quote(provider)
        let approval = try await LipsyncProviderFixtures.approval(provider, quote: quote, root: root)
        let job = try await provider.submit(quote, approval: approval)
        #expect(job.remoteID == LipsyncProviderFixtures.requestID)
        #expect(await http.requests.count == 2)
    }
}
#endif
