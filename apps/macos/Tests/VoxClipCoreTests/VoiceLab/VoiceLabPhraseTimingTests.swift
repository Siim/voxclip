import Foundation
import Testing
@testable import VoxClipCore

@Suite("Rewrite phrase timing", .offlineFixtures)
struct VoiceLabPhraseTimingTests {
    @Test func sharedRealPhraseCalibration() throws {
        struct Document: Decodable {
            struct Row: Decodable {
                let id: String
                let text: String
                let rate: Double
                let measuredVoicedSeconds: [Double]
                let expectedSeconds: Double
            }
            let schema: String
            let caseCount: Int
            let cases: [Row]
        }
        let document = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/phrase-timing-cases.json")
        #expect(document.schema == "voxclip-phrase-timing/1" && document.caseCount == 3 && document.cases.count == 3)
        for row in document.cases {
            let estimate = try VoiceLabPhraseTiming.estimate(text: row.text, rate: row.rate)
            #expect(abs(estimate - row.expectedSeconds) < 0.000000001)
            if row.id == "phrase-2" { #expect(abs(estimate / row.measuredVoicedSeconds[0] - 1) <= 0.2) }
            if row.id == "phrase-3" { #expect(estimate >= 1.6) }
            for measured in row.measuredVoicedSeconds { #expect(abs(estimate / measured - 1) <= 0.25) }
        }
    }
    private func window(_ duration: Double, kind: VoiceLabSeamKind = .hard) -> VoiceLabWindow {
        let start = kind == .none ? 0.0 : 10.0
        let end = start + duration
        let first = Int64(EditingPrimitives.jsRound(start * 48_000))
        let last = Int64(EditingPrimitives.jsRound(end * 48_000))
        let fade: Int64 = kind == .none ? 0 : kind == .hard ? 240 : 960
        return VoiceLabWindow(firstWordId: "w0", lastWordId: "w0", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: start, end: end, startSample: first, endSample: last,
            leftSeam: .init(kind: kind, time: start, sample: first, fadeSamples: fade),
            rightSeam: .init(kind: kind, time: end, sample: last, fadeSamples: fade))
    }

    @Test func slowClipAndPunctuationDoNotUseTheOptimisticFloor() throws {
        let words = [TimedWord(id: "a", text: "abcdefghij", start: 1, end: 2),
                     TimedWord(id: "b", text: "abcdefghij", start: 10, end: 11)]
        let rate = try VoiceLabPhraseTiming.speakingRate(transcript: words)
        #expect(rate == 10)
        let text = "then, well, let's get going."
        let timing = try VoiceLabPhraseTiming.measure(text: text, rate: rate, window: window(1.1),
            incomingSilence: nil, outgoingSilence: nil, sourceSampleRate: 48_000)
        #expect(timing.estimateSeconds >= 1.6)
        #expect(!timing.fits)
        #expect(abs(timing.slotSeconds - 1.375) < 0.0001)
        #expect(timing.copy == "≈ 1.7 s · slot 1.4 s")
        let fast = try VoiceLabPhraseTiming.estimate(text: text, rate: 20)
        #expect(timing.estimateSeconds > fast)
        let plain = try VoiceLabPhraseTiming.estimate(text: "then well let's get going", rate: rate)
        #expect(abs(timing.estimateSeconds - plain - 0.46) < 0.0001)
    }

    @Test func slotAndPreflightUseThePaidTakeGate() throws {
        for kind in [VoiceLabSeamKind.hard, .gap, .none] {
            for duration in [0.3, 1.1, 3.0, 8.0] {
                for pause in [0.0, 0.08, 0.3, 0.8] {
                    let source = window(duration, kind: kind)
                    let silence: Double? = kind == .hard ? nil : pause
                    let timing = try VoiceLabPhraseTiming.measure(text: "speech", rate: 10, window: source,
                        incomingSilence: silence, outgoingSilence: silence, sourceSampleRate: 48_000)
                    let fit = try VoiceLabPhraseTiming.preview(seconds: timing.estimateSeconds, window: source,
                        incomingSilence: silence, outgoingSilence: silence, sourceSampleRate: 48_000)
                    let audio = VoiceLabTakeAudio(sampleRate: 48_000, trimmed: [], mixed: [], patchRange: 0..<0,
                        seams: [], gainDb: 0, roomTone: nil, fit: fit)
                    let qa = VoiceLabTakeQAResult(values: VoiceLabQA(speakerScore: 1), failures: [])
                    let row = VoiceLabTakeRow(id: UUID(), index: 0, seed: 0, audio: audio, qa: qa)
                    let paid = VoiceLabVideoDurationOptions(row: row, sourceSampleRate: 48_000)
                    #expect(timing.fits == (paid.allows(.source) || paid.allows(.retimed)))
                    for offset in [-0.01, 0.01] {
                        if timing.slotSeconds <= 0.02 { continue }
                        let length = max(0.1, timing.slotSeconds + offset)
                        let boundary = try VoiceLabPhraseTiming.preview(seconds: length, window: source,
                            incomingSilence: silence, outgoingSilence: silence, sourceSampleRate: 48_000)
                        let gate = VoiceLabVideoDurationOptions(fit: boundary, sourceSampleRate: 48_000, assetSampleRate: 48_000)
                        #expect((gate.allows(.source) || gate.allows(.retimed)) == (offset < 0))
                    }
                }
            }
        }
    }

    @Test func overlappingWordSpansCountOnceAndEventsDoNotCount() throws {
        let words = [TimedWord(id: "a", text: "abcde", start: 0, end: 1),
                     TimedWord(id: "b", text: "abcd", start: 0.5, end: 1.5),
                     TimedWord(id: "c", text: "[laughter]", kind: .event, start: 10, end: 20)]
        #expect(try VoiceLabPhraseTiming.speakingRate(transcript: words) == 6)
    }

    @Test func scopeFeedbackRequiresItsOwnQuoteAndKeepsSeparateByteLimits() async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let service = PatchRewriteService(shared: shared)
        let entries = [ClipWord(index: 1, text: "Go.", start: 0, end: 1)]
        let ranges = [PatchRewriteLineRange(line: "[1-1]", minChars: 1, maxChars: 20)]
        let identity = UUID()
        func input(_ feedback: String?, instruction: String = "Keep my tone.") -> PatchRewriteRequest {
            PatchRewriteRequest(id: identity, entries: entries, ranges: ranges, instruction: instruction, language: "en", feedback: feedback)
        }
        let stale = try await service.prepare(input(nil), connector: .openai, model: "selected-model")
        let feedback = String(repeating: "Shorter words. ", count: 100)
        let connector = CapturingRewriteConnector(output: #"{"edits":[]}"#)
        await #expect(throws: VoiceLabError.self) {
            _ = try await service.propose(input(feedback), connector: connector, model: "selected-model",
                authorization: PatchRewriteAuthorization(quote: stale, approved: true))
        }
        #expect(await connector.requests.isEmpty)
        let quote = try await service.prepare(input(feedback), connector: .openai, model: "selected-model")
        _ = try await service.propose(input(feedback), connector: connector, model: "selected-model",
            authorization: PatchRewriteAuthorization(quote: quote, approved: true))
        #expect(await connector.requests.last?.instruction.hasSuffix(feedback) == true)
        await #expect(throws: VoiceLabError.self) {
            _ = try await service.prepare(input(String(repeating: "a", count: 20_001)), connector: .openai, model: "selected-model")
        }
        await #expect(throws: VoiceLabError.self) {
            _ = try await service.prepare(input(nil, instruction: String(repeating: "a", count: 1_001)), connector: .openai, model: "selected-model")
        }
    }

