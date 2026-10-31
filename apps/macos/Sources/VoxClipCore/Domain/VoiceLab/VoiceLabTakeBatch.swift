import Foundation

/// Every voice window's bounded take set in one Rewrite, prepared before anything is shown and approved once; voice-lab
/// §8.6 with several hunks (design delta §13.2) and design delta §6 T1. One affirmative approval covers exactly the union of
/// the windows' quotes and their summed TTS plus Scribe QA cap. Each window keeps its own `VoiceLabTakeRun`, and the windows
/// run one at a time in source order (`VoiceLabTakeBatchProgress`). Try Another on one phrase is a new batch of one window.
/// `shared/fixtures/voice-lab/take-batch-cases.json` pins the rules.
public struct VoiceLabTakeBatch: Sendable, Equatable, Identifiable {
    /// One window's `VoiceLabTakeRun` input and the bounded set that window's run prepared from it.
    public struct Window: Sendable, Equatable {
        public let input: VoiceLabTakeInput
        public let quote: VoiceLabTakeRunQuote
        public init(input: VoiceLabTakeInput, quote: VoiceLabTakeRunQuote) { self.input = input; self.quote = quote }
        /// The window's request IDs in run order: each take's TTS, then its QA.
        public var requestIDs: [UUID] { quote.takes.flatMap { [$0.synthesis.requestID, $0.qa.requestID] } }
    }

    /// The display name in the batch's confirmation.
    public static let providerName = "ElevenLabs"
    /// `ElevenLabsVoiceLab` holds at most 32 outstanding quotes (§2.6) and a window holds a TTS and a QA quote for each of
    /// `CANDIDATES` takes, so preparing a sixth window would evict the first window's quotes before the approval.
    public static let maximumWindows = 32 / (2 * VoiceLabPricing.maximumCandidates)

    public let id: UUID
    /// In source order.
    public let windows: [Window]
    /// The union's summed TTS and Scribe QA estimate, one unit per take. `usd` is unknown when any quote's is, and so are
    /// `credits`.
    public let estimate: CostEstimate

    /// Refuses (`invalidInput`) what `validate(_:)` refuses, a window with no take or more than `CANDIDATES`, and a run,
    /// quote or request that appears twice.
    public init(id: UUID = UUID(), windows: [Window]) throws {
        try Self.validate(windows.map(\.input))
        var runs = Set<UUID>(), quotes = Set<UUID>(), requests = Set<UUID>()
        for window in windows {
            guard (1...VoiceLabPricing.maximumCandidates).contains(window.quote.takes.count), runs.insert(window.quote.id).inserted
            else { throw VoiceLabError.invalidInput }
            for quote in window.quote.takes.flatMap({ [$0.synthesis, $0.qa] }) {
                guard quotes.insert(quote.id).inserted, requests.insert(quote.requestID).inserted else { throw VoiceLabError.invalidInput }
            }
        }
        self.id = id
        self.windows = windows
        let takes = windows.flatMap(\.quote.takes)
        estimate = VoiceLabTakeRunQuote.total(of: takes.flatMap { [$0.synthesis.estimate, $0.qa.estimate] }, takes: takes.count)
    }

    /// Refuses (`invalidInput`) no window or more than `maximumWindows`, windows that differ in voice record, language,
    /// model or source (`contentKey`), and windows out of source order or without a gap between them (placeAll merges
    /// windows that touch, §8.4). A batch's runs check this before they prepare any quote.
    public static func validate(_ inputs: [VoiceLabTakeInput]) throws {
        guard (1...maximumWindows).contains(inputs.count), let first = inputs.first else { throw VoiceLabError.invalidInput }
        for (index, input) in inputs.enumerated() {
            guard input.recordID == first.recordID, input.language == first.language, input.modelID == first.modelID,
                  input.contentKey == first.contentKey,
                  index == 0 || inputs[index - 1].window.endSample < input.window.startSample else { throw VoiceLabError.invalidInput }
        }
    }

    public var takeCount: Int { windows.reduce(0) { $0 + $1.quote.takes.count } }

