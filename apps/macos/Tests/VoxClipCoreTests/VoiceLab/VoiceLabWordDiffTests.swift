import Foundation
import Testing
@testable import VoxClipCore

private struct LabWord: Decodable, Sendable {
    let value: TimedWord
    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        let id = try row.decode(String.self)
        let text = try row.decode(String.self)
        let start = try row.decode(Double.self)
        let end = try row.decode(Double.self)
        let kind = try row.decode(WordKind.self)
        value = TimedWord(id: id, text: text, kind: kind, start: start, end: end)
    }
}
private struct LabDiffOp: Decodable, Sendable {
    let kind: String
    let sourceWordId: String?
    let sourceToken: String?
    let newToken: String?
    init(kind: String, sourceWordId: String, sourceToken: String, newToken: String) {
        self.kind = kind
        self.sourceWordId = sourceWordId
        self.sourceToken = sourceToken
        self.newToken = newToken
    }
    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        kind = try row.decode(String.self)
        sourceWordId = try row.decode(String?.self)
        sourceToken = try row.decode(String?.self)
        newToken = try row.decode(String?.self)
    }
}
private struct LabRepetition: Decodable, Sendable {
    let token: String
    let count: Int
    let idPrefix: String?
    let timingStep: Double?
}
private struct LabRepeatedOps: Decodable, Sendable {
    let kind: String
    let sourceToken: String
    let newToken: String
    let count: Int
    let idPrefix: String
}
private struct LabHunk: Decodable, Sendable {
    let kind: String
    let sourceWordIds: [String]
    let newTokens: [String]
    let correctedTexts: [String]
    let absorbedItemIds: [String]
    let bridgeWordIds: [String]
    let sourceStartIndex: Int
    let sourceEndIndex: Int
    let anchorSeconds: Double?
}
private struct LabPatchBudget: Decodable, Sendable {
    let voiceTokenCount: Int
    let wordItems: Int
    let flag: String
    let copy: String?
}
private struct LabSummary: Decodable, Sendable {
    let cutCount: Int
    let revoicedPhrases: Int
    let estimateSeconds: Double
    let costUnits: Double?
    let usd: String?
    let copy: String
}
private struct LabDiffExpected: Decodable, Sendable {
    let error: String?
    let side: VoiceLabDiffSideValue?
    let count: Int?
    let limit: Int?
    let ops: [LabDiffOp]?
    let repeatedOps: LabRepeatedOps?
    let hunks: [LabHunk]?
    let budget: LabPatchBudget?
    let summary: LabSummary?
    var expandedOps: [LabDiffOp]? {
        guard let repeatedOps else { return ops }
        return (0..<repeatedOps.count).map { (index: Int) -> LabDiffOp in
            LabDiffOp(kind: repeatedOps.kind, sourceWordId: repeatedOps.idPrefix + String(index),
                      sourceToken: repeatedOps.sourceToken, newToken: repeatedOps.newToken)
        }
    }
}
private enum VoiceLabDiffSideValue: String, Decodable, Sendable { case source, newText }
private struct LabDiffCase: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let source: [LabWord]?
    let newText: String?
    let sourceRepeat: LabRepetition?
    let newTextRepeat: LabRepetition?
    let transcriptWordItems: Int
    let transcriptEvents: Int
    let expected: LabDiffExpected
    let patchTexts: [String?]?
    var description: String { name }
    var expandedSource: [TimedWord] {
        guard let sourceRepeat else { return source!.map(\.value) }
        let step: Double = sourceRepeat.timingStep!
        let halfStep: Double = step / 2
        return (0..<sourceRepeat.count).map { (index: Int) -> TimedWord in
            let position: Double = Double(index)
            let start: Double = position * step
            let end: Double = start + halfStep
            return TimedWord(id: sourceRepeat.idPrefix! + String(index), text: sourceRepeat.token, start: start, end: end)
        }
    }
    var expandedText: String {
        guard let newTextRepeat else { return newText! }
        return Array(repeating: newTextRepeat.token, count: newTextRepeat.count).joined(separator: " ")
    }
}
private struct LabDiffDocument: Decodable {
    let caseCount: Int
    let cases: [LabDiffCase]
}

@Suite("Voice Lab word diff and patch budget")
struct VoiceLabWordDiffTests {
    private static let document = try? JSONDecoder().decode(LabDiffDocument.self, from: FixtureLoader.data("fixtures/voice-lab/word-diff-cases.json"))

    @Test func fixtureCount() throws {
        let document = try #require(Self.document)
        #expect(document.caseCount == 129)
        #expect(document.cases.count == document.caseCount)
    }

