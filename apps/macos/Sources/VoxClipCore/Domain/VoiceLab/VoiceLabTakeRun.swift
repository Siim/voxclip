import Foundation

public struct VoiceLabTakeInput: Sendable, Equatable {
    public let text: String
    public let modelID: String
    public let recordID: String
    public let language: String
    public let seed: UInt32
    public let contentKey: String
    /// The source frames the run reads, at `sourceSampleRate`.
    public let source: VoiceLabSourceExcerpt
    /// The whole source's 10 ms RMS envelope (`VoiceLabTakeProcessing.envelope`), which the room-tone search reads.
    public let sourceEnvelope: AudioEnvelope
    public let sourceSampleRate: Int
    public let items: [TimedWord]
    public let cutWordIDs: Set<String>
    public let window: VoiceLabWindow
    public let incomingSilence: Double?
    public let outgoingSilence: Double?
    public let cleanAudioOn: Bool
    public let providerConsent: Bool
    /// A source held whole.
    public init(text: String, modelID: String, recordID: String, language: String, seed: UInt32, contentKey: String,
                source: [Float], sourceSampleRate: Int, items: [TimedWord], cutWordIDs: Set<String> = [],
                window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?,
                cleanAudioOn: Bool = false, providerConsent: Bool) {
        self.init(text: text, modelID: modelID, recordID: recordID, language: language, seed: seed, contentKey: contentKey,
                  source: VoiceLabSourceExcerpt(whole: source), sourceEnvelope: VoiceLabTakeProcessing.envelope(source, sampleRate: sourceSampleRate),
                  sourceSampleRate: sourceSampleRate, items: items, cutWordIDs: cutWordIDs, window: window, incomingSilence: incomingSilence,
                  outgoingSilence: outgoingSilence, cleanAudioOn: cleanAudioOn, providerConsent: providerConsent)
    }
    /// A source of any length, of which only `source`'s regions are held.
    public init(text: String, modelID: String, recordID: String, language: String, seed: UInt32, contentKey: String,
                source: VoiceLabSourceExcerpt, sourceEnvelope: AudioEnvelope, sourceSampleRate: Int, items: [TimedWord],
                cutWordIDs: Set<String> = [], window: VoiceLabWindow, incomingSilence: Double?, outgoingSilence: Double?,
                cleanAudioOn: Bool = false, providerConsent: Bool) {
        self.text = text; self.modelID = modelID; self.recordID = recordID; self.language = language; self.seed = seed
        self.contentKey = contentKey; self.source = source; self.sourceEnvelope = sourceEnvelope; self.sourceSampleRate = sourceSampleRate; self.items = items
        self.cutWordIDs = cutWordIDs; self.window = window; self.incomingSilence = incomingSilence; self.outgoingSilence = outgoingSilence
        self.cleanAudioOn = cleanAudioOn; self.providerConsent = providerConsent
    }
    public func options(take: Int) -> VoiceLabSpeechOptions {
        let kept = items.filter { $0.kind == .word && !cutWordIDs.contains($0.id) }
        let previous = kept.filter { $0.end <= window.start }.map(\.text).joined(separator: " ")
        let next = kept.filter { $0.start >= window.end }.map(\.text).joined(separator: " ")
        return VoiceLabSpeechOptions(seed: seed &+ UInt32(truncatingIfNeeded: take), previousText: previous, nextText: next)
    }
}

public struct VoiceLabTakeQuote: Sendable, Equatable {
    public let index: Int
    public let seed: UInt32
    public let synthesis: VoiceLabQuote
    public let qa: VoiceLabQuote
    package init(index: Int, seed: UInt32, synthesis: VoiceLabQuote, qa: VoiceLabQuote) {
        self.index = index; self.seed = seed; self.synthesis = synthesis; self.qa = qa
    }
}