    /// The batch's one presentation (§3.1): inline below $0.50 when every price is known and the month's cap is not
    /// crossed, otherwise one confirmation for the whole batch, with the cap sentence when the union crosses `cap`.
    public func kind(cap: VoiceLabMonthlyCap? = nil) -> VoiceLabCostPresentation.Kind {
        VoiceLabCostPresentation.kind(estimate, isLipSync: false, providerName: Self.providerName, cap: cap)
    }

    /// The summed estimate of the batch's requests in `requestIDs`, one unit per take it touches. Other IDs are ignored.
    public func estimate(of requestIDs: Set<UUID>) -> CostEstimate {
        let takes = windows.flatMap(\.quote.takes)
        let quotes = takes.flatMap { [$0.synthesis, $0.qa] }.filter { requestIDs.contains($0.requestID) }
        let touched = takes.filter { requestIDs.contains($0.synthesis.requestID) || requestIDs.contains($0.qa.requestID) }
        return VoiceLabTakeRunQuote.total(of: quotes.map(\.estimate), takes: touched.count)
    }
}

/// A take batch's run, window by window; voice-lab §2.6 and §8.6. A window that completes or stops early discards its own
/// unsent quotes and hands over to the next window. A fatal, cancelled or invalidated window ends the batch and discards
/// every later window's quotes too. Sent means the provider accepted the request: its 2xx status line arrived, which is
/// exactly when the spend ledger records it (§3.1), whether or not the reply then succeeded. A request the provider
/// refused counts with the discarded ones, because nothing was recorded for it.
public struct VoiceLabTakeBatchProgress: Sendable, Equatable {
    public let batch: VoiceLabTakeBatch
    /// The window that runs next, in source order; nil once the batch is over.
    public private(set) var window: Int?
    /// The request IDs the provider accepted.
    public private(set) var sent: Set<UUID> = []
    /// The request IDs that will never be sent.
    public private(set) var discarded: Set<UUID> = []

    public init(batch: VoiceLabTakeBatch) { self.batch = batch; window = 0 }

    /// Records that window `index` ended with `end` after the provider accepted `requestIDs`. Refuses (`invalidInput`), and
    /// changes nothing for, a window other than `window`, a request that is not that window's, and a take's QA request
    /// without its TTS request.
    public mutating func finish(window index: Int, sent requestIDs: Set<UUID>, end: VoiceLabTakeRunEnd) throws {
        guard let current = window, index == current else { throw VoiceLabError.invalidInput }
        let own = batch.windows[index]
        guard requestIDs.isSubset(of: own.requestIDs),
              own.quote.takes.allSatisfy({ !requestIDs.contains($0.qa.requestID) || requestIDs.contains($0.synthesis.requestID) })
        else { throw VoiceLabError.invalidInput }
        sent.formUnion(requestIDs)
        discarded.formUnion(Set(own.requestIDs).subtracting(requestIDs))
        switch end {
        case .completed, .earlyStop:
            window = index + 1 < batch.windows.count ? index + 1 : nil
        case .cancelled, .invalidated, .fatal:
            for later in batch.windows[(index + 1)...] { discarded.formUnion(later.requestIDs) }
            window = nil
        }
    }

    /// `finish(window:sent:end:)` for a window's result: sent are the requests its rows record as accepted
    /// (`VoiceLabTakeRow.acceptedRequestIDs`), receipt or not.
    public mutating func finish(window index: Int, result: VoiceLabTakeRunResult) throws {
        try finish(window: index, sent: Set(result.rows.flatMap(\.acceptedRequestIDs)), end: result.end)
    }

    /// What the provider accepted, one unit per take with a sent TTS request: the "Made {t} takes · ≈ ${x}" line and the
    /// "Discard {t} takes?" amount (design delta §6 T3).
    public var sentEstimate: CostEstimate { batch.estimate(of: sent) }
    /// The approved requests neither sent nor discarded. A cap check before a later dispatch weighs this, not the whole
    /// batch, because the month's spend already holds what was sent.
    public var remainingEstimate: CostEstimate {
        batch.estimate(of: Set(batch.windows.flatMap(\.requestIDs)).subtracting(sent).subtracting(discarded))
    }
}