    @Test(arguments: Self.document?.cases ?? [])
    fileprivate func sharedVector(_ vector: LabDiffCase) throws {
        let source: [TimedWord] = vector.expandedSource
        if vector.expected.error != nil {
            let side: VoiceLabDiffSide = vector.expected.side == .source ? .source : .newText
            let error = VoiceLabWordDiffError.tokenLimit(side: side, count: vector.expected.count!, limit: vector.expected.limit!)
            #expect(throws: error) { try VoiceLabWordDiff.diff(source: source, newText: vector.expandedText) }
            return
        }
        let result = try VoiceLabWordDiff.diff(source: source, newText: vector.expandedText)
        let ops = try #require(vector.expected.expandedOps)
        #expect(result.ops.count == ops.count)
        for (actual, expected) in zip(result.ops, ops) {
            #expect(actual.kind.rawValue == expected.kind)
            #expect(actual.sourceWordId == expected.sourceWordId)
            #expect(actual.sourceToken.map { Array($0.utf8) } == expected.sourceToken.map { Array($0.utf8) })
            #expect(actual.newToken.map { Array($0.utf8) } == expected.newToken.map { Array($0.utf8) })
        }
        var inserted: Bool = false
        for op in result.ops {
            if op.kind == .equal { inserted = false }
            if op.kind == .delete { #expect(!inserted) }
            if op.kind == .insert { inserted = true }
        }
        let hunks = try #require(vector.expected.hunks)
        #expect(result.hunks.count == hunks.count)
        for (actual, expected) in zip(result.hunks, hunks) {
            #expect(actual.kind.rawValue == expected.kind)
            #expect(actual.sourceWordIds == expected.sourceWordIds)
            #expect(actual.newTokens.map { Array($0.utf8) } == expected.newTokens.map { Array($0.utf8) })
            #expect(actual.correctedTexts.map { Array($0.utf8) } == expected.correctedTexts.map { Array($0.utf8) })
            #expect(actual.absorbedItemIds == expected.absorbedItemIds)
            #expect(actual.bridgeWordIds == expected.bridgeWordIds)
            #expect(actual.sourceStartIndex == expected.sourceStartIndex)
            #expect(actual.sourceEndIndex == expected.sourceEndIndex)
            #expect(actual.anchorSeconds == expected.anchorSeconds)
        }
        let transcript: [TimedWord] = (0..<vector.transcriptWordItems).map { (index: Int) -> TimedWord in
            let start: Double = Double(index)
            let end: Double = start + 0.5
            return TimedWord(id: "t\(index)", text: "word", start: start, end: end)
        }
        let events: [TimedWord] = (0..<vector.transcriptEvents).map { (index: Int) -> TimedWord in
            TimedWord(id: "e\(index)", text: "noise", kind: .event, start: 0, end: 0.1)
        }
        let budget = VoiceLabPatchBudget.evaluate(hunks: result.hunks, transcript: transcript + events)
        let expected = try #require(vector.expected.budget)
        #expect(budget.voiceTokenCount == expected.voiceTokenCount)
        #expect(budget.wordItems == expected.wordItems)
        #expect(budget.flag.rawValue == expected.flag)
        #expect(budget.copy == expected.copy)
        let voices: [VoiceLabDiffHunk] = result.hunks.filter { $0.kind == .voice }
        let texts: [String?] = try #require(vector.patchTexts)
        let meters: [VoiceLabFitMeterResult] = try voices.enumerated().map { (index: Int, hunk: VoiceLabDiffHunk) in
            try VoiceLabFitMeter.measure(text: texts[index] ?? hunk.newTokens.joined(separator: " "), window: labWindow(), incomingSilence: 0.4,
                                        outgoingSilence: 0.4, rate: 10, newWords: hunk.newTokens.joined(separator: " "))
        }
        let catalog = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let summary = try VoiceLabDiffSummary.make(hunks: result.hunks, meters: meters, catalog: catalog, model: "eleven_v3", candidates: 3,
                                                  patchTexts: texts)
        let header = try #require(vector.expected.summary)
        #expect(summary.cutCount == header.cutCount)
        #expect(summary.revoicedPhrases == header.revoicedPhrases)
        #expect(summary.estimateSeconds == header.estimateSeconds)
        #expect(summary.costEstimate?.units == header.costUnits)
        #expect(summary.costEstimate?.usd == header.usd.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) })
        #expect(summary.copy == header.copy)
        let noPrice = try VoiceLabDiffSummary.make(hunks: result.hunks, meters: meters)
        #expect(noPrice.costEstimate == nil)
        let unknown = try VoiceLabDiffSummary.make(hunks: result.hunks, meters: meters, catalog: catalog, model: "not-listed", patchTexts: texts)
        #expect(unknown.costEstimate?.usd == nil)
        #expect(unknown.copy == noPrice.copy)
        if let cost = summary.costEstimate?.usd {
            let suffix: String = " · " + VoiceLabCostPresentation.format(cost)
            #expect(summary.copy == noPrice.copy + suffix)
        } else { #expect(summary.copy == noPrice.copy) }
    }

    @Test func invalidInputsAreTyped() throws {
        let source = [TimedWord(id: "w", text: "old", start: 0, end: 1)]
        #expect(throws: VoiceLabWordDiffError.invalidInput) { try VoiceLabWordDiff.diff(source: source + source, newText: "new") }
        #expect(throws: VoiceLabWordDiffError.invalidInput) {
            try VoiceLabWordDiff.diff(source: [TimedWord(id: "w", text: "old", start: .nan, end: 1)], newText: "new")
        }
        let diff = try VoiceLabWordDiff.diff(source: source, newText: "new")
        #expect(throws: VoiceLabLengthBudgetError.invalidInput) { try VoiceLabDiffSummary.make(hunks: diff.hunks, meters: []) }
        let text = "left new right"
        let meter = try VoiceLabFitMeter.measure(text: text, window: labWindow(), incomingSilence: 0.4, outgoingSilence: 0.4,
                                                rate: 10, newWords: "new", multipleHunks: true)
        #expect(meter.copy.hasPrefix("“new” · "))
        let catalog = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let summary = try VoiceLabDiffSummary.make(hunks: diff.hunks, meters: [meter], catalog: catalog, model: "eleven_v3", patchTexts: [text])
        #expect(summary.costEstimate?.units == 14)
        #expect(summary.estimateSeconds == meter.estimateSeconds)
        #expect(throws: VoiceLabLengthBudgetError.invalidInput) {
            try VoiceLabDiffSummary.make(hunks: diff.hunks, meters: [meter], patchTexts: [])
        }
    }
}