public struct VoiceLabTakeRunQuote: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let takes: [VoiceLabTakeQuote]
    public let preparedAt: Date
    public let expiresAt: Date
    public let estimate: CostEstimate
    package init(id: UUID, takes: [VoiceLabTakeQuote], preparedAt: Date) {
        self.id = id; self.takes = takes; self.preparedAt = preparedAt; expiresAt = preparedAt.addingTimeInterval(300)
        estimate = Self.total(of: takes.flatMap { [$0.synthesis.estimate, $0.qa.estimate] }, takes: takes.count)
    }
    /// The sum of take quotes' estimates, `takes` units of "take": `usd` is unknown when any estimate's is, and so are
    /// `credits`. A run and a take batch (`VoiceLabTakeBatch`) present their totals this way.
    package static func total(of estimates: [CostEstimate], takes: Int) -> CostEstimate {
        let known = estimates.allSatisfy { $0.usd != nil }
        let creditsKnown = estimates.allSatisfy { $0.credits != nil }
        return CostEstimate(provider: "elevenlabs", operation: "takeRun", units: Double(takes), unit: "take",
                            usd: known ? estimates.reduce(Decimal(0)) { $0 + ($1.usd ?? 0) } : nil,
                            credits: creditsKnown ? estimates.reduce(0) { $0 + ($1.credits ?? 0) } : nil,
                            basis: known ? "bounded-tts-and-scribe" : "unknown")
    }
}

public enum VoiceLabTakeQAFailure: String, Sendable, Codable { case transcript, clipping, loudness, speaker }
public struct VoiceLabTakeQAResult: Sendable, Equatable {
    public let values: VoiceLabQA
    public let failures: [VoiceLabTakeQAFailure]
    public var passed: Bool { failures.isEmpty }
    package init(values: VoiceLabQA, failures: [VoiceLabTakeQAFailure]) { self.values = values; self.failures = failures }
}

public enum VoiceLabTakeQuality {
    public static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { EditingPrimitives.normalizeForMatch(EditingPrimitives.nfc(String($0))) }.filter { !$0.isEmpty }
    }
    public static func transcriptRatio(expected: [String], recognized: [String]) throws -> Double {
        guard !expected.isEmpty, expected.count <= 5_000, recognized.count <= 5_000 else { throw VoiceLabError.invalidInput }
        var previous = [Int](repeating: 0, count: recognized.count + 1)
        for expectedToken in expected {
            var next = [Int](repeating: 0, count: recognized.count + 1)
            for index in recognized.indices {
                next[index + 1] = expectedToken.utf8.elementsEqual(recognized[index].utf8)
                    ? previous[index] + 1 : max(previous[index + 1], next[index])
            }
            previous = next
        }
        return 2 * Double(previous.last ?? 0) / Double(expected.count + recognized.count)
    }
    public static func evaluate(expected: String, recognized: [String], mixed: [Float], sampleRate: Int,
                                seams: [Int], speakerScore: Double, threshold: Double) throws -> VoiceLabTakeQAResult {
        guard speakerScore.isFinite, (-1...1).contains(speakerScore), threshold.isFinite, (0...1).contains(threshold) else { throw VoiceLabError.invalidInput }
        let expectedTokens = tokens(expected)
        let recognizedTokens = recognized.flatMap(tokens)
        let ratio = try transcriptRatio(expected: expectedTokens, recognized: recognizedTokens)
        let peak = try VoiceLabLoudness.samplePeakDbfs(mixed)
        guard peak.isFinite else { throw VoiceLabError.invalidAudio }
        let jump = try VoiceLabLoudness.lufsJumpLu(mixed, sampleRate: sampleRate, seamSamples: seams)
        var failures: [VoiceLabTakeQAFailure] = []
        let exact = expectedTokens.count == recognizedTokens.count && zip(expectedTokens, recognizedTokens).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
        if expectedTokens.count <= 5 ? !exact : ratio < 0.9 { failures.append(.transcript) }
        if peak >= 0 { failures.append(.clipping) }
        if jump > 2 { failures.append(.loudness) }
        if speakerScore < threshold { failures.append(.speaker) }
        return VoiceLabTakeQAResult(values: VoiceLabQA(transcriptMatch: ratio, lufsJumpLu: jump, peakDbfs: peak, speakerScore: speakerScore), failures: failures)
    }
    public static func rank(fit: VoiceLabFitResult, windowSeconds window: Double, matchRatio: Double, flatness: Double) throws -> Double {
        guard matchRatio.isFinite, flatness.isFinite, (0...1).contains(matchRatio), (0...1).contains(flatness) else { throw VoiceLabError.invalidInput }
        guard window.isFinite, window > 0 else { throw VoiceLabError.invalidInput }
        let fitCost: Double
        switch fit {
        case .exact: fitCost = 0
        case .changedDuration(_, _, let residual): fitCost = min(1, abs(residual) / (0.25 * window))
        }
        return 0.6 * (1 - fitCost) + 0.3 * matchRatio + 0.1 * flatness
    }
}

