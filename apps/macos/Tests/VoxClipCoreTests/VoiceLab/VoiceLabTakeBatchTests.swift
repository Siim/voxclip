import Foundation
import Testing
@testable import VoxClipCore

/// voice-lab.md §8.6 with several hunks, §2.6 and §3.1 (design delta §6 T1): replays
/// shared/fixtures/voice-lab/take-batch-cases.json (rules in take-batch-cases-README.md).
@Suite("Take batch vectors")
struct VoiceLabTakeBatchTests {
    private struct Vectors: Decodable {
        struct Amount: Decodable { let usd: String?; let credits: Int? }
        struct Window: Decodable {
            let recordId: String; let language: String; let modelId: String; let contentKey: String
            let startSample: Int64; let endSample: Int64; let characters: Int; let takes: Int
            let synthesis: Amount; let qa: Amount
        }
        struct Cap: Decodable { let limit: String; let spent: String }
        struct Estimate: Decodable { let units: Double; let usd: String?; let credits: Int?; let basis: String }
        struct Kind: Decodable { let kind: String; let text: String }
        struct Expected: Decodable { let error: String?; let estimate: Estimate?; let kind: Kind? }
        /// `[window, take, "synthesis" | "qa"]`.
        struct Request: Decodable {
            let window: Int; let take: Int; let part: String
            init(from decoder: any Decoder) throws {
                var row = try decoder.unkeyedContainer()
                window = try row.decode(Int.self); take = try row.decode(Int.self); part = try row.decode(String.self)
            }
        }
        struct Dispatch: Decodable { let request: Request; let remaining: Estimate }
        struct StepExpected: Decodable {
            let error: String?; let dispatches: [Dispatch]?; let next: Int?; let sent: Estimate?; let remaining: Estimate?
            let discarded: [Request]?
        }
        struct Step: Decodable { let window: Int; let end: String; let sent: [String]; let expected: StepExpected }
        struct Case: Decodable {
            let id: String; let windows: [Window]; let cap: Cap?; let expected: Expected; let run: [Step]?
        }
        let schema: String
        let providerName: String
        let candidates: Int
        let maximumWindows: Int
        let sampleRate: Int
        let cases: [Case]
    }
    private struct VectorError: Error { let message: String }
    private static let preparedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/take-batch-cases.json"))
    }
    private static func decimal(_ text: String) throws -> Decimal {
        guard let value = Decimal(string: text) else { throw VectorError(message: "decimal \(text)") }
        return value
    }
    private static func estimate(_ amount: Vectors.Amount, operation: String, units: Double, unit: String) throws -> CostEstimate {
        CostEstimate(provider: "elevenlabs", operation: operation, units: units, unit: unit, usd: try amount.usd.map(decimal),
                     credits: amount.credits, basis: amount.usd == nil ? "unknown" : "list-fixture")
    }
    private static func quote(_ operation: VoiceLabOperation, _ estimate: CostEstimate) -> VoiceLabQuote {
        VoiceLabQuote(id: UUID(), operation: operation, requestID: UUID(), estimate: estimate, region: .default,
                      endpoint: operation == .textToSpeech ? "tts" : "qa", languageMode: nil, fingerprint: "fixture", preparedAt: preparedAt)
    }
    private static func input(recordID: String = "voice-record", language: String = "en", modelID: String = "eleven_v3",
                              contentKey: String = "source-content", startSample: Int64, endSample: Int64, rate: Int = 24_000) -> VoiceLabTakeInput {
        let start = Double(startSample) / Double(rate), end = Double(endSample) / Double(rate)
        let window = VoiceLabWindow(firstWordId: "first", lastWordId: "last", leftBridgeWordIds: [], rightBridgeWordIds: [],
            start: start, end: end, startSample: startSample, endSample: endSample,
            leftSeam: .init(kind: .hard, time: start, sample: startSample, fadeSamples: 288),
            rightSeam: .init(kind: .hard, time: end, sample: endSample, fadeSamples: 288))
        return VoiceLabTakeInput(text: "phrase", modelID: modelID, recordID: recordID, language: language, seed: 7, contentKey: contentKey,
            source: [Float](), sourceSampleRate: rate, items: [], window: window, incomingSilence: nil, outgoingSilence: nil, providerConsent: true)
    }
    private static func takes(_ count: Int, synthesis: CostEstimate, qa: CostEstimate) -> [VoiceLabTakeQuote] {
        (0..<count).map { index in
            VoiceLabTakeQuote(index: index, seed: 7 &+ UInt32(index), synthesis: quote(.textToSpeech, synthesis), qa: quote(.speechToText, qa))
        }
    }
    private static func window(_ row: Vectors.Window, rate: Int) throws -> VoiceLabTakeBatch.Window {
        let synthesis = try estimate(row.synthesis, operation: "textToSpeech", units: Double(row.characters), unit: "character")
        let qa = try estimate(row.qa, operation: "speechToText", units: 290, unit: "second")
        return .init(input: input(recordID: row.recordId, language: row.language, modelID: row.modelId, contentKey: row.contentKey,
                                  startSample: row.startSample, endSample: row.endSample, rate: rate),
                     quote: VoiceLabTakeRunQuote(id: UUID(), takes: takes(row.takes, synthesis: synthesis, qa: qa), preparedAt: preparedAt))
    }
    private static func kind(_ row: Vectors.Kind?) throws -> VoiceLabCostPresentation.Kind {
        switch (row?.kind, row?.text) {
        case ("inline"?, let text?): return .inline(text)
        case ("confirm"?, let text?): return .confirm(text)
        default: throw VectorError(message: "kind \(String(describing: row?.kind))")
        }
    }
    private static func expect(_ actual: CostEstimate, _ expected: Vectors.Estimate?, _ label: String) throws {
        guard let expected else { throw VectorError(message: "\(label): no expected estimate") }
        let usd = try expected.usd.map(decimal)
        #expect(actual.provider == "elevenlabs" && actual.unit == "take", "\(label)")
        #expect(actual.units == expected.units, "\(label) units")
        #expect(actual.usd == usd, "\(label) usd \(String(describing: actual.usd))")
        #expect(actual.credits == expected.credits, "\(label) credits")
        #expect(actual.basis == expected.basis, "\(label) basis")
    }
    /// The request IDs a step names: each listed take's TTS ("synthesis") or TTS and QA ("both"). A take the window lacks
    /// becomes a request ID outside the batch, which `finish` must refuse.
    private static func requestIDs(_ step: Vectors.Step, in batch: VoiceLabTakeBatch) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for (take, which) in step.sent.enumerated() {
            guard ["both", "synthesis", "none"].contains(which) else { throw VectorError(message: "sent \(which)") }
            guard which != "none" else { continue }
            guard batch.windows.indices.contains(step.window), batch.windows[step.window].quote.takes.indices.contains(take) else {
                ids.insert(UUID()); continue
            }
            let quote = batch.windows[step.window].quote.takes[take]
            ids.insert(quote.synthesis.requestID)
            if which == "both" { ids.insert(quote.qa.requestID) }
        }
        return ids
    }
    private static func requestID(_ request: Vectors.Request, in batch: VoiceLabTakeBatch) throws -> UUID {
        guard batch.windows.indices.contains(request.window), batch.windows[request.window].quote.takes.indices.contains(request.take),
              ["synthesis", "qa"].contains(request.part) else { throw VectorError(message: "discarded \(request)") }
        let take = batch.windows[request.window].quote.takes[request.take]
        return request.part == "synthesis" ? take.synthesis.requestID : take.qa.requestID
    }

    @Test func everyCaseReplays() throws {
        let vectors = try vectors()
        for row in vectors.cases {
            let windows = try row.windows.map { try Self.window($0, rate: vectors.sampleRate) }
            if let error = row.expected.error {
                #expect(error == "invalidInput", "\(row.id)")
                #expect(throws: VoiceLabError.invalidInput, "\(row.id)") { try VoiceLabTakeBatch(windows: windows) }
                #expect(throws: VoiceLabError.invalidInput, "\(row.id) before any quote") { try VoiceLabTakeBatch.validate(windows.map(\.input)) }
                continue
            }
            let batch = try VoiceLabTakeBatch(windows: windows)
            try Self.expect(batch.estimate, row.expected.estimate, row.id)
            #expect(batch.takeCount == row.windows.reduce(0) { $0 + $1.takes }, "\(row.id)")
            let cap = try row.cap.map { VoiceLabMonthlyCap(limit: try Self.decimal($0.limit), spent: try Self.decimal($0.spent)) }
            let kind = try Self.kind(row.expected.kind)
            #expect(batch.kind(cap: cap) == kind, "\(row.id)")
            if let steps = row.run { try replay(steps, batch: batch, id: row.id) }
        }
    }

    private func replay(_ steps: [Vectors.Step], batch: VoiceLabTakeBatch, id: String) throws {
        var progress = VoiceLabTakeBatchProgress(batch: batch)
        #expect(progress.window == 0 && progress.sent.isEmpty && progress.discarded.isEmpty, "\(id)")
        #expect(progress.remainingEstimate == batch.estimate, "\(id): before the run, the whole batch remains")
        for (index, step) in steps.enumerated() {
            let label = "\(id) step \(index)"
            let ids = try Self.requestIDs(step, in: batch)
            guard let end = VoiceLabTakeRunEnd(rawValue: step.end) else { throw VectorError(message: "end \(step.end)") }
            if step.expected.error != nil {
                let before = progress
                do {
                    try progress.finish(window: step.window, sent: ids, end: end)
                    Issue.record("\(label) must be refused")
                } catch { #expect(error as? VoiceLabError == .invalidInput, "\(label)") }
                #expect(progress == before, "\(label) changes nothing")
                continue
            }
            guard let dispatches = step.expected.dispatches else { throw VectorError(message: "\(label): no dispatches") }
            for (ordinal, dispatch) in dispatches.enumerated() {
                let request = try Self.requestID(dispatch.request, in: batch)
                guard let remaining = progress.remainingEstimate(from: request) else {
                    Issue.record("\(label) dispatch \(ordinal): no remainder"); continue
                }
                try Self.expect(remaining, dispatch.remaining, "\(label) dispatch \(ordinal) remaining")
            }
            try progress.finish(window: step.window, sent: ids, end: end)
            #expect(progress.window == step.expected.next, "\(label) next")
            for request in progress.sent.union(progress.discarded) {
                #expect(progress.remainingEstimate(from: request) == nil, "\(label): a sent or discarded request is never dispatched")
            }
            #expect(progress.remainingEstimate(from: UUID()) == nil, "\(label): a foreign request")
            try Self.expect(progress.sentEstimate, step.expected.sent, "\(label) sent")
            try Self.expect(progress.remainingEstimate, step.expected.remaining, "\(label) remaining")
            let discarded = try Set((step.expected.discarded ?? []).map { try Self.requestID($0, in: batch) })
            #expect(progress.discarded == discarded, "\(label) discarded")
            #expect(progress.sent.isDisjoint(with: progress.discarded), "\(label)")
            if let total = batch.estimate.usd, let sent = progress.sentEstimate.usd, let remaining = progress.remainingEstimate.usd,
               let dropped = batch.estimate(of: progress.discarded).usd {
                #expect(sent + remaining + dropped == total, "\(label): every request is sent, discarded or still to come")
            }
        }
    }

    /// voice-lab §3.1 with one approval for the batch: a cap check before each dispatch that adds `remainingEstimate(from:)`
    /// to the month's ledger never crosses a cap the approval did not cross. The figure that moves only when a window
    /// finishes would, because the ledger already holds the requests it still counts.
    @Test func aCapCheckBeforeEachDispatchStaysWithTheApproval() throws {
        let vectors = try vectors()
        let row = try #require(vectors.cases.first { $0.id == "three-windows-reaching-cap" })
        let batch = try VoiceLabTakeBatch(windows: row.windows.map { try Self.window($0, rate: vectors.sampleRate) })
        let cap = try #require(row.cap)
        let limit = try Self.decimal(cap.limit), approvedAt = try Self.decimal(cap.spent)
        #expect(!VoiceLabMonthlyCap(limit: limit, spent: approvedAt).isCrossed(by: batch.estimate))
        var progress = VoiceLabTakeBatchProgress(batch: batch)
        var ledger = approvedAt, staleCrossings = 0
        for (index, window) in batch.windows.enumerated() {
            for request in window.quote.takes.flatMap({ [$0.synthesis, $0.qa] }) {
                let remaining = try #require(progress.remainingEstimate(from: request.requestID))
                #expect(!VoiceLabMonthlyCap(limit: limit, spent: ledger).isCrossed(by: remaining))
                #expect(ledger + (remaining.usd ?? 0) == limit, "every request accepted: the ledger and the rest reach the cap exactly")
                if VoiceLabMonthlyCap(limit: limit, spent: ledger).isCrossed(by: progress.remainingEstimate) { staleCrossings += 1 }
                ledger += request.estimate.usd ?? 0
            }
            try progress.finish(window: index, sent: Set(window.requestIDs), end: .completed)
        }
        #expect(staleCrossings > 0)
        #expect(ledger == limit && progress.window == nil)
    }

    @Test func theConstantsMatchTheVectors() throws {
        let vectors = try vectors()
        #expect(vectors.schema == "voxclip-take-batch-cases/1")
        #expect(vectors.providerName == VoiceLabTakeBatch.providerName)
        #expect(vectors.candidates == VoiceLabPricing.maximumCandidates)
        #expect(vectors.maximumWindows == VoiceLabTakeBatch.maximumWindows && VoiceLabTakeBatch.maximumWindows == 5)
        let ids = Set(vectors.cases.map(\.id))
        #expect(ids.count == vectors.cases.count)
        for required in ["three-windows-inline", "three-windows-crossing-limit", "three-windows-crossing-cap", "early-stop-on-window-2"] {
            #expect(ids.contains(required), "the plan names \(required)")
        }
    }

    /// One approval covers the union: three windows that would each be inline alone confirm together.
    @Test func theUnionConfirmsWhereEachWindowAloneWouldNot() throws {
        let vectors = try vectors()
        let row = try #require(vectors.cases.first { $0.id == "three-windows-crossing-limit" })
        let batch = try VoiceLabTakeBatch(windows: row.windows.map { try Self.window($0, rate: vectors.sampleRate) })
        for window in batch.windows {
            guard case .inline = VoiceLabCostPresentation.kind(window.quote.estimate, isLipSync: false, providerName: "ElevenLabs") else {
                Issue.record("Each window alone is under $0.50"); continue
            }
        }
        #expect(batch.kind() == .confirm("This will cost about $0.51 on your ElevenLabs account."))
    }

    @Test func aRepeatedRunQuoteOrRequestIsRefused() throws {
        let tts = CostEstimate(provider: "elevenlabs", operation: "textToSpeech", units: 5, unit: "character", usd: Decimal(string: "0.0004"), basis: "fixture")
        let qa = CostEstimate(provider: "elevenlabs", operation: "speechToText", units: 290, unit: "second", usd: Decimal(string: "0.0177222222"), basis: "fixture")
        let first = VoiceLabTakeBatch.Window(input: Self.input(startSample: 48_000, endSample: 96_000),
            quote: VoiceLabTakeRunQuote(id: UUID(), takes: Self.takes(3, synthesis: tts, qa: qa), preparedAt: Self.preparedAt))
        let later = Self.input(startSample: 120_000, endSample: 168_000)
        func second(_ takes: [VoiceLabTakeQuote], id: UUID = UUID()) -> VoiceLabTakeBatch.Window {
            .init(input: later, quote: VoiceLabTakeRunQuote(id: id, takes: takes, preparedAt: Self.preparedAt))
        }
        let pair = try VoiceLabTakeBatch(windows: [first, second(Self.takes(3, synthesis: tts, qa: qa))])
        #expect(pair.takeCount == 6 && pair.estimate.usd == Decimal(string: "0.1087333332"))
        #expect(throws: VoiceLabError.invalidInput) { try VoiceLabTakeBatch(windows: []) }
        #expect(throws: VoiceLabError.invalidInput) { try VoiceLabTakeBatch(windows: [first, second(Self.takes(3, synthesis: tts, qa: qa), id: first.quote.id)]) }
        #expect(throws: VoiceLabError.invalidInput) { try VoiceLabTakeBatch(windows: [first, second([first.quote.takes[0]])]) }
        let sameRequest = VoiceLabQuote(id: UUID(), operation: .speechToText, requestID: first.quote.takes[0].qa.requestID, estimate: qa,
                                        region: .default, endpoint: "qa", languageMode: nil, fingerprint: "fixture")
        let borrowed = VoiceLabTakeQuote(index: 0, seed: 1, synthesis: Self.quote(.textToSpeech, tts), qa: sameRequest)
        #expect(throws: VoiceLabError.invalidInput) { try VoiceLabTakeBatch(windows: [first, second([borrowed])]) }
        #expect(throws: VoiceLabError.invalidInput) { try VoiceLabTakeBatch(windows: [first, second([])]) }
        #expect(throws: VoiceLabError.invalidInput) { try VoiceLabTakeBatch(windows: [first, second(Self.takes(4, synthesis: tts, qa: qa))]) }
    }

    /// Sent is what the provider accepted, read from the rows: a receipt, or a request accepted before its reply failed and
    /// left no receipt, which the spend ledger recorded all the same. A QA request needs its take's TTS.
    @Test func finishingFromAResultCountsWhatTheProviderAccepted() throws {
        let tts = CostEstimate(provider: "elevenlabs", operation: "textToSpeech", units: 5, unit: "character", usd: Decimal(string: "0.0004"), credits: 5, basis: "fixture")
        let qa = CostEstimate(provider: "elevenlabs", operation: "speechToText", units: 290, unit: "second", usd: Decimal(string: "0.0177222222"), basis: "fixture")
        let quote = VoiceLabTakeRunQuote(id: UUID(), takes: Self.takes(3, synthesis: tts, qa: qa), preparedAt: Self.preparedAt)
        let laterQuote = VoiceLabTakeRunQuote(id: UUID(), takes: Self.takes(3, synthesis: tts, qa: qa), preparedAt: Self.preparedAt)
        let batch = try VoiceLabTakeBatch(windows: [.init(input: Self.input(startSample: 48_000, endSample: 96_000), quote: quote),
            .init(input: Self.input(startSample: 120_000, endSample: 168_000), quote: laterQuote)])
        func receipt(_ request: VoiceLabQuote) -> VoiceLabReceipt {
            VoiceLabReceipt(provider: "elevenlabs", region: .default, endpoint: request.endpoint, modelID: nil, voiceID: nil,
                            requestID: request.requestID, providerRequestID: nil, spendWarning: nil)
        }
        let takes = quote.takes, later = laterQuote.takes
        let rows = [
            VoiceLabTakeRow(id: takes[0].synthesis.requestID, index: 0, seed: takes[0].seed, receipt: receipt(takes[0].synthesis),
                            failure: .qa([.transcript]), qaReceipt: receipt(takes[0].qa), quote: takes[0]),
            // Scribe accepted the QA request, then its reply was malformed.
            VoiceLabTakeRow(id: takes[1].synthesis.requestID, index: 1, seed: takes[1].seed, receipt: receipt(takes[1].synthesis),
                            failure: .provider(.malformedResponse), quote: takes[1], accepted: [takes[1].qa.requestID]),
            VoiceLabTakeRow(id: takes[2].synthesis.requestID, index: 2, seed: takes[2].seed, failure: .provider(.providerFailure(500)), quote: takes[2]),
        ]
        #expect(rows[0].acceptedRequestIDs == [takes[0].synthesis.requestID, takes[0].qa.requestID])
        #expect(rows[1].acceptedRequestIDs == [takes[1].synthesis.requestID, takes[1].qa.requestID] && rows[2].acceptedRequestIDs.isEmpty)
        var progress = VoiceLabTakeBatchProgress(batch: batch)
        try progress.finish(window: 0, result: VoiceLabTakeRunResult(rows: rows, end: .completed))
        #expect(progress.sent == [takes[0].synthesis.requestID, takes[0].qa.requestID, takes[1].synthesis.requestID, takes[1].qa.requestID])
        #expect(progress.discarded == [takes[2].synthesis.requestID, takes[2].qa.requestID])
        #expect(progress.window == 1)
        #expect(progress.sentEstimate.units == 2 && progress.sentEstimate.usd == Decimal(string: "0.0362444444"))
        #expect(progress.remainingEstimate.units == 3 && progress.remainingEstimate.usd == Decimal(string: "0.0543666666"))
        // ElevenLabs accepted the TTS request, then its alignment was missing: a fatal end with no receipt.
        let missing = VoiceLabTakeRow(id: later[0].synthesis.requestID, index: 0, seed: later[0].seed, failure: .provider(.invalidAlignment),
                                      quote: later[0], accepted: [later[0].synthesis.requestID])
        try progress.finish(window: 1, result: VoiceLabTakeRunResult(rows: [missing], end: .fatal))
        #expect(progress.window == nil && progress.sent.contains(later[0].synthesis.requestID))
        #expect(progress.sentEstimate.units == 3 && progress.sentEstimate.usd == Decimal(string: "0.0366444444"))
        #expect(progress.remainingEstimate.units == 0 && progress.remainingEstimate.usd == 0)

        var lone = VoiceLabTakeBatchProgress(batch: batch)
        #expect(throws: VoiceLabError.invalidInput) { try lone.finish(window: 0, sent: [takes[0].qa.requestID], end: .completed) }
        #expect(lone == VoiceLabTakeBatchProgress(batch: batch))
    }
}