private struct LabWindow: Decodable, Sendable {
    let start: Double
    let end: Double
    let left: VoiceLabSeamKind
    let right: VoiceLabSeamKind
    let incoming: Double?
    let outgoing: Double?
    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        start = try row.decode(Double.self); end = try row.decode(Double.self)
        left = try row.decode(VoiceLabSeamKind.self); right = try row.decode(VoiceLabSeamKind.self)
        incoming = try row.decode(Double?.self); outgoing = try row.decode(Double?.self)
    }
}
private struct LabCandidate: Decodable, Sendable {
    let value: VoiceLabRateCandidate
    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        value = try VoiceLabRateCandidate(text: row.decode(String.self), firstCharStart: row.decode(Double.self), lastCharEnd: row.decode(Double.self))
    }
}
private struct LabLengthInput: Decodable, Sendable {
    let window: LabWindow?
    let rate: Double?
    let bridgeLength: Int?
    let text: String?
    let newWords: String?
    let multipleHunks: Bool?
    let transcript: [LabWord]?
    let pauseThresholdSeconds: Double?
    let candidates: [LabCandidate]?
}
private struct LabRange: Decodable, Sendable {
    let targetSeconds: Double
    let edgePadSeconds: Double
    let bridgeLength: Int
    let minChars: Int
    let maxChars: Int
    let advisory: Bool
}
private struct LabMeter: Decodable, Sendable {
    let estimateSeconds: Double
    let gapSeconds: Double
    let lowerBoundSeconds: Double
    let upperBoundSeconds: Double
    let verdict: String
    let copy: String
}
private struct LabLengthExpected: Decodable, Sendable {
    let error: String?
    let budget: LabRange?
    let meter: LabMeter?
    let charactersPerSecond: Double?
    let source: String?
    let textLength: Int?
    let voicedSeconds: Double?
    let targetSeconds: Double?
    let edgePadSeconds: Double?
    let bridgeLength: Int?
    let minChars: Int?
    let maxChars: Int?
    let advisory: Bool?
}
private struct LabLengthCase: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let kind: String
    let input: LabLengthInput
    let expected: LabLengthExpected
    var description: String { name }
}
private struct LabLengthDocument: Decodable {
    let caseCount: Int
    let cases: [LabLengthCase]
}

private func labWindow(start: Double = 0, end: Double = 2, left: VoiceLabSeamKind = .gap,
                       right: VoiceLabSeamKind = .gap, bridges: [String] = []) -> VoiceLabWindow {
    VoiceLabWindow(firstWordId: "w0", lastWordId: "w0", leftBridgeWordIds: bridges, rightBridgeWordIds: [], start: start, end: end,
                   startSample: 0, endSample: 0, leftSeam: VoiceLabSeamPlacement(kind: left, time: start, sample: 0, fadeSamples: 0),
                   rightSeam: VoiceLabSeamPlacement(kind: right, time: end, sample: 0, fadeSamples: 0))
}