public struct VoiceLabTakeAudio: Sendable, Equatable {
    public let sampleRate: Int
    public let trimmed: [Float]
    public let mixed: [Float]
    public let patchRange: Range<Int>
    public let seams: [Int]
    public let gainDb: Double
    public let roomTone: VoiceLabRoomTone?
    public let fit: VoiceLabFitResult
    public var words: [VoiceLabWord] { fit.plan.words }
    package init(sampleRate: Int, trimmed: [Float], mixed: [Float], patchRange: Range<Int>, seams: [Int], gainDb: Double,
                 roomTone: VoiceLabRoomTone?, fit: VoiceLabFitResult) {
        self.sampleRate = sampleRate; self.trimmed = trimmed; self.mixed = mixed; self.patchRange = patchRange
        self.seams = seams; self.gainDb = gainDb; self.roomTone = roomTone; self.fit = fit
    }
}

public enum VoiceLabTakeFailure: Sendable, Equatable {
    case provider(VoiceLabError)
    case consent(VoiceConsentError)
    case invalidAudio
    case invalidAlignment
    case qa([VoiceLabTakeQAFailure])
}
public struct VoiceLabTakeRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let index: Int
    public let seed: UInt32
    public let receipt: VoiceLabReceipt?
    public let qaReceipt: VoiceLabReceipt?
    /// The take's request IDs the provider accepted: the 2xx status line arrived, which is when the spend ledger records
    /// a request (voice-lab §3.1), even if the reply then failed and no receipt followed. Holds both receipts' IDs.
    public let acceptedRequestIDs: Set<UUID>
    public let generated: VoiceLabAudioResult?
    public let quote: VoiceLabTakeQuote?
    public let audio: VoiceLabTakeAudio?
    public let qa: VoiceLabTakeQAResult?
    public let score: Double?
    public let failure: VoiceLabTakeFailure?
    public var selectable: Bool { failure == nil && qa?.passed == true && audio != nil }
    public var fits: Bool {
        if let audio, case .exact = audio.fit { return true }
        return false
    }
    package init(id: UUID, index: Int, seed: UInt32, receipt: VoiceLabReceipt? = nil, audio: VoiceLabTakeAudio? = nil,
                 qa: VoiceLabTakeQAResult? = nil, score: Double? = nil, failure: VoiceLabTakeFailure? = nil,
                 qaReceipt: VoiceLabReceipt? = nil, generated: VoiceLabAudioResult? = nil, quote: VoiceLabTakeQuote? = nil,
                 accepted: Set<UUID> = []) {
        self.id = id; self.index = index; self.seed = seed; self.receipt = receipt; self.audio = audio
        self.qa = qa; self.score = score; self.failure = failure
        self.qaReceipt = qaReceipt; self.generated = generated; self.quote = quote
        acceptedRequestIDs = accepted.union([receipt?.requestID, qaReceipt?.requestID].compactMap { $0 })
    }
}
public enum VoiceLabTakeRunEnd: String, Sendable, Equatable { case completed, earlyStop, cancelled, invalidated, fatal }
public struct VoiceLabTakeRunResult: Sendable, Equatable {
    public let rows: [VoiceLabTakeRow]
    public let end: VoiceLabTakeRunEnd
    public var ranked: [VoiceLabTakeRow] {
        rows.filter(\.selectable).sorted { $0.score == $1.score ? $0.index < $1.index : ($0.score ?? 0) > ($1.score ?? 0) }
    }
    public var best: VoiceLabTakeRow? { ranked.first }
    package init(rows: [VoiceLabTakeRow], end: VoiceLabTakeRunEnd) { self.rows = rows; self.end = end }
}
