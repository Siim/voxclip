import Foundation
import Testing
@testable import VoxClipCore

/// voice-lab.md §6.5.1 and §15 test 20: the shared training-span vectors, compared exactly.
@Suite struct VoiceTrainingSpansTests {
    private struct Vectors: Decodable {
        struct Constants: Decodable, Equatable {
            let minConf: Double, maxGapMs: Int, spanMinMs: Int, spanMaxMs: Int
            let voicedDb: Double, minSnrDb: Double, totalMinMs: Int, totalMaxMs: Int
        }
        struct Item: Decodable { let kind: WordKind; let start: Double; let end: Double; let conf: Double?; let speaker: String?; let synthetic: Bool }
        struct Span: Decodable { let startMs: Int; let endMs: Int; let snrDb: Double }
        struct Rejection: Decodable { let startMs: Int; let endMs: Int; let reason: String; let snrDb: Double? }
        struct Expected: Decodable {
            let status: String; let availableMs: Int; let selectedMs: Int; let preferredMs: Int
            let selected: [Span]; let qualifying: [Span]; let rejected: [Rejection]
        }
        struct Case: Decodable {
            let id: String; let duration: Double; let items: [Item]; let excluded: [[Double]]; let preferRange: [Double]?
            let frames: [[Double]]; let expected: Expected
        }
        let schema: String
        let constants: Constants
        let cases: [Case]
    }
    private func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/training-spans.json"))
    }

    @Test func constantsMatchTheSharedVectors() throws {
        let vectors = try vectors()
        #expect(vectors.schema == "voxclip-voice-lab-training-spans/1")
        #expect(vectors.constants == .init(minConf: VoiceTrainingSpans.TRAIN_MIN_CONF, maxGapMs: VoiceTrainingSpans.TRAIN_MAX_GAP,
            spanMinMs: VoiceTrainingSpans.TRAIN_SPAN_MIN, spanMaxMs: VoiceTrainingSpans.TRAIN_SPAN_MAX, voicedDb: VoiceTrainingSpans.TRAIN_VOICED,
            minSnrDb: VoiceTrainingSpans.TRAIN_MIN_SNR, totalMinMs: VoiceTrainingSpans.TRAIN_TOTAL_MIN, totalMaxMs: VoiceTrainingSpans.TRAIN_TOTAL_MAX))
        #expect(vectors.cases.map(\.id) == ["happy-path", "low-confidence-split", "event-inside", "two-speakers", "synthetic-excluded", "low-snr-rejected",
            "long-run-split-at-pauses", "unsplittable-run-and-30-second-span", "cap-120-seconds", "below-minimum", "snr-percentiles", "empty-transcript",
            "prefer-fills-cap", "prefer-below-cap-filled-from-other", "prefer-partial-overlap", "prefer-overlap-at-end", "prefer-no-qualifying-span",
            "prefer-ties-across-groups", "prefer-below-minimum"])
        // The original twelve cases have no preferRange: their selection is the unpreferred one.
        #expect(vectors.cases.filter { $0.preferRange == nil }.count == 12)
    }

    @Test func everySharedCaseMatchesExactly() throws {
        for vector in try vectors().cases {
            let items = vector.items.map { VoiceTrainingItem(kind: $0.kind, start: $0.start, end: $0.end, conf: $0.conf, speaker: $0.speaker, synthetic: $0.synthetic) }
            let excluded = try vector.excluded.map { pair in
                try #require(pair.count == 2, Comment(rawValue: vector.id))
                return VoiceTrainingRange(start: pair[0], end: pair[1])
            }
            let preferRange = try vector.preferRange.map { pair in
                try #require(pair.count == 2, Comment(rawValue: vector.id))
                return VoiceTrainingRange(start: pair[0], end: pair[1])
            }
            var frames: [Double] = []
            for pair in vector.frames { frames.append(contentsOf: repeatElement(pair[1], count: Int(pair[0]))) }
            let result = try VoiceTrainingSpans.select(items: items, excluded: excluded, frameDb: frames, duration: vector.duration, preferRange: preferRange)
            let expected = vector.expected
            let comment = Comment(rawValue: vector.id)
            #expect(result.status.rawValue == expected.status, comment)
            #expect(result.availableMs == expected.availableMs, comment)
            #expect(result.selectedMs == expected.selectedMs, comment)
            #expect(result.preferredMs == expected.preferredMs, comment)
            #expect(result.selected == expected.selected.map { VoiceTrainingSpan(startMs: $0.startMs, endMs: $0.endMs, snrDb: $0.snrDb) }, comment)
            #expect(result.qualifying == expected.qualifying.map { VoiceTrainingSpan(startMs: $0.startMs, endMs: $0.endMs, snrDb: $0.snrDb) }, comment)
            #expect(result.rejected.map(\.reason.rawValue) == expected.rejected.map(\.reason), comment)
            #expect(result.rejected.map { [$0.startMs, $0.endMs] } == expected.rejected.map { [$0.startMs, $0.endMs] }, comment)
            #expect(result.rejected.map(\.snrDb) == expected.rejected.map(\.snrDb), comment)
        }
    }

    @Test func aRangeOverTheWholeTakeOrOutsideEverySpanPicksWhatNoRangePicks() throws {
        for vector in try vectors().cases {
            let items = vector.items.map { VoiceTrainingItem(kind: $0.kind, start: $0.start, end: $0.end, conf: $0.conf, speaker: $0.speaker, synthetic: $0.synthetic) }
            let excluded = vector.excluded.map { VoiceTrainingRange(start: $0[0], end: $0[1]) }
            var frames: [Double] = []
            for pair in vector.frames { frames.append(contentsOf: repeatElement(pair[1], count: Int(pair[0]))) }
            func select(_ range: VoiceTrainingRange?) throws -> VoiceTrainingSpanSelection {
                try VoiceTrainingSpans.select(items: items, excluded: excluded, frameDb: frames, duration: vector.duration, preferRange: range)
            }
            let comment = Comment(rawValue: vector.id)
            let plain = try select(nil)
            var whole = try select(VoiceTrainingRange(start: 0, end: vector.duration))
            #expect(whole.preferredMs == plain.selectedMs, comment)
            whole.preferredMs = 0
            #expect(whole == plain, comment)
            #expect(try select(VoiceTrainingRange(start: vector.duration, end: vector.duration)) == plain, comment)
        }
    }

    @Test func nonFiniteAndInvertedInputsAreRefused() {
        let word = VoiceTrainingItem(start: 1, end: 7)
        let frames = [Double](repeating: -20, count: 1_000)
        let cases: [(items: [VoiceTrainingItem], excluded: [VoiceTrainingRange], frames: [Double], duration: Double)] = [
            ([VoiceTrainingItem(start: .nan, end: 7)], [], frames, 10),
            ([VoiceTrainingItem(start: 1, end: .infinity)], [], frames, 10),
            ([VoiceTrainingItem(kind: .event, start: 1, end: 7, conf: .nan)], [], frames, 10),
            ([word], [VoiceTrainingRange(start: .nan, end: 2)], frames, 10),
            ([word], [VoiceTrainingRange(start: 3, end: 2)], frames, 10),
            ([word], [], frames + [.nan], 10),
            ([word], [], frames + [-.infinity], 10),
            ([word], [], frames, -0.001),
            ([word], [], frames, .infinity),
            ([VoiceTrainingItem(start: 1, end: 1e300)], [], frames, 10),
        ]
        for (index, value) in cases.enumerated() {
            #expect(throws: VoiceLabError.invalidInput, Comment(rawValue: "case \(index)")) {
                try VoiceTrainingSpans.select(items: value.items, excluded: value.excluded, frameDb: value.frames, duration: value.duration)
            }
        }
        #expect(throws: Never.self) { try VoiceTrainingSpans.select(items: [word], excluded: [VoiceTrainingRange(start: 2, end: 2)], frameDb: [], duration: 0) }
        let preferRanges = [VoiceTrainingRange(start: .nan, end: 2), VoiceTrainingRange(start: 1, end: .infinity), VoiceTrainingRange(start: -.infinity, end: 2),
                            VoiceTrainingRange(start: 3, end: 2), VoiceTrainingRange(start: 1, end: 1e300)]
        for (index, range) in preferRanges.enumerated() {
            #expect(throws: VoiceLabError.invalidInput, Comment(rawValue: "preferRange \(index)")) {
                try VoiceTrainingSpans.select(items: [word], excluded: [], frameDb: frames, duration: 10, preferRange: range)
            }
        }
    }

    @Test func projectInputsMarkEveryVoiceLabRangeAndKeepSourceTimes() throws {
        var project = try JSONProjectStore.decode(FixtureLoader.data("fixtures/voice-lab/passage-project.voxclip"))
        let words = try #require(project.transcript?.words)
        var disabled = project.voiceLab.segments[0]
        disabled.id = "disabled-segment"; disabled.enabled = false
        disabled.replace = VoiceLabReplacement(start: 5.4, end: 6.0, firstWordId: "w9", lastWordId: "w9")
        project.voiceLab.segments.append(disabled)
        project.edits.cutWordIds = ["w1", "w2", "w3"]; project.edits.corrections = ["w8": "changed"]
        let inputs = VoiceTrainingSpans.inputs(project: project)
        #expect(inputs.items.count == words.count)
        #expect(inputs.items.map(\.start) == words.map(\.start) && inputs.items.map(\.end) == words.map(\.end))
        #expect(inputs.items.map(\.conf) == words.map(\.conf) && inputs.items.map(\.speaker) == words.map(\.speaker))
        #expect(inputs.items.map(\.synthetic) == words.map { ["w4", "w5", "w9"].contains($0.id) })
        #expect(inputs.excluded == [VoiceTrainingRange(start: 2.5, end: 3.2), VoiceTrainingRange(start: 5.4, end: 6.0)])
        project.transcript = nil
        #expect(VoiceTrainingSpans.inputs(project: project).items.isEmpty)
    }
}