    @Test func shorteningFeedbackIsBoundToEachFreshQuote() async throws {
        let shared = SharedResources(root: try FixtureLoader.sharedRoot())
        let service = VoiceRewriteService(shared: shared)
        let words = [TimedWord(id: "w1", text: "and let's go.", start: 0, end: 1.1)]
        let feedback = "SHORTER WORDING FEEDBACK:\nOriginal words: and let's go.\nProposed words: then, well, let's get going.\nSay it in fewer words; keep the other changes as they are."
        let original = VoiceRewriteRequest(id: UUID(), scope: .passage, sourceWords: words,
            instruction: "Keep my casual tone.", language: "en", targetSeconds: 1.1, minChars: 1, maxChars: 40)
        let shorter = VoiceRewriteRequest(id: original.id, scope: .passage, sourceWords: words,
            instruction: original.instruction, language: "en", targetSeconds: 1.1, minChars: 1, maxChars: 40, feedback: feedback)
        let stale = try await service.prepare(original, connector: .openai, model: "selected-model")
        let connector = CapturingRewriteConnector(output: "{\"rewrite\":\"Let's go.\"}")
        await #expect(throws: VoiceLabError.self) {
            _ = try await service.propose(shorter, connector: connector, model: "selected-model",
                authorization: VoiceRewriteAuthorization(quote: stale, approved: true))
        }
        #expect(await connector.requests.isEmpty)
        let quote = try await service.prepare(shorter, connector: .openai, model: "selected-model")
        _ = try await service.propose(shorter, connector: connector, model: "selected-model",
            authorization: VoiceRewriteAuthorization(quote: quote, approved: true))
        let request = try #require(await connector.requests.last)
        #expect(request.instruction.hasSuffix(feedback))
    }
}