@Suite("Voice Lab length budget and fit meter")
struct VoiceLabLengthBudgetTests {
    private static let document = try? JSONDecoder().decode(LabLengthDocument.self, from: FixtureLoader.data("fixtures/voice-lab/length-budget-cases.json"))

    @Test func fixtureCount() throws {
        let document = try #require(Self.document)
        #expect(document.caseCount == 53)
        #expect(document.cases.count == document.caseCount)
    }

    @Test(arguments: Self.document?.cases ?? [])
    fileprivate func sharedVector(_ vector: LabLengthCase) throws {
        do {
            try replay(vector)
            #expect(vector.expected.error == nil)
        } catch let error as VoiceLabLengthBudgetError {
            #expect(vector.expected.error == (error == .invalidInput ? "invalidInput" : "rateUnavailable"))
        }
    }

    private func replay(_ vector: LabLengthCase) throws {
        let input = vector.input
        let expected = vector.expected
        if vector.kind == "rate" {
            let rate = try VoiceLabLengthBudget.rate(transcript: input.transcript!.map(\.value), pauseThresholdSeconds: input.pauseThresholdSeconds!,
                                                    candidates: input.candidates!.map(\.value))
            #expect(rate.charactersPerSecond == expected.charactersPerSecond)
            #expect(rate.source.rawValue == expected.source)
            #expect(rate.textLength == expected.textLength)
            #expect(rate.voicedSeconds == expected.voicedSeconds)
        } else if vector.kind == "fullTake" {
            let range = try VoiceLabLengthBudget.fullTake(transcript: input.transcript!.map(\.value), rate: input.rate!)
            #expect(range.targetSeconds == expected.targetSeconds)
            #expect(range.edgePadSeconds == expected.edgePadSeconds)
            #expect(range.bridgeLength == expected.bridgeLength)
            #expect(range.minChars == expected.minChars)
            #expect(range.maxChars == expected.maxChars)
            #expect(range.advisory == expected.advisory)
        } else {
            let raw = try #require(input.window)
            let window = labWindow(start: raw.start, end: raw.end, left: raw.left, right: raw.right)
            let range = try VoiceLabLengthBudget.calculate(window: window, incomingSilence: raw.incoming, outgoingSilence: raw.outgoing,
                                                         bridgeLength: input.bridgeLength!, rate: input.rate!)
            let budget = try #require(expected.budget)
            #expect(range.targetSeconds == budget.targetSeconds)
            #expect(range.edgePadSeconds == budget.edgePadSeconds)
            #expect(range.bridgeLength == budget.bridgeLength)
            #expect(range.minChars == budget.minChars)
            #expect(range.maxChars == budget.maxChars)
            #expect(range.advisory == budget.advisory)
            let meter = try VoiceLabFitMeter.measure(text: input.text!, window: window, incomingSilence: raw.incoming,
                                                    outgoingSilence: raw.outgoing, rate: input.rate!, newWords: input.newWords!,
                                                    multipleHunks: input.multipleHunks!)
            let target = try #require(expected.meter)
            #expect(meter.estimateSeconds == target.estimateSeconds)
            #expect(meter.gapSeconds == target.gapSeconds)
            #expect(meter.lowerBoundSeconds == target.lowerBoundSeconds)
            #expect(meter.upperBoundSeconds == target.upperBoundSeconds)
            #expect(meter.verdict.rawValue == target.verdict)
            #expect(meter.copy == target.copy)
        }
    }

    @Test func passageResolvesBridgesAndRejectsInvalidInputs() throws {
        let transcript = [TimedWord(id: "w0", text: "õ ä 12", start: 0, end: 1)]
        let window = labWindow(bridges: ["w0"])
        let range = try VoiceLabLengthBudget.passage(window: window, transcript: transcript, incomingSilence: 0.4, outgoingSilence: 0.4, rate: 10)
        #expect(range.bridgeLength == 4)
        let calculated = try VoiceLabLengthBudget.calculate(window: window, incomingSilence: 0.4, outgoingSilence: 0.4, bridgeLength: 4, rate: 10)
        #expect(range == calculated)
        #expect(throws: VoiceLabLengthBudgetError.invalidInput) {
            try VoiceLabLengthBudget.passage(window: window, transcript: [], incomingSilence: 0.4, outgoingSilence: 0.4, rate: 10)
        }
        #expect(throws: VoiceLabLengthBudgetError.invalidInput) { try VoiceLabLengthBudget.estimate(text: "word", rate: .infinity) }
        #expect(throws: VoiceLabLengthBudgetError.invalidInput) {
            try VoiceLabFitMeter.measure(text: "word", window: window, incomingSilence: .nan, outgoingSilence: 0.4, rate: 10, newWords: "word")
        }
    }
}
